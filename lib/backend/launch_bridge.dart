import 'dart:io';

import 'package:flutter/services.dart';

/// Bridge to the native boot receiver.
/// - [launchedFromBoot] tells us if this process was started by the device
///   boot (so we only auto-play for real reboots, not normal app opens).
/// - [setAutostartEnabled] mirrors the autostart toggle into native
///   SharedPreferences so the boot receiver knows whether to launch the app.
/// The device's configured timezone, as reported by Android.
class TimeZoneInfo {
  final String id; // IANA id, e.g. "Europe/Prague"
  final Duration offset; // offset in force right now
  final bool dst; // summer time currently active
  final String country; // region code from the system locale, e.g. "CZ"
  const TimeZoneInfo({
    required this.id,
    required this.offset,
    required this.dst,
    required this.country,
  });

  /// "UTC+2" / "UTC-3:30".
  String get offsetLabel {
    final m = offset.inMinutes;
    final sign = m < 0 ? '-' : '+';
    final h = m.abs() ~/ 60;
    final min = m.abs() % 60;
    return min == 0
        ? 'UTC$sign$h'
        : 'UTC$sign$h:${min.toString().padLeft(2, '0')}';
  }
}

class LaunchBridge {
  static const _channel = MethodChannel('cz.smotrim.player/launch');

  static Future<bool> launchedFromBoot() async {
    if (!Platform.isAndroid) return false;
    try {
      final v = await _channel.invokeMethod<bool>('launchedFromBoot');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setAutostartEnabled(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setAutostart', {'enabled': enabled});
    } catch (_) {}
  }

  /// Keeps the screen/device awake (FLAG_KEEP_SCREEN_ON) while [on] is true so
  /// the TV box does not go to sleep during playback.
  static Future<void> setKeepScreenOn(bool on) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setKeepScreenOn', {'on': on});
    } catch (_) {}
  }

  /// Whether the "display over other apps" (SYSTEM_ALERT_WINDOW) permission is
  /// granted — required so the boot receiver can launch the app on Android 12+.
  static Future<bool> hasOverlayPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final v = await _channel.invokeMethod<bool>('hasOverlayPermission');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system screen to grant the overlay permission.
  static Future<void> requestOverlayPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestOverlayPermission');
    } catch (_) {}
  }

  /// The timezone the device is configured with: IANA id ("Europe/Prague"),
  /// the offset in force right now, whether summer time is active, and the
  /// region code. Shown in Settings so a box left on the factory timezone is
  /// visible at a glance instead of silently shifting the whole guide.
  static Future<TimeZoneInfo?> timeZoneInfo() async {
    if (!Platform.isAndroid) return null;
    try {
      final v = await _channel.invokeMapMethod<String, dynamic>('timeZoneInfo');
      if (v == null) return null;
      return TimeZoneInfo(
        id: v['id'] as String? ?? '',
        offset: Duration(minutes: (v['offsetMinutes'] as int?) ?? 0),
        dst: v['dst'] as bool? ?? false,
        country: v['country'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// Whether an app with [package] is installed on the device.
  static Future<bool> isPackageInstalled(String package) async {
    if (!Platform.isAndroid) return false;
    try {
      final v = await _channel.invokeMethod<bool>(
        'isPackageInstalled',
        {'package': package},
      );
      return v ?? false;
    } catch (_) {
      return false;
    }
  }
}
