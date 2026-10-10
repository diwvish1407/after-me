import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/application/me_controller.dart';
import '../application/checkin_history_controller.dart';
import '../data/models/checkin_models.dart';

/// Settings > Check-in history: every check-in the server recorded, newest first, with
/// its date and time in the profile's timezone and where it came from.
class CheckInHistoryScreen extends ConsumerWidget {
  const CheckInHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final history = ref.watch(checkInHistoryControllerProvider);
    final timezone = ref.watch(meControllerProvider).value?.profile.timezone;
    final controller = ref.read(checkInHistoryControllerProvider.notifier);

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
      appBar: AppBar(title: Text(l10n.settingsCheckInHistory)),
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
                      title: l10n.historyEmptyTitle,
                      message: l10n.historyEmptyBody,
                    )
                  : _HistoryList(
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

class _HistoryList extends StatelessWidget {
  const _HistoryList({
    required this.state,
    required this.timezone,
    required this.onMore,
  });

  final CheckInHistoryState state;
  final String? timezone;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (timezone != null) ...[
          BodyText(l10n.scheduleTimezoneNote(timezone!)),
          Gap.sm,
        ],
        for (final item in state.items)
          _HistoryRow(item: item, timezone: timezone),
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

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.item, required this.timezone});

  final CheckInHistoryItem item;
  final String? timezone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final kind = switch (item.kind) {
      CheckInKind.ok => l10n.historyKindOk,
      CheckInKind.safe => l10n.historyKindSafe,
      CheckInKind.unknown => l10n.historyKindUnknown,
    };
    final source = switch (item.source) {
      CheckInSource.app => l10n.historySourceApp,
      CheckInSource.web => l10n.historySourceWeb,
      CheckInSource.unknown => l10n.historySourceUnknown,
    };
    final when = formatDateTime(context, item.receivedAt, timezone: timezone);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Semantics(
        container: true,
        excludeSemantics: true,
        label: l10n.historyRowSemantics(kind, when, source),
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(kind, style: textTheme.titleMedium),
                Text(when, style: textTheme.bodyMedium),
                Text(
                  source,
                  style: textTheme.bodyMedium?.copyWith(color: t.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
