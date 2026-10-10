import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

bool _loaded = false;

tz.Location? _locationOf(String? id) {
  if (id == null || id.isEmpty) {
    return null;
  }
  if (!_loaded) {
    // The bundled tz database, with the legacy link names (`UTC`, `Asia/Calcutta`,
    // `Europe/Kiev`) that a phone or the server may use for a profile. Parsed once, in
    // a few milliseconds.
    tzdata.initializeTimeZones();
    _loaded = true;
  }
  try {
    return tz.getLocation(id);
  } on tz.LocationNotFoundException {
    return null;
  }
}

/// Whether [timezone] is an IANA name the bundled database knows.
bool isKnownTimezone(String? timezone) => _locationOf(timezone) != null;

/// The wall-clock reading of [instant] in the IANA zone [timezone] (the person's
/// profile timezone: check-in times are always shown there, never in whatever zone the
/// phone happens to be set to).
///
/// The result is only meant to be read through `year`, `month`, `day`, `hour` and
/// `minute`. An unknown or missing [timezone] falls back to the phone's zone, which is
/// the best remaining guess.
DateTime inTimezone(DateTime instant, String? timezone) {
  final location = _locationOf(timezone);
  if (location == null) {
    return instant.toLocal();
  }
  return tz.TZDateTime.from(instant.toUtc(), location);
}

/// How many calendar days [instant] is after [now] in [timezone]: 0 for the same day,
/// 1 for the next day, -1 for the day before.
int calendarDaysBetween(DateTime now, DateTime instant, String? timezone) {
  final a = inTimezone(now, timezone);
  final b = inTimezone(instant, timezone);
  return DateTime.utc(
    b.year,
    b.month,
    b.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
}
