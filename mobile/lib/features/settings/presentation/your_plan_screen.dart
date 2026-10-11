import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../contacts/application/contacts_controller.dart';
import '../../contacts/data/contacts_repository.dart';

/// Settings > Your plan: the tier, what it allows and what is used (`GET
/// /v1/me/entitlements`), in one calm sentence and as a short list. The server enforces
/// every limit; this only shows them. There is no purchase here yet (billing is a later
/// phase): the screen says so plainly instead of offering something that does not work.
class YourPlanScreen extends ConsumerWidget {
  const YourPlanScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final entitlements = ref.watch(entitlementsProvider);

    Future<void> refresh() async {
      ref.invalidate(entitlementsProvider);
      try {
        await ref.read(entitlementsProvider.future);
      } on Object {
        // The screen shows the failure (or the last information) itself.
      }
    }

    final data = entitlements.value;
    final Widget content;
    if (data != null) {
      content = _PlanView(entitlements: data, stale: entitlements.hasError);
    } else if (entitlements.hasError) {
      final error = entitlements.error;
      content = ErrorView(
        failure: error is AppFailure ? error : UnknownFailure(cause: error),
        onRetry: () => ref.invalidate(entitlementsProvider),
      );
    } else {
      content = const LoadingView();
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsYourPlan)),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: refresh,
          child: CenteredScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// The tier's name in the app's words. A tier this version does not know is "Your plan".
String tierName(AppLocalizations l10n, String tier) => switch (tier) {
  'free' => l10n.yourPlanTierFree,
  'premium' => l10n.yourPlanTierPremium,
  _ => l10n.yourPlanTierOther,
};

/// "Free · 1 of 1 contact · 0 of 3 instructions · 1 of 2 stages".
String planSummary(AppLocalizations l10n, Entitlements e) => [
  tierName(l10n, e.tier),
  l10n.yourPlanContactsOf(e.usage.contacts, e.limits.contacts),
  if (e.limits.instructions > 0)
    l10n.yourPlanInstructionsOf(e.usage.instructions, e.limits.instructions),
  if (e.limits.stages > 0)
    l10n.yourPlanStagesOf(e.usage.stages, e.limits.stages),
].join(' · ');

class _PlanView extends StatelessWidget {
  const _PlanView({required this.entitlements, required this.stale});

  final Entitlements entitlements;

  /// The latest refresh failed: what is shown is the last information we have.
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final e = entitlements;
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stale) ...[
          Semantics(
            liveRegion: true,
            container: true,
            child: StatusBanner(
              kind: StatusBannerKind.info,
              message: l10n.staleDataNote,
            ),
          ),
          Gap.md,
        ],
        Semantics(
          header: true,
          child: Text(tierName(l10n, e.tier), style: textTheme.headlineSmall),
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          planSummary(l10n, e),
          style: textTheme.bodyMedium?.copyWith(color: t.textMuted),
        ),
        Gap.md,
        SectionCard(
          title: l10n.yourPlanUsageTitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Row(
                label: l10n.yourPlanContacts,
                value: l10n.yourPlanUsed(e.usage.contacts, e.limits.contacts),
              ),
              if (e.limits.instructions > 0)
                _Row(
                  label: l10n.yourPlanInstructions,
                  value: l10n.yourPlanUsed(
                    e.usage.instructions,
                    e.limits.instructions,
                  ),
                ),
              if (e.limits.stages > 0)
                _Row(
                  label: l10n.yourPlanStages,
                  value: l10n.yourPlanUsed(e.usage.stages, e.limits.stages),
                ),
              _Row(
                label: l10n.yourPlanOwnTimes,
                value: e.limits.customOffsets
                    ? l10n.yourPlanIncluded
                    : l10n.yourPlanNotIncluded,
              ),
            ],
          ),
        ),
        Gap.md,
        if (e.isFree) ...[
          BodyText(l10n.yourPlanFreeNote),
          Gap.sm,
          // No purchase yet: say so, never a button that does nothing.
          Semantics(
            container: true,
            child: StatusBanner(
              kind: StatusBannerKind.info,
              message: l10n.yourPlanPremiumSoon,
            ),
          ),
        ] else
          BodyText(l10n.yourPlanPremiumNote),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    // The label above its value: a long word never has to share a line, so nothing is
    // broken in the middle at large text sizes.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: textTheme.bodySmall?.copyWith(color: t.textMuted),
            ),
            Text(value, style: textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}
