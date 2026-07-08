import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_tv/backend/identity_service.dart';
import 'package:open_tv/backend/m3u.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/l10n/strings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';

/// Reasons a restore can fail, mapped to a localized message by the UI.
enum RestoreError { invalidInput, badCredentials, throttled, server, network, badPlaylist }

class RestoreException implements Exception {
  final RestoreError code;
  RestoreException(this.code);
  @override
  String toString() => 'RestoreException($code)';
}

/// Localized text for a [RestoreError].
String restoreErrorText(S s, RestoreError code) {
  switch (code) {
    case RestoreError.invalidInput:
      return s.restoreInvalidInput;
    case RestoreError.badCredentials:
      return s.restoreErrBadCredentials;
    case RestoreError.throttled:
      return s.restoreErrThrottled;
    case RestoreError.server:
      return s.restoreErrServer;
    case RestoreError.network:
      return s.restoreErrNetwork;
    case RestoreError.badPlaylist:
      return s.restoreErrBadPlaylist;
  }
}

/// Restores the subscriber's playlist from the server using their ID + PIN.
///
/// The playlist.php endpoint returns the M3U on HTTP 200. It is served from two
/// interchangeable hosts (same database): tv.smotrim.cz is tried first because
/// it has no bot-protection, then api.smotrim.cz. A host that is unreachable,
/// not deployed (404) or blocked by a hosting anti-bot challenge (401/HTML) is
/// skipped and the next one is tried. Definitive answers from a working
/// endpoint — 400 (bad input), 403 (wrong id/pin), 429 (throttled) — stop the
/// search immediately and map to a clear error.
class RestoreService {
  // Ordered by preference. Both hosts hit the same subscribers database.
  static const apiBases = ['https://tv.smotrim.cz', 'https://api.smotrim.cz'];
  // Stable source name so re-restoring updates the same playlist.
  static const sourceName = 'Smotrim CZ';

  static String _playlistUrl(String base, String id, String pin) =>
      '$base/playlist.php'
      '?id=${Uri.encodeQueryComponent(id)}'
      '&pin=${Uri.encodeQueryComponent(pin)}';

  static Future<void> restore(String id, String pin) async {
    // 1) Fetch the playlist, trying each host until one returns a real M3U.
    final client = http.Client();
    String? body;
    String? usedUrl;
    // Remembered when a host fails "softly" (network/blocked/not-deployed) so we
    // can surface a sensible error if every host fails that way.
    RestoreError softError = RestoreError.network;
    try {
      for (final base in apiBases) {
        final url = _playlistUrl(base, id, pin);
        try {
          final resp = await client
              .get(Uri.parse(url))
              .timeout(const Duration(seconds: 30));
          switch (resp.statusCode) {
            case 200:
              final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
              // A working endpoint returns the M3U. Anything else on 200 (e.g.
              // an anti-bot HTML/JS challenge page) is not ours → try next host.
              if (text.contains('#EXTM3U')) {
                body = text;
                usedUrl = url;
              } else {
                softError = RestoreError.network;
              }
              break;
            case 400:
              throw RestoreException(RestoreError.invalidInput);
            case 403:
              throw RestoreException(RestoreError.badCredentials);
            case 429:
              throw RestoreException(RestoreError.throttled);
            default:
              // 401 (anti-bot "Token required"), 404 (not deployed), 5xx, …
              softError = RestoreError.server;
          }
        } on RestoreException {
          rethrow;
        } catch (_) {
          softError = RestoreError.network;
        }
        if (body != null) break;
      }
    } finally {
      client.close();
    }

    if (body == null || usedUrl == null) {
      throw RestoreException(softError);
    }

    // 2) Trim any leading junk before the first #EXTM3U (BOM, blank lines).
    final idx = body.indexOf('#EXTM3U');
    if (idx > 0) {
      body = body.substring(idx);
    }

    // 3) Import from the already-downloaded content (no second download). The
    //    source is stored as an M3U-URL source so future "refresh" re-fetches
    //    it from the same host that answered.
    final path = await Utils.getTempPath('restore.m3u');
    await File(path).writeAsString(body);
    try {
      await processM3U(
        Source(name: sourceName, sourceType: SourceType.m3uUrl, url: usedUrl),
        false,
        path,
      );
    } catch (_) {
      throw RestoreException(RestoreError.badPlaylist);
    }

    // 4) Switch to it and adopt the credentials as this device's identity.
    await Sql.activateOnlySource(sourceName);
    await IdentityService.save(id, pin);
  }
}
