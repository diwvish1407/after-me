import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/security/secure_screen.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../../onboarding/application/onboarding_controller.dart';
import '../application/instructions_controller.dart';
import '../data/instructions_repository.dart';
import 'instruction_by_id_view.dart';
import 'instruction_form.dart';

/// Edit an instruction. Only what changed is sent; the recipients, when they changed,
/// are sent whole. Pops with `true` when something was saved.
class EditInstructionScreen extends ConsumerWidget {
  const EditInstructionScreen({required this.instructionId, super.key});

  final String instructionId;

  /// Saves what changed; false when the password sheet was closed. Changing who
  /// receives it, or switching it off, while check-ins are on asks for the password (403
  /// `reauth_required`): the sheet is shown once and the same change repeated. Editing
  /// only the text or the category never asks. A time the plan has no stage for yet is
  /// added to the plan first, in the same attempt and under the same password.
  Future<bool> _save(
    BuildContext context,
    WidgetRef ref,
    Instruction instruction,
    InstructionFormValues values,
  ) async {
    final l10n = AppLocalizations.of(context);
    final fields = instructionFieldChanges(instruction, values);
    final recipientsChanged = instructionRecipientsChanged(instruction, values);
    final changed = !fields.isEmpty || recipientsChanged;
    if (changed) {
      final controller = ref.read(instructionsControllerProvider.notifier);
      final updated = await withReauth(
        context,
        () => recipientsChanged
            ? controller.updateInstructionWithTimes(
                instruction.id,
                fields,
                recipients: values.recipients,
              )
            : controller.updateInstruction(instruction.id, fields),
        reason: recipientsChanged ? instructionSaveReason(values) : null,
      );
      if (updated == null) {
        // The sheet was closed: nothing was saved, the edits stay and nothing is said.
        return false;
      }
      if (!context.mounted) {
        return true;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.instructionUpdated)));
    }
    if (context.mounted) {
      context.pop(changed);
    }
    return true;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return SecureScreen(
      child: InstructionByIdView(
        id: instructionId,
        title: l10n.instructionEditTitle,
        builder: (context, instruction, holder) => FormPage(
          title: l10n.instructionEditTitle,
          children: [
            InstructionForm(
              initial: instruction,
              submitLabel: l10n.instructionSaveChanges,
              onSubmit: (values) => _save(context, ref, instruction, values),
              onAddContact: () => context.go(AppRoutes.peopleAdd),
              onReviewPlan: () => context.push(OnboardingStep.plan.path),
            ),
          ],
        ),
      ),
    );
  }
}
