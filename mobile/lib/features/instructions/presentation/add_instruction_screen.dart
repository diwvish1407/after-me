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
import 'instruction_form.dart';
import 'instruction_starters.dart';

/// Write a new instruction (USER_FLOWS §9): category, title, text, who receives it and
/// when. [starterName] is the example the person picked on the empty tab (the name of an
/// [InstructionStarter], passed as the route's `extra`); anything else is ignored.
///
/// The screen shows what is being written, so the window is `FLAG_SECURE` while it is
/// open. What is typed is kept in memory only, so leaving to add a contact or review the
/// plan loses nothing.
class AddInstructionScreen extends ConsumerWidget {
  const AddInstructionScreen({this.starterName, super.key});

  final String? starterName;

  /// Saves it; false when the password sheet was closed (nothing saved, nothing said).
  /// Choosing recipients while check-ins are on asks for the password (403
  /// `reauth_required`): the sheet is shown once and the same save repeated. A time the
  /// plan has no stage for yet is added to the plan first, in the same attempt and under
  /// the same password. An instruction with nobody to receive it never asks.
  Future<bool> _save(
    BuildContext context,
    WidgetRef ref,
    InstructionFormValues values,
  ) async {
    final controller = ref.read(instructionsControllerProvider.notifier);
    final created = await withReauth(
      context,
      () => controller.addInstructionWithTimes(
        category: values.category,
        title: values.title,
        body: values.body,
        recipients: values.recipients,
      ),
      reason: instructionSaveReason(values),
    );
    if (created == null) {
      return false;
    }
    if (!context.mounted) {
      return true;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).instructionAdded)),
    );
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.instructions);
    }
    return true;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final starter = InstructionStarter.values
        .where((s) => s.name == starterName)
        .firstOrNull;
    return SecureScreen(
      child: FormPage(
        title: l10n.instructionAddTitle,
        children: [
          InstructionForm(
            starter: starter,
            submitLabel: l10n.instructionSave,
            onSubmit: (values) => _save(context, ref, values),
            // The Instructions branch keeps this page: coming back finds it as it was.
            onAddContact: () => context.go(AppRoutes.peopleAdd),
            onReviewPlan: () => context.push(OnboardingStep.plan.path),
          ),
        ],
      ),
    );
  }
}
