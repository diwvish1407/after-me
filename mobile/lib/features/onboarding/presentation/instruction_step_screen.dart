import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/design_system/design_system.dart';
import '../../../core/security/secure_screen.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../../instructions/application/instruction_autosave.dart';
import '../../instructions/application/instructions_controller.dart';
import '../../instructions/presentation/instruction_form.dart';
import '../../instructions/presentation/instruction_starter_cards.dart';
import '../../instructions/presentation/instruction_starters.dart';
import '../application/onboarding_controller.dart';
import '../application/setup_controller.dart';
import 'onboarding_scaffold.dart';

/// Step 7 (optional): write the first instruction. The same create flow as the
/// Instructions tab (category, title, text, who receives it, when), against the real
/// instructions API, started from one of six examples or from a blank page. The step can
/// be skipped. The window is `FLAG_SECURE` while the person writes (FR-INS-06).
class InstructionStepScreen extends ConsumerStatefulWidget {
  const InstructionStepScreen({super.key});

  @override
  ConsumerState<InstructionStepScreen> createState() =>
      _InstructionStepScreenState();
}

class _InstructionStepScreenState extends ConsumerState<InstructionStepScreen> {
  InstructionStarter? _starter;

  /// The form is open (with an example, or blank). A draft that was kept in memory
  /// reopens it directly.
  late bool _writing;

  @override
  void initState() {
    super.initState();
    final draft = ref.read(instructionAutosaveProvider);
    _writing = draft != null && draft.editingId == null;
  }

  /// Saves it. While check-ins are off (onboarding) the server never asks for the
  /// password; if it does (an account that is already on), the same save is repeated
  /// once after it, plan stage and all.
  Future<bool> _save(BuildContext context, InstructionFormValues values) async {
    final controller = ref.read(setupControllerProvider.notifier);
    final saved = await withReauth(context, () async {
      await controller.createInstruction(
        category: values.category,
        title: values.title,
        body: values.body,
        recipients: values.recipients,
      );
      return true;
    }, reason: instructionSaveReason(values));
    if (saved == null) {
      return false;
    }
    if (mounted && context.mounted) {
      await advanceFrom(context, ref, OnboardingStep.instruction);
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final setup =
        ref.watch(setupControllerProvider).value ?? const SetupState();
    // The list is read here, where it is used (and not at start-up for Home): what was
    // just saved is known to the setup controller even while the list waits for the
    // password.
    final saved =
        ref.watch(instructionsControllerProvider).value ?? setup.instructions;
    if (saved.isNotEmpty) {
      // The title is content, so this page is secure too.
      return SecureScreen(
        child: OnboardingScaffold(
          step: OnboardingStep.instruction,
          title: l10n.instructionStepTitle,
          subtitle: l10n.instructionStepSaved(saved.first.title),
          primaryLabel: l10n.actionContinue,
          onPrimary: () =>
              advanceFrom(context, ref, OnboardingStep.instruction),
          children: const [],
        ),
      );
    }
    if (!_writing) {
      return OnboardingScaffold(
        step: OnboardingStep.instruction,
        title: l10n.instructionStepTitle,
        subtitle: l10n.instructionStepBody,
        secondaryLabel: l10n.actionSkipForNow,
        onSecondary: () =>
            advanceFrom(context, ref, OnboardingStep.instruction),
        children: [
          for (final starter in InstructionStarter.featured)
            StarterCard(
              starter: starter,
              onTap: () => setState(() {
                _starter = starter;
                _writing = true;
              }),
            ),
          AppButton.text(
            label: l10n.instructionsWriteOwn,
            onPressed: () => setState(() {
              _starter = null;
              _writing = true;
            }),
            expand: true,
          ),
          Gap.sm,
          BodyText(l10n.instructionPasswordNote),
        ],
      );
    }
    return SecureScreen(
      child: OnboardingScaffold(
        step: OnboardingStep.instruction,
        title: l10n.instructionStepTitle,
        subtitle: l10n.instructionWriteBody,
        secondaryLabel: l10n.actionSkipForNow,
        onSecondary: () =>
            advanceFrom(context, ref, OnboardingStep.instruction),
        children: [
          InstructionForm(
            starter: _starter,
            submitLabel: l10n.instructionSave,
            // The contact just added is the natural first recipient.
            suggestedRecipientIds: {for (final c in setup.contacts) c.id},
            onSubmit: (values) => _save(context, values),
            onAddContact: () => context.go(OnboardingStep.contact.path),
            onReviewPlan: () => context.go(OnboardingStep.plan.path),
          ),
          Gap.md,
          AppButton.text(
            label: l10n.instructionChooseAnother,
            onPressed: () => setState(() => _writing = false),
            expand: true,
          ),
        ],
      ),
    );
  }
}
