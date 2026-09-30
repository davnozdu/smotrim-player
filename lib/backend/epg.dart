import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_tv/backend/epg_timezone.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/memory.dart';
import 'package:path_provider/path_provider.dart';

/// Default EPG with a week of past programmes (gzipped) — used for the archive
/// list. Logos stay on epg.one (better name coverage); this one is only pulled
/// on demand when opening the archive menu.
const archiveEpgUrl = 'https://iptvx.one/epg/epg_lite.xml.gz';

/// Programme times are shown in the viewer's timezone (by default the one the
/// device is set to), so the guide and the archive match the clock on the wall.
///
/// XMLTV timestamps carry an explicit UTC offset (both epg.one and iptvx.one
/// emit `+0300`), so the absolute instant is already exact after parsing — only
/// the presentation is converted here. Everything the player sends upstream
/// (the Flussonic `utc=` archive anchor) stays in real UTC seconds.
///
/// Note this applies no clock correction: a programme's start is already an
/// exact instant, and the device's timezone is a separate setting from its
/// (possibly wrong) clock. Only "now" needs correcting — see [epgNow].
DateTime epgLocal(DateTime utc) => epgToDisplay(utc);

// Offset between the EPG server's clock and this device's clock. TV boxes are
// the classic offender here: no RTC battery, no NTP until the network is up, so
// they can boot minutes (or hours) off. A wrong clock picks the wrong "now"
// programme and anchors the archive at the wrong moment, so the skew measured
// from the EPG response is folded into every "now" decision.
Duration _clockSkew = Duration.zero;

/// How far the device clock is off, as last measured against the EPG server.
Duration get epgClockSkew => _clockSkew;

/// "Now" in UTC, corrected for a wrong device clock. Everything that decides
/// which programme is on air — and where the archive's live edge is — uses
/// this instead of `DateTime.now()`.
DateTime epgNow() => DateTime.now().toUtc().add(_clockSkew);

// Anything under a minute is request latency and whole-second HTTP dates, not
// a clock problem worth correcting.
const _skewThreshold = Duration(minutes: 1);
bool _skewProbed = false;

// Measures the clock error from a HEAD request's Date header. Only used when
// the guide came from disk and no download happened to measure it. Runs once
// per app start.
Future<void> _probeClockSkew(String url) async {
  if (_skewProbed) return;
  _skewProbed = true;
  try {
    final resp = await http
        .head(Uri.parse(url))
        .timeout(const Duration(seconds: 8));
    final date = resp.headers['date'];
    if (date == null) return;
    final skew =
        HttpDate.parse(date).toUtc().difference(DateTime.now().toUtc());
    if (skew.abs() > _skewThreshold) _clockSkew = skew;
  } catch (_) {}
}

final _channelBlockRegex = RegExp(
  r'<channel\b[^>]*>(.*?)</channel>',
  dotAll: true,
);
final _displayNameRegex = RegExp(
  r'<display-name[^>]*>(.*?)</display-name>',
  dotAll: true,
);
final _iconRegex = RegExp(r'<icon[^>]*\bsrc="([^"]*)"');
final _tagRegex = RegExp(r'<[^>]+>');
final _nonAlphaNumRegex = RegExp(r'[^0-9a-zа-яё]');

/// Normalizes a channel name so playlist names and EPG display-names can be
/// matched regardless of case, quality markers and punctuation.
/// Keeps only latin/cyrillic letters and digits.
String normalizeChannelName(String name) {
  final lower = name.toLowerCase().replaceAll('&amp;', '&');
  return lower.replaceAll(_nonAlphaNumRegex, '');
}

const _qualTokens = {
  'hd', 'uhd', 'fhd', '4k', '2k', 'sd', 'hevc', 'h265', 'h264',
  'fps', 'orig', 'original', 'backup', 'raw', '50', '60',
};
const _countryTokens = {
  'uk', 'us', 'usa', 'fr', 'de', 'nl', 'pl', 'ua', 'ru', 'it', 'es', 'tr',
  'ge', 'az', 'by', 'kz', 'am', 'il', 'uz', 'tj', 'md', 'ro', 'pt', 'gb',
  'at', 'ch', 'be', 'se', 'no', 'fi', 'dk', 'cz', 'sk', 'hu', 'gr', 'rs',
  'hr', 'bg', 'ee', 'lv', 'lt',
};
final _parensRegex = RegExp(r'\([^)]*\)');
final _splitRegex = RegExp(r'[^0-9a-zа-яё]+');

// A timezone-shifted feed: "Первый канал +2", "НТВ (+4)", "Россия 1 (-1)".
// The sign must not be glued to a digit on either side, so channel names that
// merely contain a plus ("1+1", "1+2") are not mistaken for a shift.
final _shiftTokenRegex = RegExp(r'(^|[^0-9a-zа-яё])([+-]\d{1,2})(?![0-9])');

/// The timezone shift a channel name declares, in hours (0 when none).
int channelShiftHours(String name) {
  final m = _shiftTokenRegex.firstMatch(name.toLowerCase());
  if (m == null) return 0;
  return int.tryParse(m.group(2)!) ?? 0;
}

/// Looser normalization for matching against EPGs that lack quality/region
/// display-name variants: strips HD/UHD/4K/(region)/country tokens.
///
/// The `+N` shift is deliberately NOT stripped — it is kept as a suffix on the
/// key. A shifted feed broadcasts a different schedule from the base channel,
/// so merging them (as this used to) attaches the wrong programme list: picking
/// a show from the guide then opens the archive at a moment when something else
/// was on. Regions in brackets ("+0 (Липецк)") still collapse into the base
/// key — those run the base schedule on the same clock.
String normalizeChannelNameLoose(String name) =>
    _looseKey(name, keepCountry: false);

String _looseKey(String name, {required bool keepCountry}) {
  var s = name.toLowerCase().replaceAll('&amp;', '&');
  final shift = channelShiftHours(s);
  s = s.replaceAll(_parensRegex, '');
  // Drop only a genuine shift token, keeping the separator that preceded it.
  // A blanket `[+-]\d+` strip would also eat the second half of "1+1" / "1+2"
  // and collapse those two channels onto the same key.
  s = s.replaceAllMapped(_shiftTokenRegex, (m) => m.group(1)!);
  final out = <String>[];
  for (final t in s.split(_splitRegex)) {
    if (t.isEmpty || _qualTokens.contains(t)) continue;
    if (!keepCountry && _countryTokens.contains(t)) continue;
    out.add(t);
  }
  final base = out.join();
  if (base.isEmpty || shift == 0) return base;
  return '$base@$shift';
}

// The whole name — quality, country and region included — with only case and
// punctuation ignored. The shift stays a separate "@N" suffix, so "ТНТ4" and
// "ТНТ +4" remain two different channels.
String _exactKey(String name) {
  final s = name.toLowerCase().replaceAll('&amp;', '&');
  final shift = channelShiftHours(s);
  final base = s
      .replaceAllMapped(_shiftTokenRegex, (m) => m.group(1)!)
      .replaceAll(_nonAlphaNumRegex, '');
  if (base.isEmpty) return '';
  return shift == 0 ? '=$base' : '=$base@$shift';
}

// Quality markers dropped, country kept: "Animal Planet HD" -> "animalplanet",
// "Animal Planet HD DE" -> "animalplanetde".
String _regionalKey(String name) {
  final k = _looseKey(name, keepCountry: true);
  return k.isEmpty ? '' : '~$k';
}

/// Keys an EPG display-name is filed under, one per matching tier.
List<String> _displayNameKeys(String displayName) => [
  _exactKey(displayName),
  _regionalKey(displayName),
  normalizeChannelNameLoose(displayName),
];

/// Keys to look a playlist channel up by, most specific first.
///
/// The loose key alone collapses different feeds onto one entry: with the
/// country dropped, "Animal Planet" and "Animal Planet HD DE" are the same key,
/// and "RU.TV" becomes plain "tv" — which a dozen channels share. Whichever of
/// those had the most programmes used to win, so a channel regularly showed
/// another country's schedule (RU.TV showed Armenia TV). An exact or
/// same-country match now always beats the loose one; the loose key and the
/// HD->base fallback only apply when nothing closer exists.
List<String> _channelKeys(String channelName) {
  final keys = <String>[];
  void add(String k) {
    if (k.isNotEmpty && !keys.contains(k)) keys.add(k);
  }

  add(_exactKey(channelName));
  add(_regionalKey(channelName));
  add(normalizeChannelNameLoose(channelName));
  add(normalizeChannelNameLoose(channelName.replaceAll(_qualityStripRegex, ' ')));
  return keys;
}

// Simple in-memory cache so refreshing several sources in a row doesn't
// re-download the (large) EPG every time.
Map<String, String>? _cachedLogos;
String? _cachedUrl;
DateTime? _cachedAt;
const _cacheTtl = Duration(minutes: 10);

/// Downloads an XMLTV EPG and builds a map of normalized channel name -> logo url.
/// Only the `<channel>` section is read; downloading stops once `<programme>`
/// entries begin, so we never pull the (much larger) program data.
Future<Map<String, String>> fetchEpgLogos(String epgUrl) async {
  if (_cachedLogos != null &&
      _cachedUrl == epgUrl &&
      _cachedAt != null &&
      DateTime.now().difference(_cachedAt!) < _cacheTtl) {
    return _cachedLogos!;
  }
  final client = http.Client();
  try {
    final request = http.Request('GET', Uri.parse(epgUrl));
    // Logos are optional: on a stalled line give up rather than hold the whole
    // playlist import hostage.
    final response = await client.send(request).timeout(_connectTimeout);
    if (response.statusCode != 200) {
      throw Exception('Failed to download EPG: ${response.statusCode}');
    }
    final buffer = StringBuffer();
    await for (final line in response.stream
        .timeout(_idleTimeout)
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      buffer.writeln(line);
      // All <channel> entries come before any <programme>; stop reading there.
      if (line.contains('<programme')) break;
    }
    final logos = _parseLogos(buffer.toString());
    _cachedLogos = logos;
    _cachedUrl = epgUrl;
    _cachedAt = DateTime.now();
    return logos;
  } finally {
    client.close();
  }
}

// Cache for the full guide (all channels' programmes in a time window).
// Kept in memory (45 min) and mirrored to disk (6 h) so re-opening the guide —
// or a cold start — neither re-downloads nor re-parses. All heavy work
// (download, gzip, parse, JSON encode/decode) happens in a background isolate.
// Small per-URL memory cache. The catalog uses epgUrl while the player may use
// the archive EPG (when "extended archive" is on) — keeping both means they
// don't evict each other and force a re-parse from disk on every refresh.
final Map<String, Map<String, List<EpgProgram>>> _guideByUrl = {};
final Map<String, DateTime> _guideAtByUrl = {};
const _guideMaxUrls = 2;
// In-flight parse, so the catalog and the guide asking at the same time share
// a single download/parse instead of triggering two.
Future<Map<String, List<EpgProgram>>>? _guideInflight;
String? _guideInflightKey;
const _guideMemTtl = Duration(minutes: 45);
const _guideDiskTtl = Duration(hours: 6);
// How old a disk copy may be when the download fails and it is all there is.
const _guideStaleTtl = Duration(hours: 36);
// A stalled socket on a bad line would otherwise hang the download (and every
// screen waiting on it) until the OS gives up, which can take hours.
const _connectTimeout = Duration(seconds: 20);
const _idleTimeout = Duration(seconds: 30);

/// How far back a guide keeps programmes. The archive EPG carries 8 days of
/// past schedule and is the source for the 7-day archive list, so it is parsed
/// with a wide past window; epg.one only ever carries ~1 day.
///
/// Deriving the window from the URL (instead of passing it per call) keeps the
/// whole app on ONE parsed guide per source: the grid, the "now playing"
/// marquee and every channel's archive list all read the same cache entry, so
/// the EPG is downloaded and parsed once instead of once per screen.
Duration _pastWindowFor(String url) =>
    url == archiveEpgUrl ? const Duration(days: 8) : const Duration(hours: 30);

// Channels the user actually has. The EPG carries ~4000 channels and 1.4M
// programmes; a playlist has a few hundred. Dropping everything else inside the
// parse isolate is what makes a week-deep guide affordable on a TV box — both
// in parse time and in the memory the result occupies.
Set<String>? _scopeNames;
String _scopeKey = 'all';

/// Drops the parsed guide from RAM. The on-disk copy stays, so reopening the
/// guide is still fast — this only hands memory back to the system when
/// Android says it is short, typically mid-way through a long viewing session.
void clearEpgMemoryCache() {
  _guideByUrl.clear();
  _guideAtByUrl.clear();
}

/// Forgets the channel scope (and every guide parsed with it). Call after a
/// playlist is imported or refreshed, so new channels get EPG right away.
void invalidateEpgScope() {
  _scopeNames = null;
  _scopeKey = 'all';
  _guideByUrl.clear();
  _guideAtByUrl.clear();
}

Future<Set<String>> _epgScope() async {
  final cached = _scopeNames;
  if (cached != null) return cached;
  var names = <String>{};
  try {
    for (final n in await Sql.getLivestreamNames()) {
      // Every key the lookup may try, including the HD->base fallback, so an
      // HD channel still matches an EPG that only lists the SD schedule.
      names.addAll(_channelKeys(n));
    }
  } catch (_) {
    names = <String>{}; // empty = no filtering (safe fallback)
  }
  _scopeNames = names;
  _scopeKey = names.isEmpty
      ? 'all'
      : '${names.length}.${names.fold<int>(0, (a, b) => a ^ b.hashCode)}';
  return names;
}

// Stores a freshly built guide, evicting the least-recently-stored entry so the
// memory cache never holds more than [_guideMaxUrls] sources.
void _storeGuide(String key, Map<String, List<EpgProgram>> guide) {
  _guideByUrl[key] = guide;
  _guideAtByUrl[key] = DateTime.now();
  if (_guideByUrl.length > _guideMaxUrls) {
    final oldest = _guideAtByUrl.entries
        .reduce((a, b) => a.value.isBefore(b.value) ? a : b)
        .key;
    _guideByUrl.remove(oldest);
    _guideAtByUrl.remove(oldest);
  }
}

Future<File> _guideCacheFile(String key) async {
  final dir = await getTemporaryDirectory();
  // v2: keys carry matching tiers — a guide cached by an older build has none.
  return File('${dir.path}/epg_guide_v2_${key.hashCode}.json');
}

/// Returns programmes for every channel (normalized name -> programmes in a
/// window around now), for the TV guide grid, the catalog "now playing" and the
/// player's archive list. Memory cache -> disk cache -> background parse.
///
/// Pass [cachedOnly] when the caller cannot afford the heavy path — during
/// playback a download+parse competes with the video for RAM on a 2 GB box.
/// It then serves whatever is already in memory (even if past its TTL) and
/// never starts a download.
Future<Map<String, List<EpgProgram>>> fetchAllPrograms(
  String epgUrl, {
  bool cachedOnly = false,
}) async {
  final url = epgUrl.trim();
  if (url.isEmpty) return {};
  final scope = await _epgScope();
  // No livestreams yet (fresh install, or a movies-only playlist): there is
  // nothing to show a guide for, and parsing the whole feed unfiltered is
  // exactly the work this scope exists to avoid.
  if (scope.isEmpty) return {};
  // The scope is part of the key: after the playlist changes, a guide parsed
  // for the old channel set must not be served.
  final key = '$url|$_scopeKey';
  // 1) Fresh in-memory result for this exact source.
  final cached = _guideByUrl[key];
  final cachedAt = _guideAtByUrl[key];
  if (cached != null &&
      cachedAt != null &&
      DateTime.now().difference(cachedAt) < _guideMemTtl) {
    return cached;
  }
  // Stale, or nothing at all — but the caller asked not to pay for a reload.
  // A guide an hour past its TTL is still the right answer for "what is on
  // now": programme boundaries move slowly.
  if (cachedOnly) return cached ?? {};
  // Coalesce concurrent requests for the same source.
  if (_guideInflight != null && _guideInflightKey == key) {
    return _guideInflight!;
  }
  final future = _loadGuide(url, key, scope);
  _guideInflight = future;
  _guideInflightKey = key;
  try {
    return await future;
  } finally {
    if (identical(_guideInflight, future)) {
      _guideInflight = null;
      _guideInflightKey = null;
    }
  }
}

Future<Map<String, List<EpgProgram>>> _loadGuide(
  String url,
  String key,
  Set<String> scope,
) async {
  // 2) Recent on-disk copy (decoded in a background isolate).
  final fromDisk = await _readGuideDisk(key);
  if (fromDisk != null) {
    _storeGuide(key, fromDisk);
    // Serving from disk skips the download that normally measures the clock —
    // and a box that just booted with a wrong clock is exactly the case where
    // the cache is freshest. Probe separately, without blocking the guide.
    unawaited(_probeClockSkew(url));
    return fromDisk;
  }
  // 3) Download + parse + persist — all inside the isolate.
  final cachePath = (await _guideCacheFile(key)).path;
  final Map<String, dynamic> data;
  try {
    data = await compute(_parseAllPrograms, {
      'url': url,
      'cache': cachePath,
      'pastHours': _pastWindowFor(url).inHours,
      'names': scope.toList(),
    });
  } catch (_) {
    // No usable connection. A guide from yesterday is still right about what
    // is on today (the feed covers 36 h ahead) — far better than a blank grid
    // on a flaky line. It goes into memory like a fresh one, so the download
    // is retried once the memory TTL runs out instead of on every screen.
    final stale = await _readGuideDisk(key, maxAge: _guideStaleTtl);
    if (stale == null) rethrow;
    _storeGuide(key, stale);
    return stale;
  }
  // Only a fresh response carries a server clock to compare against; a guide
  // restored from disk leaves the last measured skew alone.
  final skew = Duration(milliseconds: (data['skew'] as int?) ?? 0);
  _clockSkew = skew.abs() > _skewThreshold ? skew : Duration.zero;
  _skewProbed = true;
  final result = _buildGuide(data);
  _storeGuide(key, result);
  return result;
}

// Builds the name -> programmes map from the isolate's id-keyed output.
Map<String, List<EpgProgram>> _buildGuide(Map data) {
  final namesById = data['names'] as Map;
  final progsById = data['progs'] as Map;
  final result = <String, List<EpgProgram>>{};
  progsById.forEach((id, list) {
    final programs = _withoutOverlaps(
      (list as List)
          .map((m) => _programFromMap(Map<String, dynamic>.from(m as Map)))
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start)),
    );
    for (final name in (namesById[id] as List? ?? const [])) {
      final existing = result[name as String];
      // HD and SD variants of a channel can collapse to the same normalized
      // key — keep the entry that actually has programmes (don't let an empty
      // one wipe a full one).
      if (existing == null || programs.length > existing.length) {
        result[name] = programs;
      }
    }
  });
  return result;
}

/// Builds a guide the way a download does, from display-names and programmes
/// per EPG channel id. Only for tests: the real input comes from the parser.
@visibleForTesting
Map<String, List<EpgProgram>> buildGuideForTest(
  Map<String, List<String>> displayNamesById,
  Map<String, List<EpgProgram>> programsById,
) => _buildGuide({
  'names': {
    for (final e in displayNamesById.entries)
      e.key: {for (final n in e.value) ..._displayNameKeys(n)}
          .where((k) => k.isNotEmpty)
          .toList(),
  },
  'progs': {
    for (final e in programsById.entries)
      e.key: [
        for (final p in e.value)
          {
            's': p.start.millisecondsSinceEpoch,
            'e': p.stop.millisecondsSinceEpoch,
            't': p.title,
          },
      ],
  },
});

/// Trims each programme so it ends no later than the next one starts, and
/// drops exact duplicates. Feeds are not always consistent — iptvx.one has
/// overlaps on about one channel in twelve (a show running a few minutes past
/// the next one's start, or a short news slot nested inside a film). Left as
/// is, those draw as blocks stacked on top of each other in the grid, and "what
/// is on now" depends on which of the two happens to come first. [sorted] must
/// be ordered by start.
List<EpgProgram> _withoutOverlaps(List<EpgProgram> sorted) {
  final out = <EpgProgram>[];
  for (final p in sorted) {
    if (out.isNotEmpty) {
      final prev = out.last;
      if (p.start == prev.start) {
        // Same slot listed twice: a title beats none, then the longer wins.
        final better = prev.title.isEmpty != p.title.isEmpty
            ? p.title.isNotEmpty
            : p.stop.isAfter(prev.stop);
        if (better) out[out.length - 1] = p;
        continue;
      }
      if (p.start.isBefore(prev.stop)) {
        out[out.length - 1] = EpgProgram(prev.start, p.start, prev.title);
      }
    }
    out.add(p);
  }
  return out;
}

// Matches quality markers even when glued to the name (e.g. "ТВ HD", "ТВHD").
final _qualityStripRegex = RegExp(
  r'(uhd|fhd|hd|4k|2k|sd)',
  caseSensitive: false,
);

/// Programmes for a channel, with an HD->base fallback: if the exact (loose)
/// name has no programmes, retry with quality markers stripped, so HD channels
/// reuse the non-HD schedule when only that exists.
List<EpgProgram> epgProgramsFor(
  Map<String, List<EpgProgram>> guide,
  String channelName,
) {
  for (final k in _channelKeys(channelName)) {
    final p = guide[k];
    if (p != null && p.isNotEmpty) return p;
  }
  return const [];
}

/// Current "now playing" title for a channel, matched the same way as
/// [epgProgramsFor] so the catalog, the guide and the player agree.
String? epgNowTitleFor(Map<String, String> nowMap, String channelName) {
  for (final k in _channelKeys(channelName)) {
    final t = nowMap[k];
    if (t != null && t.isNotEmpty) return t;
  }
  return null;
}

// Reads & decodes the on-disk guide in a background isolate (if fresh enough).
Future<Map<String, List<EpgProgram>>?> _readGuideDisk(
  String key, {
  Duration maxAge = _guideDiskTtl,
}) async {
  try {
    final f = await _guideCacheFile(key);
    if (!await f.exists()) return null;
    if (DateTime.now().difference(await f.lastModified()) > maxAge) {
      return null;
    }
    final raw = await compute(_decodeGuideFile, f.path);
    if (raw == null) return null;
    return _buildGuide(raw);
  } catch (_) {
    return null;
  }
}

// Isolate: read the cached JSON file off the UI thread.
Map<String, dynamic>? _decodeGuideFile(String path) {
  try {
    final data = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    return {'names': data['names'], 'progs': data['progs']};
  } catch (_) {
    return null;
  }
}

// Isolate: parse programmes for the user's channels in
// [now-pastHours, now+36h] and cache the result to disk.
//
// Only channels present in `names` are kept — on a typical playlist that skips
// ~90% of the feed, which is what keeps a week-deep archive parse affordable on
// a TV box. An empty `names` means "no playlist known yet": keep everything so
// the guide still works instead of coming back blank.
Future<Map<String, dynamic>> _parseAllPrograms(Map<String, dynamic> args) async {
  final epgUrl = args['url'] as String;
  final cachePath = args['cache'] as String?;
  final pastHours = (args['pastHours'] as int?) ?? 6;
  final scope = ((args['names'] as List?) ?? const []).cast<String>().toSet();
  final client = http.Client();
  try {
    final response = await client
        .send(http.Request('GET', Uri.parse(epgUrl)))
        .timeout(_connectTimeout);
    if (response.statusCode != 200) {
      throw Exception('Failed to download EPG: ${response.statusCode}');
    }
    // How far this device's clock is off, measured against the server's. Used
    // to pick the right "now" programme even on a box with a bad clock.
    var skewMs = 0;
    final serverDate = response.headers['date'];
    if (serverDate != null) {
      try {
        skewMs = HttpDate.parse(serverDate)
            .toUtc()
            .difference(DateTime.now().toUtc())
            .inMilliseconds;
      } catch (_) {}
    }
    // A slow line is fine; a line that stops delivering altogether fails the
    // download (and falls back to the disk copy) instead of hanging it.
    Stream<List<int>> bytes = response.stream.timeout(_idleTimeout);
    if (epgUrl.endsWith('.gz')) {
      bytes = bytes.transform(gzip.decoder);
    }
    // The window is centred on corrected "now", so a wrong clock can't shift
    // the retained programmes out from under the guide.
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch + skewMs;
    final lower = nowMs - pastHours * 3600 * 1000;
    final upper = nowMs + 36 * 3600 * 1000;
    final idNames = <String, List<String>>{};
    final idProgs = <String, List<Map<String, dynamic>>>{};
    final current = StringBuffer();
    await for (final line in bytes
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      current.writeln(line);
      if (line.contains('</channel>')) {
        final block = current.toString();
        current.clear();
        final id = _channelIdRegex.firstMatch(block)?.group(1);
        if (id != null) {
          final names = <String>[];
          for (final dn in _displayNameRegex.allMatches(block)) {
            final keys = _displayNameKeys(
              (dn.group(1) ?? '').replaceAll(_tagRegex, ''),
            );
            for (final k in keys) {
              if (k.isEmpty || names.contains(k)) continue;
              if (scope.isNotEmpty && !scope.contains(k)) continue;
              names.add(k);
            }
          }
          if (names.isNotEmpty) idNames[id] = names;
        }
      } else if (line.contains('</programme>')) {
        final block = current.toString();
        current.clear();
        final ch = _progChannelRegex.firstMatch(block)?.group(1);
        // Not one of the user's channels — skip before any further regex work.
        if (ch == null || !idNames.containsKey(ch)) continue;
        final sm = _progStartRegex.firstMatch(block);
        final em = _progStopRegex.firstMatch(block);
        if (sm == null || em == null) continue;
        final start = _parseXmltvTime(sm.group(1)!, sm.group(2));
        final stop = _parseXmltvTime(em.group(1)!, em.group(2));
        final sMs = start.millisecondsSinceEpoch;
        final eMs = stop.millisecondsSinceEpoch;
        if (eMs <= lower || sMs >= upper) continue;
        final title = (_titleRegex.firstMatch(block)?.group(1) ?? '')
            .replaceAll(_tagRegex, '')
            .trim();
        (idProgs[ch] ??= []).add({'s': sMs, 'e': eMs, 't': _unescapeXml(title)});
      }
    }
    final out = <String, dynamic>{'names': idNames, 'progs': idProgs};
    // Persist for fast cold starts (best-effort, still inside the isolate).
    // The skew is deliberately not persisted — it is only valid for a live
    // response, and a stale one would be worse than none.
    if (cachePath != null) {
      try {
        File(cachePath).writeAsStringSync(jsonEncode(out));
      } catch (_) {}
    }
    out['skew'] = skewMs;
    return out;
  } finally {
    client.close();
  }
}

/// Refreshes the global "now playing" map (normalized name -> current title).
/// Derived from the shared guide cache — no separate download/parse. The derive
/// always runs (it's cheap: just scanning the in-memory guide) so the catalog
/// marquee reflects the *current* programme, not a stale snapshot. The heavy
/// download/parse stays guarded by the guide cache (45 min memory / 6 h disk).
Future<void> refreshNowPlaying(String epgUrl) async {
  final url = epgUrl.trim();
  if (url.isEmpty) return;
  try {
    final guide = await fetchAllPrograms(url);
    nowPlaying.value = _deriveNowPlaying(guide);
    nowPlayingAt = DateTime.now();
  } catch (_) {}
}

// Picks the currently-airing title per channel from the parsed guide.
Map<String, String> _deriveNowPlaying(Map<String, List<EpgProgram>> guide) {
  final now = epgNow();
  final out = <String, String>{};
  guide.forEach((name, programs) {
    for (final p in programs) {
      if (!p.start.isAfter(now) && p.stop.isAfter(now)) {
        if (p.title.isNotEmpty) out[name] = p.title;
        break;
      }
    }
  });
  return out;
}

/// A single EPG programme (times in UTC).
class EpgProgram {
  final DateTime start;
  final DateTime stop;
  final String title;
  const EpgProgram(this.start, this.stop, this.title);
}

final _channelIdRegex = RegExp(r'<channel id="([^"]+)"');
final _progChannelRegex = RegExp(r'channel="([^"]+)"');
final _progStartRegex = RegExp(r'start="(\d{14})\s*([+\-]\d{4})?"');
final _progStopRegex = RegExp(r'stop="(\d{14})\s*([+\-]\d{4})?"');
final _titleRegex = RegExp(r'<title[^>]*>(.*?)</title>', dotAll: true);

/// Programmes for one channel, taken from the shared guide cache.
///
/// The guide is downloaded and parsed once per source (see [fetchAllPrograms]),
/// so opening the archive on a second channel costs a map lookup instead of
/// another EPG download — that used to be a full re-download and re-parse of
/// the feed for every channel the user opened.
Future<List<EpgProgram>> fetchPrograms(
  String epgUrl,
  String channelName,
) async {
  final guide = await fetchAllPrograms(epgUrl);
  return epgProgramsFor(guide, channelName);
}

EpgProgram _programFromMap(Map<String, dynamic> m) => EpgProgram(
  DateTime.fromMillisecondsSinceEpoch(m['s'] as int, isUtc: true),
  DateTime.fromMillisecondsSinceEpoch(m['e'] as int, isUtc: true),
  m['t'] as String,
);

DateTime _parseXmltvTime(String digits, String? tz) {
  var dt = DateTime.utc(
    int.parse(digits.substring(0, 4)),
    int.parse(digits.substring(4, 6)),
    int.parse(digits.substring(6, 8)),
    int.parse(digits.substring(8, 10)),
    int.parse(digits.substring(10, 12)),
    int.parse(digits.substring(12, 14)),
  );
  if (tz != null && tz.length == 5) {
    final sign = tz[0] == '-' ? -1 : 1;
    final offMinutes =
        int.parse(tz.substring(1, 3)) * 60 + int.parse(tz.substring(3, 5));
    dt = dt.subtract(Duration(minutes: sign * offMinutes));
  }
  return dt;
}

String _unescapeXml(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'");

Map<String, String> _parseLogos(String xml) {
  final map = <String, String>{};
  for (final block in _channelBlockRegex.allMatches(xml)) {
    final content = block.group(1)!;
    final icon = _iconRegex.firstMatch(content)?.group(1);
    if (icon == null || icon.isEmpty) continue;
    for (final dn in _displayNameRegex.allMatches(content)) {
      final raw = (dn.group(1) ?? '').replaceAll(_tagRegex, '');
      final key = normalizeChannelName(raw);
      if (key.isNotEmpty) map.putIfAbsent(key, () => icon);
    }
  }
  return map;
}
