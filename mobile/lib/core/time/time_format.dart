import 'package:material_ui/material_ui.dart';

import '../../l10n/gen/app_localizations.dart';
import 'zoned_time.dart';

/// "8:00 PM" (or "20:00" with a 24-hour setting) for a local time given as minutes
/// after midnight. Minutes beyond a day wrap.
String formatMinutesOfDay(BuildContext context, int minutes) {
  final wrapped = ((minutes % 1440) + 1440) % 1440;
  return MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay(hour: wrapped ~/ 60, minute: wrapped % 60),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
}

/// A time that may fall on a later day: "11:00 PM", "1:00 AM the next day" or
/// "8:00 PM, 2 days later".
String formatMinutesWithDay(
  BuildContext context,
  AppLocalizations l10n,
  int minutes,
) {
  final time = formatMinutesOfDay(context, minutes);
  final days = minutes ~/ 1440;
  return switch (days) {
    0 => time,
    1 => l10n.timeNextDay(time),
    _ => l10n.timeDaysLater(time, days),
  };
}

/// "3 hours", "1 day", "90 minutes" for a duration in minutes.
String formatDurationMinutes(AppLocalizations l10n, int minutes) {
  if (minutes % 1440 == 0) {
    return l10n.durationDays(minutes ~/ 1440);
  }
  if (minutes % 60 == 0) {
    return l10n.durationHours(minutes ~/ 60);
  }
  return l10n.durationMinutes(minutes);
}

/// "Oct 8, 2026, 7:30 PM" for [instant] in [timezone] (an IANA name, normally the
/// profile timezone). Without a timezone the phone's own zone is used. The 12/24-hour
/// setting is always the phone's.
String formatDateTime(
  BuildContext context,
  DateTime instant, {
  String? timezone,
}) {
  final material = MaterialLocalizations.of(context);
  final local = timezone == null
      ? instant.toLocal()
      : inTimezone(instant, timezone);
  return '${material.formatMediumDate(local)}, '
      '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
}

/// "8:00 PM" for [instant] in [timezone].
String formatClockTime(
  BuildContext context,
  DateTime instant, {
  String? timezone,
}) {
  final local = timezone == null
      ? instant.toLocal()
      : inTimezone(instant, timezone);
  return MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay.fromDateTime(local),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
}

/// "Today · 8:00 PM", "Tomorrow · 8:00 PM", "Yesterday · 8:00 PM" or "Oct 16 · 8:00 PM"
/// for [instant], with the day counted in [timezone] from [now] (the server's idea of
/// now, not the phone's).
String formatDayTime(
  BuildContext context,
  AppLocalizations l10n,
  DateTime instant, {
  required DateTime now,
  String? timezone,
}) {
  final time = formatClockTime(context, instant, timezone: timezone);
  return switch (calendarDaysBetween(now, instant, timezone)) {
    0 => l10n.dayTimeToday(time),
    1 => l10n.dayTimeTomorrow(time),
    -1 => l10n.dayTimeYesterday(time),
    _ => l10n.dayTimeOther(_shortDate(context, instant, timezone), time),
  };
}

/// The same, as a phrase inside a sentence: "today at 8:00 PM", "tomorrow at 8:00 PM",
/// "on Oct 16 at 8:00 PM".
String formatSpokenDayTime(
  BuildContext context,
  AppLocalizations l10n,
  DateTime instant, {
  required DateTime now,
  String? timezone,
}) {
  final time = formatClockTime(context, instant, timezone: timezone);
  return switch (calendarDaysBetween(now, instant, timezone)) {
    0 => l10n.spokenToday(time),
    1 => l10n.spokenTomorrow(time),
    -1 => l10n.spokenYesterday(time),
    _ => l10n.spokenOther(_shortDate(context, instant, timezone), time),
  };
}

String _shortDate(BuildContext context, DateTime instant, String? timezone) =>
    MaterialLocalizations.of(context)
        .formatShortMonthDay(inTimezone(instant, timezone));

/// "less than a minute", "45 minutes", "1 hour", "1 hour 30 minutes" for a wait
/// (rounded up to whole minutes).
String formatUntil(AppLocalizations l10n, Duration wait) {
  final minutes = (wait.inSeconds / 60).ceil();
  if (minutes <= 0) {
    return l10n.untilLessThanMinute;
  }
  if (minutes < 60) {
    return l10n.durationMinutes(minutes);
  }
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0
      ? l10n.durationHours(hours)
      : l10n.durationHoursMinutes(hours, rest);
}
