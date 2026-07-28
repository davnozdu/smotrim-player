/// Which timezone programme times are displayed in.
///
/// [auto] is the default and the right answer for a correctly set-up box: the
/// system knows its own IANA zone ("Europe/Prague"), so `toLocal()` applies the
/// full rules — including the summer/winter switch — without this app knowing
/// anything about geography.
///
/// The fixed options exist for the case [auto] cannot fix: a box shipped with
/// the wrong region and never corrected (Asia/Shanghai is the classic). They
/// carry their own DST rules so they stay right across the switch too.
enum EpgTimezone {
  /// Follow the timezone configured on the device.
  auto,

  /// Central Europe — CET in winter, CEST in summer (Prague, Berlin, Warsaw).
  centralEurope,

  /// Moscow — UTC+3 all year, no summer time since 2014.
  moscow,
}

EpgTimezone epgTimezoneFromName(String? name) {
  switch (name) {
    case 'centralEurope':
      return EpgTimezone.centralEurope;
    case 'moscow':
      return EpgTimezone.moscow;
    default:
      return EpgTimezone.auto;
  }
}

String epgTimezoneName(EpgTimezone tz) {
  switch (tz) {
    case EpgTimezone.centralEurope:
      return 'centralEurope';
    case EpgTimezone.moscow:
      return 'moscow';
    case EpgTimezone.auto:
      return 'auto';
  }
}

/// Active display timezone. Set once from the stored settings at startup and
/// whenever the setting changes, so the guide, the archive list and the player
/// all read the same value without threading Settings through every widget.
EpgTimezone epgTimezone = EpgTimezone.auto;

/// Converts a UTC instant to the display timezone.
///
/// The offset is resolved **for that instant**, not for "now". That matters
/// around the DST switch: a programme recorded before the switch has to render
/// with the offset that applied then, otherwise everything in yesterday's
/// archive shifts by an hour on the last Sunday of March and October.
DateTime epgToDisplay(DateTime utc) {
  final u = utc.toUtc();
  switch (epgTimezone) {
    case EpgTimezone.auto:
      return u.toLocal();
    case EpgTimezone.centralEurope:
      return u.add(Duration(hours: euSummerTime(u) ? 2 : 1));
    case EpgTimezone.moscow:
      return u.add(const Duration(hours: 3));
  }
}

/// Whether EU summer time is in force at [utc].
///
/// The EU switches at the same instant everywhere: 01:00 UTC on the last Sunday
/// of March, back at 01:00 UTC on the last Sunday of October. One rule covers
/// every EU zone, so this needs no timezone database.
bool euSummerTime(DateTime utc) {
  final u = utc.toUtc();
  final start = _lastSundayAtOneUtc(u.year, 3);
  final end = _lastSundayAtOneUtc(u.year, 10);
  return !u.isBefore(start) && u.isBefore(end);
}

// Last Sunday of [month] at 01:00 UTC. Day 0 of the next month is the last day
// of this one; walk back to Sunday from there.
DateTime _lastSundayAtOneUtc(int year, int month) {
  var d = DateTime.utc(year, month + 1, 0, 1);
  while (d.weekday != DateTime.sunday) {
    d = d.subtract(const Duration(days: 1));
  }
  return d;
}
