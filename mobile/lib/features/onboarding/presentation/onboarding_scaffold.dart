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
    final t = context.tokens;
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        progress,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: t.textMuted),
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      LinearProgressIndicator(
                        value: number / onboardingTotalSteps,
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                    ],
                  ),
                ),
              ),
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
