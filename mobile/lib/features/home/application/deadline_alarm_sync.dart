import 'dart:ui';

import '../../../core/alarm/deadline_alarm.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../../l10n/gen/app_localizations_en.dart';
import '../../checkin/data/models/checkin_models.dart';
import 'home_controller.dart';

/// What the alarm should be for this Home aggregate: a device time to ring at, `null` to
/// cancel, or [AlarmPlan.keep] to leave things as they are.
sealed class AlarmPlan {
  const AlarmPlan();

  static const AlarmPlan keep = _Keep();
}

class _Keep extends AlarmPlan {
  const _Keep();
}

class AlarmAt extends AlarmPlan {
  const AlarmAt(this.deviceTime);

  final DateTime deviceTime;
}

class AlarmCancel extends AlarmPlan {
  const AlarmCancel();
}

/// Decides the alarm from what the server said. Check-ins on with a deadline: ring at that
/// deadline, moved to the phone's clock with the server offset. Check-ins off, or signed
/// out: no alarm. A missed check-in (incident open): the alarm already rang, keep it.
AlarmPlan alarmPlanFor(HomeData? data) {
  if (data == null) {
    return const AlarmCancel();
  }
  final checkIn = data.snapshot.checkin;
  final due = checkIn.nextDueAt;
  return switch (checkIn.status) {
    CheckInStatus.active when due != null => AlarmAt(
      due.subtract(data.serverOffset).toLocal(),
    ),
    CheckInStatus.incidentOpen || CheckInStatus.unknown => AlarmPlan.keep,
    _ => const AlarmCancel(),
  };
}

DeadlineAlarmText deadlineAlarmText() {
  final locale = PlatformDispatcher.instance.locale;
  final AppLocalizations l10n = AppLocalizations.delegate.isSupported(locale)
      ? lookupAppLocalizations(locale)
      : AppLocalizationsEn();
  return DeadlineAlarmText(
    channelName: l10n.alarmChannelName,
    channelDescription: l10n.alarmChannelDescription,
    title: l10n.alarmTitle,
    body: l10n.alarmBody,
  );
}

/// Applies [plan] to [alarm].
Future<void> applyAlarmPlan(DeadlineAlarm alarm, AlarmPlan plan) =>
    switch (plan) {
      AlarmAt(:final deviceTime) => alarm.set(deviceTime, deadlineAlarmText()),
      AlarmCancel() => alarm.cancel(),
      _Keep() => Future<void>.value(),
    };
