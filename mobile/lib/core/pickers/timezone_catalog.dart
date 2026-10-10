/// The timezones offered in the picker.
///
/// The platform list (Android's tz database) is used when available; otherwise a short
/// list of common zones. Only canonical `Area/City` identifiers (and `UTC`) are kept,
/// which the API accepts.
abstract final class TimezoneCatalog {
  static final RegExp _canonical = RegExp(
    r'^(?:UTC|(?:Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific)/[A-Za-z0-9_+\-/]+)$',
  );

  static const List<String> common = [
    'UTC',
    'Africa/Cairo',
    'Africa/Johannesburg',
    'Africa/Lagos',
    'Africa/Nairobi',
    'America/Anchorage',
    'America/Argentina/Buenos_Aires',
    'America/Bogota',
    'America/Chicago',
    'America/Denver',
    'America/Halifax',
    'America/Los_Angeles',
    'America/Mexico_City',
    'America/New_York',
    'America/Sao_Paulo',
    'America/Toronto',
    'America/Vancouver',
    'Asia/Bangkok',
    'Asia/Dhaka',
    'Asia/Dubai',
    'Asia/Hong_Kong',
    'Asia/Jakarta',
    'Asia/Karachi',
    'Asia/Kolkata',
    'Asia/Manila',
    'Asia/Seoul',
    'Asia/Shanghai',
    'Asia/Singapore',
    'Asia/Tokyo',
    'Australia/Melbourne',
    'Australia/Perth',
    'Australia/Sydney',
    'Europe/Amsterdam',
    'Europe/Berlin',
    'Europe/Dublin',
    'Europe/Istanbul',
    'Europe/Lisbon',
    'Europe/London',
    'Europe/Madrid',
    'Europe/Moscow',
    'Europe/Paris',
    'Europe/Rome',
    'Pacific/Auckland',
    'Pacific/Honolulu',
  ];

  /// A sorted, de-duplicated list; always contains [include] when it is valid.
  static List<String> choices(List<String> platform, {String? include}) {
    final source = platform.isEmpty ? common : platform;
    final set = <String>{
      for (final id in source)
        if (_canonical.hasMatch(id)) id,
      if (include != null && _canonical.hasMatch(include)) include,
    };
    return set.toList()..sort();
  }

  /// "America/New_York" -> "America/New York": underscores become spaces so a search
  /// for "new york" matches.
  static String label(String id) => id.replaceAll('_', ' ');
}
