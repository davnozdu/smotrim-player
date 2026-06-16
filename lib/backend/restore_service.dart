import 'package:open_tv/backend/identity_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';

/// Restores the subscriber's playlist from the server using their ID + PIN.
///
/// The server-side download script is not written yet; this builds the request
/// URL and feeds it through the normal M3U-URL import pipeline. Once the script
/// at [apiBase] returns an M3U playlist for the given credentials, restoring
/// will download and import it automatically (no other code changes needed).
class RestoreService {
  // Base of the (server-side, not yet implemented) playlist API.
  static const apiBase = 'https://api.smotrim.cz';
  // Stable source name so re-restoring updates the same playlist.
  static const sourceName = 'Smotrim CZ';

  // Provisional endpoint — adjust the path here once the server script exists.
  static String playlistUrl(String id, String pin) =>
      '$apiBase/playlist.php'
      '?id=${Uri.encodeQueryComponent(id)}'
      '&pin=${Uri.encodeQueryComponent(pin)}';

  /// Downloads and imports the playlist for [id]/[pin], then switches the app to
  /// it. Throws on network / parse errors (surfaced by the caller).
  static Future<void> restore(String id, String pin) async {
    await Utils.processSource(
      Source(
        name: sourceName,
        sourceType: SourceType.m3uUrl,
        url: playlistUrl(id, pin),
      ),
    );
    await Sql.activateOnlySource(sourceName);
    // Adopt the entered credentials as this device's identity.
    await IdentityService.save(id, pin);
  }
}
