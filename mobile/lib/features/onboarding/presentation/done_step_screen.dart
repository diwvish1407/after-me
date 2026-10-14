import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../checkin/presentation/schedule_labels.dart';
import '../../contacts/presentation/contact_labels.dart';
import '../../instructions/application/instructions_controller.dart';
import '../application/onboarding_controller.dart';
import '../application/setup_controller.dart';
import 'onboarding_scaffold.dart';

/// Step 9: you're set. Turns the schedule on when everything needed is in place. When
/// the server says something is missing (`no_contacts`, `no_stages`, `stage_empty`) the
/// step says what in plain words and offers the step that fixes it.
class DoneStepScreen extends ConsumerStatefulWidget {
  const DoneStepScreen({super.key});

  @override
  ConsumerState<DoneStepScreen> createState() => _DoneStepScreenState();
}

class _DoneStepScreenState extends ConsumerState<DoneStepScreen> {
  bool _activating = true;
  ActivationOutcome? _outcome;
  AppFailure? _failure;

  bool get _activated => _outcome?.activated ?? false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_activate);
  }

  Future<void> _activate() async {
    setState(() {
      _activating = true;
      _failure = null;
    });
    try {
      final controller = ref.read(setupControllerProvider.notifier);
      await ref.read(setupControllerProvider.future);
      // The server decides whether check-ins can start and says what is missing.
      final outcome = await controller.activate();
      if (mounted) {
        setState(() {
          _activating = false;
          _outcome = outcome;
        });
      }
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(() {
          _activating = false;
          _failure = failure;
        });
      }
    }
  }

  Future<void> _finish() async {
    await ref.read(onboardingControllerProvider.notifier).finish();
    if (mounted) {
      context.go(AppRoutes.home);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final setup =
        ref.watch(setupControllerProvider).value ?? const SetupState();
    // Read here, where the summary shows it: Home never starts this read.
    final instructions =
        ref.watch(instructionsControllerProvider).value ?? setup.instructions;
    final schedule = setup.schedule;
    final first = setup.contacts.isEmpty ? null : setup.contacts.first;
    final String message;
    if (_activated && first != null) {
      message = l10n.doneActiveInvited(first.displayName);
    } else if (_activated) {
      message = l10n.doneActive;
    } else if (_outcome != null) {
      message = l10n.doneUnmet(activationMissingText(l10n, _outcome!.missing));
    } else {
      message = '';
    }
    return OnboardingScaffold(
      step: OnboardingStep.done,
      title: _activated ? l10n.doneTitleActive : l10n.doneTitle,
      primaryLabel: l10n.doneGoHome,
      primaryBusy: _activating,
      onPrimary: _finish,
      children: [
        if (_failure != null) ...[
          FailureNotice.of(context, _failure!),
          Gap.sm,
          AppButton.secondary(
            label: l10n.retry,
            onPressed: _activate,
            expand: true,
          ),
          Gap.md,
        ],
        if (message.isNotEmpty) ...[
          StatusBanner(
            kind: _activated
                ? StatusBannerKind.info
                : StatusBannerKind.attention,
            message: message,
            liveRegion: true,
          ),
          Gap.md,
        ],
        // What is missing, with the step that fixes it (contact first: a plan stage
        // needs someone to tell).
        if (_outcome != null && !_activated) ...[
          if (_outcome!.missing.contains('no_contacts')) ...[
            AppButton.secondary(
              label: l10n.checklistContact,
              onPressed: () => context.go(OnboardingStep.contact.path),
              expand: true,
            ),
            Gap.sm,
          ],
          if (_outcome!.missing.contains('no_stages') ||
              _outcome!.missing.contains('stage_empty')) ...[
            AppButton.secondary(
              label: l10n.checklistPlan,
              onPressed: () => context.go(OnboardingStep.plan.path),
              expand: true,
            ),
            Gap.sm,
          ],
        ],
        _SummaryRow(
          done: setup.hasContact,
          text: first == null
              ? l10n.summaryNoContact
              : l10n.summaryContact(
                  first.displayName,
                  contactRelationshipText(l10n, first).toLowerCase(),
                ),
        ),
        _SummaryRow(
          done: schedule != null,
          text: schedule == null
              ? l10n.summaryNoSchedule
              : l10n.scheduleSummary(
                  intervalLabel(l10n, schedule.intervalDays).toLowerCase(),
                  formatMinutesOfDay(context, schedule.dueMinutes),
                ),
        ),
        _SummaryRow(
          done: setup.hasPlan,
          text: setup.hasPlan
              ? l10n.summaryPlan(
                  formatDurationMinutes(l10n, setup.plan!.graceMinutes),
                )
              : l10n.summaryNoPlan,
        ),
        _SummaryRow(
          done: instructions.isNotEmpty,
          text: instructions.isEmpty
              ? l10n.summaryNoInstruction
              : l10n.summaryInstructions(instructions.length),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          l10n.doneReminder,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: t.textMuted),
        ),
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.done, required this.text});

  final bool done;
  final String text;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            done ? Icons.check_circle_outline : Icons.radio_button_unchecked,
            color: done ? t.ok : t.textMuted,
            semanticLabel: done ? l10n.statusDone : l10n.statusNotDone,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
