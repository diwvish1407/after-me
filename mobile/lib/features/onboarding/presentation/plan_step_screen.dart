import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../checkin/data/schedule_repository.dart';
import '../../plan/data/plan_repository.dart';
import '../../plan/presentation/plan_labels.dart';
import '../../plan/presentation/plan_preview.dart';
import '../application/onboarding_controller.dart';
import '../application/setup_controller.dart';
import 'onboarding_scaffold.dart';

/// Step 6: the plan. The "Standard" preset is pre-filled; changing the delay is optional.
/// "Use this plan" saves it through the plan API (`PUT /v1/plan`): the server checks it,
/// and what it says about the choices is explained here.
class PlanStepScreen extends ConsumerStatefulWidget {
  const PlanStepScreen({super.key});

  @override
  ConsumerState<PlanStepScreen> createState() => _PlanStepScreenState();
}

class _PlanStepScreenState extends ConsumerState<PlanStepScreen> {
  int? _grace;
  bool _busy = false;
  AppFailure? _failure;

  Future<void> _save(SetupState setup, int grace) async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await ref
          .read(setupControllerProvider.notifier)
          .savePlan(_draft(setup, grace));
      if (mounted) {
        await advanceFrom(context, ref, OnboardingStep.plan);
      }
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failure = failure;
        });
      }
    }
  }

  /// The preset with the chosen delay (a plan that already has more stages keeps them).
  PlanDraft _draft(SetupState setup, int grace) => PlanPresets.standard(
    setup.contacts,
    current: setup.plan,
    graceMinutes: grace,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final setup =
        ref.watch(setupControllerProvider).value ?? const SetupState();
    final saved = setup.plan;
    final savedGrace = saved != null && saved.stages.isNotEmpty
        ? saved.graceMinutes
        : null;
    final grace = _grace ?? savedGrace ?? PlanPresets.standardGraceMinutes;
    final schedule = setup.schedule ?? const CheckInSchedule();
    final preview = buildPlanPreview(
      context,
      dueMinutes: schedule.dueMinutes,
      plan: _draft(setup, grace),
      contacts: setup.contacts,
    );
    return OnboardingScaffold(
      step: OnboardingStep.plan,
      title: l10n.planStepTitle,
      subtitle: l10n.planStepBody,
      primaryLabel: setup.hasContact ? l10n.planStepUse : l10n.actionContinue,
      primaryBusy: _busy,
      onPrimary: setup.hasContact
          ? () => _save(setup, grace)
          : () => advanceFrom(context, ref, OnboardingStep.plan),
      secondaryLabel: setup.hasContact ? l10n.actionSkipForNow : null,
      onSecondary: () => advanceFrom(context, ref, OnboardingStep.plan),
      children: [
        if (_failure != null) ...[
          FailureNotice(message: planFailureMessage(l10n, _failure!)),
          Gap.md,
        ],
        SectionCard(
          title: l10n.planStandardName,
          subtitle: l10n.planStandardDescription,
          child: const SizedBox.shrink(),
        ),
        Gap.md,
        Semantics(
          header: true,
          child: Text(
            l10n.planGraceTitle,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        Gap.xs,
        Wrap(
          spacing: AppSpacing.xs,
          children: [
            // Only what the server's rules allow for this account: it refuses the rest.
            for (final minutes in PlanPresets.graceChoices(
              saved?.rules,
              current: savedGrace,
            ))
              ChoiceChip(
                label: Text(formatDurationMinutes(l10n, minutes)),
                selected: grace == minutes,
                onSelected: _busy
                    ? null
                    : (_) => setState(() => _grace = minutes),
              ),
          ],
        ),
        Gap.lg,
        Semantics(
          header: true,
          child: Text(
            l10n.planPreviewTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Gap.sm,
        if (setup.hasContact)
          PlanPreview(lines: preview)
        else ...[
          StatusBanner(
            kind: StatusBannerKind.attention,
            message: l10n.planNoContact,
            action: AppButton.text(
              label: l10n.planAddContact,
              onPressed: () => context.go(OnboardingStep.contact.path),
            ),
          ),
        ],
      ],
    );
  }
}
