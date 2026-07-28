import 'dart:convert';
import 'dart:io';

import 'package:open_tv/backend/epg.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/channel_http_headers.dart';
import 'package:open_tv/models/channel_preserve.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/source.dart';
import 'package:sqlite_async/sqlite_async.dart';
import 'package:http/http.dart' as http;

final nameRegex = RegExp(r'tvg-name="([^"]*)"');
final nameRegexAlt = RegExp(r',([^,\n\r\t]*)$');
final idRegex = RegExp(r'tvg-id="([^"]*)"');
final logoRegex = RegExp(r'tvg-logo="([^"]*)"');
final groupRegex = RegExp(r'group-title="([^"]*)"');
final extGrpRegex = RegExp(r'#EXTGRP:(.*)', caseSensitive: false);
// Days of catchup the provider keeps for the channel. `tvg-rec` is what this
// provider emits; `catchup-days` is the other common spelling. 0 means the
// channel has no archive — asking for one just returns an empty playlist.
final catchupDaysRegex =
    RegExp(r'(?:tvg-rec|catchup-days)="(\d+)"', caseSensitive: false);
final httpOriginRegex = RegExp(r'http-origin=(.+)');
final httpReferrerRegex = RegExp(r'http-referrer=(.+)');
final httpUserAgentRegex = RegExp(r'http-user-agent=(.+)');

Future<void> processM3U(Source source, bool wipe, [String? path]) async {
  path ??= source.url;
  final logoMap = await _getEpgLogoMap();
  List<ChannelPreserve>? preserve;
  var file = File(
    path!,
  ).openRead().transform(utf8.decoder).transform(const LineSplitter());
  List<Future<void> Function(SqliteWriteContext, Map<String, String>)>
  statements = [];
  statements.add(Sql.getOrCreateSourceByName(source));
  if (wipe) {
    preserve = await Sql.getChannelsPreserve(source.id!);
    statements.add(Sql.wipeSource(source.id!));
  }
  String? lastLine;
  String? channelLine;
  String? channelGroup;
  ChannelHttpHeaders? headers;
  var httpHeadersSet = false;
  await for (var line in file) {
    final lineUpper = line.toUpperCase();
    if (lineUpper.startsWith("#EXTINF")) {
      if (channelLine != null &&
          lastLine != null &&
          lastLine.trim().isNotEmpty) {
        commitChannel(
          channelLine,
          lastLine,
          channelGroup,
          httpHeadersSet ? headers : null,
          logoMap,
          statements,
        );
      }
      channelLine = line;
      lastLine = null;
      channelGroup = null;
      httpHeadersSet = false;
      headers = null;
    } else if (lineUpper.startsWith("#EXTGRP")) {
      final group = extGrpRegex.firstMatch(line)?[1]?.trim();
      if (group != null && group.isNotEmpty) {
        channelGroup = group;
      }
    } else if (lineUpper.startsWith("#EXTVLCOPT")) {
      headers ??= ChannelHttpHeaders();
      if (setChannelHeaders(line, headers)) {
        httpHeadersSet = true;
      }
    } else {
      if (line.trim().isNotEmpty) {
        lastLine = line;
      }
    }
  }
  if (channelLine != null && lastLine != null && lastLine.trim().isNotEmpty) {
    commitChannel(channelLine, lastLine, channelGroup, headers, logoMap, statements);
  }
  statements.add(Sql.updateGroups());
  if (preserve != null) {
    statements.add(Sql.restorePreserve(preserve));
  }
  await Sql.commitWrite(statements);
  // The channel list decides which channels the EPG is parsed for. Restoring a
  // playlist goes straight through here (not via Utils.processSource), so drop
  // the cached scope here too or the new channels get no programme data.
  invalidateEpgScope();
}

void commitChannel(
  String l1,
  String last,
  String? extGroup,
  ChannelHttpHeaders? headers,
  Map<String, String>? logoMap,
  List<Future<void> Function(SqliteWriteContext, Map<String, String>)>
  statements,
) {
  var channel = getChannelFromLines(l1, last, extGroup, logoMap);
  if (channel == null) return;
  statements.add(Sql.insertChannel(channel));
  if (headers != null) {
    statements.add(Sql.insertChannelHeaders(headers));
  }
}

MediaType getMediaType(String url) {
  if (url.endsWith('.mp4') || url.endsWith('.mkv')) {
    return MediaType.movie;
  }
  return MediaType.livestream;
}

Channel? getChannelFromLines(
  String l1,
  String last, [
  String? extGroup,
  Map<String, String>? logoMap,
]) {
  var url = last.trim();
  if (url.isEmpty) return null;

  var name = getName(l1)?.trim();
  if (name == null || name.isEmpty) return null;

  var image = logoRegex.firstMatch(l1)?[1]?.trim();
  if ((image == null || image.isEmpty) && logoMap != null) {
    image = logoMap[normalizeChannelName(name)];
  }

  var group = groupRegex.firstMatch(l1)?[1]?.trim();
  if (group == null || group.isEmpty) {
    group = extGroup;
  }

  final rec = catchupDaysRegex.firstMatch(l1)?[1];

  return Channel(
    name: name,
    group: group,
    image: image,
    favorite: false,
    mediaType: getMediaType(url),
    sourceId: -1,
    url: url,
    catchupDays: rec == null ? null : int.tryParse(rec),
  );
}

/// Builds the EPG logo lookup based on user settings.
/// Returns null when disabled or unavailable so import never fails because of EPG.
Future<Map<String, String>?> _getEpgLogoMap() async {
  try {
    final settings = await SettingsService.getSettings();
    if (!settings.fillLogosFromEpg) return null;
    final url = settings.epgUrl.trim();
    if (url.isEmpty) return null;
    return await fetchEpgLogos(url);
  } catch (_) {
    return null;
  }
}

String? getName(String l1) {
  var name = nameRegex.firstMatch(l1)?[1];
  if (name != null && name.trim().isNotEmpty) return name;

  name = nameRegexAlt.firstMatch(l1)?[1];
  if (name != null && name.trim().isNotEmpty) return name;

  name = idRegex.firstMatch(l1)?[1];
  if (name != null && name.trim().isNotEmpty) return name;

  return null;
}

bool setChannelHeaders(String headerLine, ChannelHttpHeaders headers) {
  final userAgent = httpUserAgentRegex.firstMatch(headerLine)?[1];
  if (userAgent != null) {
    headers.userAgent = userAgent;
    return true;
  }
  final referrer = httpReferrerRegex.firstMatch(headerLine)?[1];
  if (referrer != null) {
    headers.referrer = referrer;
    return true;
  }
  final origin = httpOriginRegex.firstMatch(headerLine)?[1];
  if (origin != null) {
    headers.httpOrigin = origin;
    return true;
  }
  return false;
}

Future<void> processM3UUrl(Source source, bool wipe) async {
  var path = await downloadM3U(source.url!);
  await processM3U(source, wipe, path);
}

Future<String> downloadM3U(String urlStr) async {
  final url = Uri.parse(urlStr);
  final client = http.Client();
  final request = http.Request('GET', url);
  final response = await client.send(request);
  if (response.statusCode != 200) {
    throw Exception('Failed to download file: ${response.statusCode}');
  }
  final path = await Utils.getTempPath("get.m3u");
  final file = File(path);
  final sink = file.openWrite();
  await for (var chunk in response.stream) {
    sink.add(chunk);
  }
  await sink.close();
  client.close();
  return path;
}
