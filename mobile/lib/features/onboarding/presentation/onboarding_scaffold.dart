import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/onboarding_controller.dart';

/// Total number of steps shown to the person: welcome, account, code, then the six
/// steps after the account exists (USER_FLOWS.md §3).
const int onboardingTotalSteps = 9;

/// The position (4-9) of [step] among the nine onboarding steps.
int stepNumber(OnboardingStep step) => step.index + 4;

/// Moves on after [step] was completed: to the furthest step reached so far while
/// onboarding is running (the next one in the normal flow, or back where the person came
/// from after a detour such as adding a contact from the plan step), or back to Home
/// when the step was opened later from the Home checklist.
Future<void> advanceFrom(
  BuildContext context,
  WidgetRef ref,
  OnboardingStep step,
) async {
  final controller = ref.read(onboardingControllerProvider.notifier);
  final wasRunning = ref.read(onboardingControllerProvider).needsOnboarding;
  await controller.completeStep(step);
  if (!context.mounted) {
    return;
  }
  final next = step.next;
  if (wasRunning && next != null) {
    context.go(ref.read(onboardingControllerProvider).step.path);
  } else {
    context.go(AppRoutes.home);
  }
}

/// The frame of an onboarding step: progress, title, body, and the actions at the end
/// of the page (so nothing is pinned or clipped at large text sizes).
class OnboardingScaffold extends StatelessWidget {
  const OnboardingScaffold({
    required this.step,
    required this.title,
    required this.children,
    this.subtitle,
    this.primaryLabel,
    this.onPrimary,
    this.primaryBusy = false,
    this.secondaryLabel,
    this.onSecondary,
    super.key,
  });

  final OnboardingStep step;
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final bool primaryBusy;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final number = stepNumber(step);
    final progress = l10n.onboardingStepOf(number, onboardingTotalSteps);
    return Scaffold(
      appBar: AppBar(
        // A back arrow only when the step was opened from Home (there is a page to go
        // back to); during onboarding itself the steps replace each other.
        automaticallyImplyLeading: true,
        title: Text(l10n.onboardingTitle),
      ),
      body: SafeArea(
        child: CenteredScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                container: true,
                label: progress,
                child: ExcludeSemantics(
                  child: Column(
                    children: [
                      _Stepper(step: step),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        progress,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: context.tokens.textMuted),
                      ),
                    ],
                  ),
                ),
              ),
              Gap.md,
              Center(child: BrandImage(_art(step), height: 120)),
              Gap.lg,
              PageHeading(title),
              if (subtitle != null) ...[Gap.xs, BodyText(subtitle!)],
              Gap.lg,
              ...children,
              if (primaryLabel != null) ...[
                Gap.lg,
                AppButton.primary(
                  label: primaryLabel!,
                  onPressed: onPrimary,
                  isLoading: primaryBusy,
                  expand: true,
                ),
              ],
              if (secondaryLabel != null) ...[
                Gap.xs,
                AppButton.secondary(
                  label: secondaryLabel!,
                  onPressed: primaryBusy ? null : onSecondary,
                  expand: true,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

BrandIllustration _art(OnboardingStep step) => switch (step) {
  OnboardingStep.contact => BrandIllustration.welcomeDecide,
  OnboardingStep.schedule => BrandIllustration.calendarClock,
  OnboardingStep.plan => BrandIllustration.planClipboard,
  OnboardingStep.instruction => BrandIllustration.welcomePrepare,
  OnboardingStep.protect => BrandIllustration.securityShield,
  OnboardingStep.done => BrandIllustration.shieldHeart,
};

/// Contacts · Schedule · Plan · Done, as in the design (the instruction step belongs to
/// "Plan", the protection step to "Done").
class _Stepper extends StatelessWidget {
  const _Stepper({required this.step});

  final OnboardingStep step;

  int get _current => switch (step) {
    OnboardingStep.contact => 0,
    OnboardingStep.schedule => 1,
    OnboardingStep.plan || OnboardingStep.instruction => 2,
    OnboardingStep.protect || OnboardingStep.done => 3,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final labels = [
      l10n.onboardingStepContacts,
      l10n.onboardingStepSchedule,
      l10n.onboardingStepPlan,
      l10n.onboardingStepDone,
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 2,
                        color: i == 0
                            ? Colors.transparent
                            : (i <= _current ? t.primary : t.border),
                      ),
                    ),
                    Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i <= _current ? t.primary : t.surface,
                        border: Border.all(
                          color: i <= _current ? t.primary : t.outline,
                          width: 2,
                        ),
                      ),
                      child: i < _current
                          ? Icon(
                              Icons.check_rounded,
                              size: 18,
                              color: t.onPrimary,
                            )
                          : Text(
                              '${i + 1}',
                              style: text.labelMedium?.copyWith(
                                color: i == _current
                                    ? t.onPrimary
                                    : t.textMuted,
                              ),
                            ),
                    ),
                    Expanded(
                      child: Container(
                        height: 2,
                        color: i == labels.length - 1
                            ? Colors.transparent
                            : (i < _current ? t.primary : t.border),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  labels[i],
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelSmall?.copyWith(
                    color: i == _current ? t.text : t.textMuted,
                    fontWeight: i == _current ? FontWeight.w700 : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
