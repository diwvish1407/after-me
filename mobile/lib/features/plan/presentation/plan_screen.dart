import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/freshness/stale_data.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../checkin/application/schedule_controller.dart';
import '../../contacts/application/contacts_controller.dart';
import '../../contacts/data/contacts_repository.dart';
import '../../onboarding/application/onboarding_controller.dart';
import '../../settings/presentation/settings_widgets.dart';
import '../application/plan_controller.dart';
import '../data/plan_repository.dart';
import 'plan_preview.dart';

/// The Plan tab (USER_FLOWS.md §10): the grace period, who is told at each stage and
/// what would happen, as the server has it, and the way into the plan editor and into
/// the past incidents. A plan that has no stage yet is set up through the plan step
/// ("Set up your plan").
class PlanScreen extends ConsumerWidget {
  const PlanScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final plan = ref.watch(planControllerProvider);
    final data = plan.value;
    final Widget content;
    if (data != null) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StaleDataNote(area: DataArea.plan),
          if (data.stages.isEmpty) ...[
            const _NoPlan(),
            Gap.md,
            const _HistoryRow(),
          ] else
            _PlanView(plan: data),
        ],
      );
    } else if (plan.hasError) {
      content = ErrorView(
        failure: plan.error is AppFailure
            ? plan.error! as AppFailure
            : UnknownFailure(cause: plan.error),
        onRetry: () =>
            unawaited(ref.read(planControllerProvider.notifier).reload()),
      );
    } else {
      content = const LoadingView();
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.navPlan)),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => ref.read(planControllerProvider.notifier).reload(),
          child: CenteredScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// An account that has not made a plan: one action, the plan step.
class _NoPlan extends StatelessWidget {
  const _NoPlan();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return EmptyState(
      icon: Icons.timeline_outlined,
      title: l10n.planEmptyTitle,
      message: l10n.planEmptyBody,
      action: AppButton.primary(
        label: l10n.planSetUp,
        onPressed: () => context.push(OnboardingStep.plan.path),
      ),
    );
  }
}

/// "Past incidents": the same screen Settings opens (USER_FLOWS.md §10 puts the history
/// in the Plan tab, §11 in Settings), not a second copy of it.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SettingsTile(
      icon: Icons.history_rounded,
      title: l10n.settingsIncidents,
      subtitle: l10n.settingsIncidentsSubtitle,
      onTap: () => context.push(AppRoutes.settingsIncidents),
    );
  }
}

class _PlanView extends ConsumerWidget {
  const _PlanView({required this.plan});

  final Plan plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final contacts = ref.watch(contactsControllerProvider).value ?? const [];
    final schedule = ref.watch(scheduleControllerProvider).value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: l10n.planGraceCardTitle,
          child: Text(
            l10n.planGraceSentence(
              formatDurationMinutes(l10n, plan.graceMinutes),
            ),
          ),
        ),
        Gap.md,
        SectionCard(
          title: l10n.planStagesTitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final stage in plan.stages)
                _StageRow(stage: stage, contacts: contacts),
            ],
          ),
        ),
        Gap.md,
        AppButton.primary(
          label: l10n.planEditAction,
          icon: Icons.edit_outlined,
          onPressed: () => context.push(AppRoutes.planEdit),
          expand: true,
        ),
        if (schedule != null) ...[
          Gap.lg,
          Semantics(
            header: true,
            child: Text(
              l10n.planPreviewTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Gap.sm,
          PlanPreview(
            lines: buildPlanPreview(
              context,
              dueMinutes: schedule.dueMinutes,
              plan: plan.toDraft(),
              contacts: contacts,
              releaseCounts: {
                for (final stage in plan.stages) stage.id: stage.releaseCount,
              },
            ),
          ),
        ],
        Gap.lg,
        const _HistoryRow(),
      ],
    );
  }
}

/// One stage: its number and delay, and who is told (names the person gave, never ids).
class _StageRow extends StatelessWidget {
  const _StageRow({required this.stage, required this.contacts});

  final PlanStage stage;
  final List<TrustedContact> contacts;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final names = [
      for (final id in stage.contactIds)
        for (final contact in contacts)
          if (contact.id == id) contact.displayName,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.planStageTitle(
                stage.position,
                formatDurationMinutes(l10n, stage.offsetMinutes),
              ),
              style: textTheme.titleSmall,
            ),
            Text(
              names.isEmpty
                  ? l10n.planStageNobody
                  : l10n.planStageNotify(joinNames(l10n, names)),
            ),
            if (stage.releaseCount > 0)
              Text(l10n.planStageReleases(stage.releaseCount)),
          ],
        ),
      ),
    );
  }
}
