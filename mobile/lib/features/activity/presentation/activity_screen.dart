import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/freshness/stale_data.dart';
import '../../../core/security/secure_screen.dart';
import '../../../core/time/time_format.dart';
import '../../../core/time/zoned_time.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../home/application/home_controller.dart';
import '../../incidents/application/incident_context.dart';
import '../application/activity_controller.dart';
import '../application/activity_grouping.dart';
import '../data/activity_repository.dart';
import 'activity_labels.dart';

/// Settings > Activity: what happened on the account, newest first and grouped by day
/// (USER_FLOWS.md §11): check-ins, who viewed what was shared, changes to the plan and to
/// the account's security.
///
/// The server sends what happened; the words are composed here (`describeActivity`).
/// Instruction titles are the owner's content, so the window is `FLAG_SECURE` only while
/// an entry that names one is on screen.
class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final feed = ref.watch(activityControllerProvider);
    final controller = ref.read(activityControllerProvider.notifier);
    final timezone = ref.watch(incidentTimezoneProvider);

    Future<void> refresh() async {
      final messenger = ScaffoldMessenger.of(context);
      final failure = await controller.reload();
      if (failure != null) {
        messenger.showSnackBar(
          SnackBar(content: Text(failureMessage(l10n, failure))),
        );
      }
    }

    final items = feed.value?.items ?? const [];
    final showsTitle = items.any(
      (item) => describeActivity(l10n, item.action, item.params).showsTitle,
    );

    return SecureScreen(
      enabled: showsTitle,
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.settingsActivity)),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: refresh,
            child: CenteredScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: feed.when(
                skipLoadingOnReload: true,
                loading: () => const LoadingView(),
                error: (error, _) => ErrorView(
                  failure: error is AppFailure
                      ? error
                      : UnknownFailure(cause: error),
                  onRetry: () => unawaited(controller.reload()),
                ),
                data: (state) => state.items.isEmpty
                    ? EmptyState(
                        icon: Icons.history_rounded,
                        title: l10n.activityEmptyTitle,
                        message: l10n.activityEmptyBody,
                      )
                    : _ActivityList(
                        state: state,
                        timezone: timezone,
                        onMore: () => unawaited(controller.loadMore()),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActivityList extends ConsumerWidget {
  const _ActivityList({
    required this.state,
    required this.timezone,
    required this.onMore,
  });

  final ActivityState state;
  final String? timezone;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(serverNowProvider)();
    final days = groupActivityByDay(state.items, timezone: timezone);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const StaleDataNote(area: DataArea.activity),
        if (timezone != null) ...[
          BodyText(l10n.scheduleTimezoneNote(timezone!)),
          Gap.sm,
        ],
        for (final day in days) ...[
          _DayHeader(
            label: _dayLabel(context, l10n, day, now: now, timezone: timezone),
          ),
          for (final item in day.items)
            _ActivityRow(item: item, timezone: timezone),
          Gap.sm,
        ],
        if (state.moreFailure != null) ...[
          Gap.sm,
          FailureNotice.of(context, state.moreFailure!),
        ],
        if (state.hasMore) ...[
          Gap.sm,
          AppButton.secondary(
            label: l10n.historyLoadMore,
            isLoading: state.loadingMore,
            onPressed: onMore,
            expand: true,
          ),
        ],
      ],
    );
  }

  static String _dayLabel(
    BuildContext context,
    AppLocalizations l10n,
    ActivityDay day, {
    required DateTime now,
    required String? timezone,
  }) {
    final instant = day.items.first.occurredAt;
    return switch (calendarDaysBetween(now, instant, timezone)) {
      0 => l10n.activityDayToday,
      -1 => l10n.activityDayYesterday,
      _ => MaterialLocalizations.of(
        context,
      ).formatFullDate(inTimezone(instant, timezone)),
    };
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
      child: Semantics(
        header: true,
        child: Text(
          label,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(color: context.tokens.textMuted),
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.item, required this.timezone});

  final ActivityItem item;
  final String? timezone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final line = describeActivity(l10n, item.action, item.params);
    final time = formatClockTime(context, item.occurredAt, timezone: timezone);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: MergeSemantics(
        child: Semantics(
          label: line.semantics(time),
          excludeSemantics: true,
          child: Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(line.icon, color: t.textMuted),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(line.text, style: textTheme.bodyLarge),
                        for (final detail in line.details)
                          Padding(
                            padding: const EdgeInsets.only(top: AppSpacing.xxs),
                            child: Text(
                              detail,
                              style: textTheme.bodyMedium?.copyWith(
                                color: t.textMuted,
                              ),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xxs),
                          child: Text(
                            time,
                            style: textTheme.bodySmall?.copyWith(
                              color: t.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
