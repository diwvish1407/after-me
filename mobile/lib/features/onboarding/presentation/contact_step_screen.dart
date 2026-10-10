import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../contacts/data/contacts_repository.dart';
import '../../contacts/presentation/contact_form.dart';
import '../../contacts/presentation/contact_status_chip.dart';
import '../application/onboarding_controller.dart';
import '../application/setup_controller.dart';
import 'onboarding_scaffold.dart';

/// Step 4: your first trusted contact. The same form as People > Add, against the real
/// contacts API: saving queues the invitation. The step can be skipped, and a limit or
/// duplicate answer from the server is explained on the form.
class ContactStepScreen extends ConsumerWidget {
  const ContactStepScreen({super.key});

  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    ContactFormValues values,
  ) async {
    await ref
        .read(setupControllerProvider.notifier)
        .addContact(values.toDraft());
    if (context.mounted) {
      await advanceFrom(context, ref, OnboardingStep.contact);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final setup = ref.watch(setupControllerProvider).value;
    final existing = setup?.contacts ?? const <TrustedContact>[];
    if (existing.isNotEmpty) {
      final contact = existing.first;
      return OnboardingScaffold(
        step: OnboardingStep.contact,
        title: l10n.contactStepTitle,
        subtitle: l10n.contactStepInvited(contact.displayName),
        primaryLabel: l10n.actionContinue,
        onPrimary: () => advanceFrom(context, ref, OnboardingStep.contact),
        children: [
          Card(
            child: ListTile(
              minTileHeight: 64,
              leading: const Icon(Icons.person_outline_rounded),
              title: Text(contact.displayName),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: ContactStatusChip(status: contact.verificationStatus),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return OnboardingScaffold(
      step: OnboardingStep.contact,
      title: l10n.contactStepTitle,
      subtitle: l10n.contactStepBody,
      secondaryLabel: l10n.actionSkipForNow,
      onSecondary: () => advanceFrom(context, ref, OnboardingStep.contact),
      children: [
        ContactForm(
          submitLabel: l10n.contactStepSave,
          onSubmit: (values) => _save(context, ref, values),
        ),
        Gap.sm,
        BodyText(l10n.contactStepInviteNote),
      ],
    );
  }
}
