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
/// Talks to the api.smotrim.cz endpoint (playlist.php): on HTTP 200 the body is
/// the M3U playlist, which is imported and made the active source. Other status
/// codes map to clear errors (403 = wrong id/pin, 429 = throttled, …).
class RestoreService {
  static const apiBase = 'https://api.smotrim.cz';
  // Stable source name so re-restoring updates the same playlist.
  static const sourceName = 'Smotrim CZ';

  static String playlistUrl(String id, String pin) =>
      '$apiBase/playlist.php'
      '?id=${Uri.encodeQueryComponent(id)}'
      '&pin=${Uri.encodeQueryComponent(pin)}';

  static Future<void> restore(String id, String pin) async {
    final url = playlistUrl(id, pin);

    // 1) Fetch the playlist with explicit status handling.
    final client = http.Client();
    String body;
    try {
      final resp = await client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      switch (resp.statusCode) {
        case 200:
          body = utf8.decode(resp.bodyBytes, allowMalformed: true);
          break;
        case 400:
          throw RestoreException(RestoreError.invalidInput);
        case 403:
          throw RestoreException(RestoreError.badCredentials);
        case 429:
          throw RestoreException(RestoreError.throttled);
        default:
          throw RestoreException(RestoreError.server);
      }
    } on RestoreException {
      rethrow;
    } catch (_) {
      throw RestoreException(RestoreError.network);
    } finally {
      client.close();
    }

    // 2) Make sure it's actually an M3U before importing.
    if (!body.trimLeft().startsWith('#EXTM3U')) {
      throw RestoreException(RestoreError.badPlaylist);
    }

    // 3) Import from the already-downloaded content (no second download). The
    //    source is stored as an M3U-URL source so future "refresh" re-fetches
    //    it from the API.
    final path = await Utils.getTempPath('restore.m3u');
    await File(path).writeAsString(body);
    try {
      await processM3U(
        Source(name: sourceName, sourceType: SourceType.m3uUrl, url: url),
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
