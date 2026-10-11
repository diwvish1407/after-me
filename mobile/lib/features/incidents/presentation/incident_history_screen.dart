import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/freshness/stale_data.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/incident_context.dart';
import '../application/incident_history_controller.dart';
import '../data/models/incident_models.dart';
import 'incident_labels.dart';

/// Settings > Past incidents: every missed check-in the server opened, newest first, and
/// how it ended in calm words. A row opens the incident with its timeline and what was
/// shared.
class IncidentHistoryScreen extends ConsumerWidget {
  const IncidentHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final history = ref.watch(incidentHistoryControllerProvider);
    final timezone = ref.watch(incidentTimezoneProvider);
    final controller = ref.read(incidentHistoryControllerProvider.notifier);

    Future<void> refresh() async {
      final messenger = ScaffoldMessenger.of(context);
      final failure = await controller.reload();
      if (failure != null) {
        messenger.showSnackBar(
          SnackBar(content: Text(failureMessage(l10n, failure))),
        );
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsIncidents)),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: refresh,
          child: CenteredScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: history.when(
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
                      title: l10n.incidentHistoryEmptyTitle,
                      message: l10n.incidentHistoryEmptyBody,
                    )
                  : _IncidentList(
                      state: state,
                      timezone: timezone,
                      onMore: () => unawaited(controller.loadMore()),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IncidentList extends StatelessWidget {
  const _IncidentList({
    required this.state,
    required this.timezone,
    required this.onMore,
  });

  final IncidentHistoryState state;
  final String? timezone;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const StaleDataNote(area: DataArea.incidents),
        if (timezone != null) ...[
          BodyText(l10n.scheduleTimezoneNote(timezone!)),
          Gap.sm,
        ],
        for (final item in state.items)
          _IncidentRow(item: item, timezone: timezone),
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
}

class _IncidentRow extends StatelessWidget {
  const _IncidentRow({required this.item, required this.timezone});

  final IncidentSummary item;
  final String? timezone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final title = l10n.incidentRowTitle(
      formatDateTime(context, item.missedDueAt, timezone: timezone),
    );
    final outcome = incidentOutcomeText(
      l10n,
      isClosed: item.isClosed,
      closedBy: item.closedBy,
      status: item.status,
      contactsMessaged: item.contactsMessaged,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Semantics(
        container: true,
        button: true,
        excludeSemantics: true,
        label: l10n.incidentRowSemantics(title, outcome),
        onTap: () => context.push(AppRoutes.incidentDetail(item.id)),
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.push(AppRoutes.incidentDetail(item.id)),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: textTheme.titleMedium),
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          outcome,
                          style: textTheme.bodyMedium?.copyWith(
                            color: t.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: t.textMuted),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
