import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/app_button.dart';
import '../../../core/design_system/brand.dart';
import '../../../core/design_system/error_view.dart';
import '../../../core/design_system/form_page.dart';
import '../../../core/design_system/loading_view.dart';
import '../../../core/time/clock.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../shell/presentation/home_back_button.dart';
import '../application/events_controller.dart';
import '../application/schedule_controller.dart';
import '../data/events_repository.dart';
import '../data/models/checkin_models.dart';
import 'schedule_labels.dart';

/// The Check-in tab (design screen 09 and the bottom navigation): the main schedule,
/// the extra check-in times (each with its own plan or the main one) and the history.
class CheckInHubScreen extends ConsumerWidget {
  const CheckInHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final schedule = ref.watch(scheduleControllerProvider);
    final events = ref.watch(eventsControllerProvider);
    return BrandPage(
      title: l10n.checkInHubTitle,
      leading: const HomeBackButton(),
      onRefresh: () async {
        await Future.wait([
          ref.read(scheduleControllerProvider.notifier).reload(),
          ref.read(eventsControllerProvider.notifier).reload(),
        ]);
      },
      children: [
        const Center(
          child: BrandImage(BrandIllustration.calendarClock, height: 120),
        ),
        Gap.md,
        _MainCard(schedule: schedule),
        Gap.lg,
        _EventsSection(events: events, timezone: schedule.value?.timezone),
        Gap.lg,
        AppButton.secondary(
          label: l10n.checkInHubHistory,
          icon: Icons.history_rounded,
          onPressed: () => context.push(AppRoutes.checkInHistory),
          expand: true,
        ),
      ],
    );
  }
}

class _MainCard extends ConsumerWidget {
  const _MainCard({required this.schedule});

  final AsyncValue<ScheduleSnapshot?> schedule;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final t = context.tokens;
    final value = schedule.value;
    if (value == null) {
      if (schedule.hasError) {
        final error = schedule.error;
        return ErrorView(
          failure: error is AppFailure ? error : UnknownFailure(cause: error),
          onRetry: () => ref.read(scheduleControllerProvider.notifier).reload(),
        );
      }
      return const LoadingView();
    }
    final due = value.nextDueAt;
    final now = ref.read(clockProvider)();
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.alarm_rounded, color: t.primary),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    l10n.checkInHubMainTitle,
                    style: text.titleMedium,
                  ),
                ),
              ),
            ],
          ),
          Gap.sm,
          Text(
            scheduleSummaryText(
              l10n,
              intervalDays: value.intervalDays,
              intervalMinutes: value.intervalMinutes,
              dueTime: formatMinutesOfDay(context, value.dueMinutes),
            ),
            style: text.bodyLarge,
          ),
          Gap.xs,
          Text(
            value.isOn && due != null
                ? l10n.checkInHubNext(
                    formatDayTime(
                      context,
                      l10n,
                      due,
                      now: now,
                      timezone: value.timezone,
                    ),
                  )
                : l10n.checkInHubOff,
            style: text.bodyMedium?.copyWith(color: t.textMuted),
          ),
          Gap.md,
          AppButton.primary(
            label: l10n.checkInHubEdit,
            icon: Icons.tune_rounded,
            onPressed: () => context.push(AppRoutes.checkInSchedule),
            expand: true,
          ),
        ],
      ),
    );
  }
}

class _EventsSection extends ConsumerWidget {
  const _EventsSection({required this.events, required this.timezone});

  final AsyncValue<CheckInEventList?> events;
  final String? timezone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final t = context.tokens;
    final list = events.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(l10n.checkInHubEventsTitle, style: text.titleMedium),
        ),
        Gap.xs,
        Text(
          l10n.checkInHubEventsBody,
          style: text.bodyMedium?.copyWith(color: t.textMuted),
        ),
        Gap.md,
        if (list == null && events.hasError)
          ErrorView(
            failure: events.error is AppFailure
                ? events.error! as AppFailure
                : UnknownFailure(cause: events.error),
            onRetry: () => ref.read(eventsControllerProvider.notifier).reload(),
          )
        else if (list == null)
          const LoadingView()
        else ...[
          if (list.items.isEmpty)
            Text(l10n.checkInHubNoEvents, style: text.bodyMedium)
          else
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Column(
                children: [
                  for (final event in list.items)
                    SetupRow(
                      icon: Icons.schedule_rounded,
                      color: t.primary,
                      title: event.label,
                      subtitle:
                          '${eventFrequencyLabel(context, l10n, event)} · ${event.hasOwnPlan ? l10n.eventOwnPlan : l10n.eventMainPlan}',
                      onTap: () =>
                          context.push(AppRoutes.checkInEvent(event.id)),
                    ),
                ],
              ),
            ),
          Gap.md,
          if (list.full)
            Text(
              l10n.checkInHubEventLimit,
              style: text.bodySmall?.copyWith(color: t.textMuted),
            )
          else
            AppButton.secondary(
              label: l10n.checkInHubAddEvent,
              icon: Icons.add_rounded,
              onPressed: () => context.push(AppRoutes.checkInEventNew),
              expand: true,
            ),
        ],
      ],
    );
  }
}

/// "Every day at 9:00 AM", "Every 3 days at 9:00 AM", "Every 4 hours".
String eventFrequencyLabel(
  BuildContext context,
  AppLocalizations l10n,
  CheckInEvent event,
) {
  final minutes = event.intervalMinutes;
  if (minutes != null) {
    return l10n.eventEveryMinutes(formatDurationMinutes(l10n, minutes));
  }
  final time = formatMinutesOfDay(context, parseLocalTime(event.dueLocalTime));
  return event.intervalDays == 1
      ? l10n.eventDaily(time)
      : l10n.eventEveryDays(event.intervalDays, time);
}
