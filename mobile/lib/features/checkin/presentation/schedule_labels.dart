import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';

/// Interval choices offered in the UI, in days. The server accepts 1-30; a value
/// outside this list (set from another device) is shown as an extra choice.
const List<int> scheduleIntervalChoices = [1, 2, 3, 7];

/// Reminder lead choices, in minutes before the deadline (0 = no reminder). The server
/// accepts any value from 0 to [maxReminderLeadMinutes]; "Custom" offers the rest.
const List<int> reminderLeadChoices = [0, 5, 15, 30, 60, 120, 240];

/// The longest reminder lead the server accepts (a day).
const int maxReminderLeadMinutes = 1440;

/// The shortest and longest custom interval the server accepts (1 minute to 30 days).
const int minIntervalMinutes = 1;
const int maxIntervalMinutes = 30 * 1440;

/// Suggested custom intervals, in minutes.
const List<int> customIntervalChoices = [5, 15, 30, 60, 120, 360, 720];

/// "Every day", "Every week", "Every 3 days".
String intervalLabel(AppLocalizations l10n, int days) => switch (days) {
  1 => l10n.intervalEveryDay,
  7 => l10n.intervalEveryWeek,
  _ => l10n.intervalEveryNDays(days),
};

/// The interval of a schedule: "Every day", or "Every 45 minutes" for a custom one.
String scheduleIntervalLabel(
  AppLocalizations l10n, {
  required int intervalDays,
  int? intervalMinutes,
}) => intervalMinutes == null
    ? intervalLabel(l10n, intervalDays)
    : l10n.intervalEveryDuration(formatDurationMinutes(l10n, intervalMinutes));

/// "Check in every day by 8:00 PM." or "Check in every 45 minutes."
String scheduleSummaryText(
  AppLocalizations l10n, {
  required int intervalDays,
  required int? intervalMinutes,
  required String dueTime,
}) => intervalMinutes == null
    ? l10n.scheduleSummary(
        intervalLabel(l10n, intervalDays).toLowerCase(),
        dueTime,
      )
    : l10n.scheduleSummaryCustom(formatDurationMinutes(l10n, intervalMinutes));

/// The reminder lead in minutes (0 = off) as a choice label: "No reminder",
/// "30 minutes before", "1 hour before".
String reminderChoiceLabel(AppLocalizations l10n, int minutes) => minutes <= 0
    ? l10n.reminderChoiceOff
    : l10n.reminderChoiceBefore(formatDurationMinutes(l10n, minutes));

/// The sentence about the reminder on the schedule step.
String reminderSentence(AppLocalizations l10n, int minutes) {
  if (minutes <= 0) {
    return l10n.scheduleReminderOff;
  }
  if (minutes == 60) {
    return l10n.scheduleReminder;
  }
  return l10n.scheduleReminderBefore(formatDurationMinutes(l10n, minutes));
}

/// The requirement codes of a 409 `activation_requirements_unmet`, in words: "a trusted
/// contact, a plan stage". A code this version does not know is "something else in
/// your plan" (said once), so the person is told something is missing without guessing.
/// `no_stages` is a plan without a stage; `stage_empty` is a plan whose stages tell no
/// one who is switched on.
String activationMissingText(AppLocalizations l10n, List<String> codes) {
  final items = <String>[];
  for (final code in codes) {
    final text = switch (code) {
      'no_contacts' => l10n.activationNoContacts,
      'no_stages' => l10n.activationNoStages,
      'stage_empty' => l10n.activationStageEmpty,
      _ => l10n.activationOther,
    };
    if (!items.contains(text)) {
      items.add(text);
    }
  }
  return items.join(', ');
}
