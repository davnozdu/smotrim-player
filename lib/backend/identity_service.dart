import 'dart:math';

import 'package:open_tv/backend/sql.dart';

const _subscriberIdKey = 'subscriberId';
const _subscriberPinKey = 'subscriberPin';
const subscriberIdLength = 8;
const subscriberPinLength = 6;

/// Subscriber identity: a unique 8-digit ID and a 6-digit PIN generated once on
/// the device and stored in the settings table (so they survive app updates —
/// see [Sql.getSetting]). The ID is shown on the home screen and used, together
/// with the PIN, to restore the subscriber's playlist from the server.
///
/// Generation uses [Random.secure] for a uniform, unpredictable draw so two
/// devices are extremely unlikely to land on the same ID+PIN pair; the server
/// (api.smotrim.cz) is expected to enforce final global uniqueness on registration.
class IdentityService {
  static final Random _rng = Random.secure();

  // A random n-digit string whose first digit is never 0, so it is always
  // exactly n digits long.
  static String _digits(int n) {
    final sb = StringBuffer();
    sb.write(1 + _rng.nextInt(9));
    for (var i = 1; i < n; i++) {
      sb.write(_rng.nextInt(10));
    }
    return sb.toString();
  }

  static bool _validDigits(String? v, int n) =>
      v != null && v.length == n && int.tryParse(v) != null;

  static Future<String> getOrCreateId() async {
    var id = await Sql.getSetting(_subscriberIdKey);
    if (!_validDigits(id, subscriberIdLength)) {
      id = _digits(subscriberIdLength);
      await Sql.setSetting(_subscriberIdKey, id);
    }
    return id!;
  }

  static Future<String?> getPin() async => Sql.getSetting(_subscriberPinKey);

  // Fresh ID + PIN that is NOT stored. Used by "become a subscriber": the new
  // credentials are only adopted once the user logs in with them.
  static ({String id, String pin}) generateCredentials() => (
        id: _digits(subscriberIdLength),
        pin: _digits(subscriberPinLength),
      );

  // Adopt an entered ID + PIN as this device's identity (after a successful
  // login/restore), so the home screen shows the subscriber's own ID.
  static Future<void> save(String id, String pin) async {
    await Sql.setSetting(_subscriberIdKey, id);
    await Sql.setSetting(_subscriberPinKey, pin);
  }

  static Future<String> getOrCreatePin() async {
    var pin = await Sql.getSetting(_subscriberPinKey);
    if (!_validDigits(pin, subscriberPinLength)) {
      pin = _digits(subscriberPinLength);
      await Sql.setSetting(_subscriberPinKey, pin);
    }
    return pin!;
  }

  /// Ensures the device has an ID and a PIN. [isNew] is true when the PIN had to
  /// be created (clean install, or an update from a build with no PIN yet) — the
  /// caller then shows the "save your credentials" notice.
  static Future<({String id, String pin, bool isNew})> ensure() async {
    final id = await getOrCreateId();
    final existing = await getPin();
    final pin = existing ?? await getOrCreatePin();
    return (id: id, pin: pin, isNew: existing == null);
  }
}
