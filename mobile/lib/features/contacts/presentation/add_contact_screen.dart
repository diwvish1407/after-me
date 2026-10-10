import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/contacts_controller.dart';
import 'contact_form.dart';

/// Add a trusted contact: saves, queues the invitation, and opens the new contact,
/// whose status is Pending until they accept.
class AddContactScreen extends ConsumerWidget {
  const AddContactScreen({super.key});

  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    ContactFormValues values,
  ) async {
    final contact = await ref
        .read(contactsControllerProvider.notifier)
        .addContact(values.toDraft());
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).contactAdded(contact.email)),
      ),
    );
    context.pushReplacement(AppRoutes.contactDetail(contact.id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return FormPage(
      title: l10n.contactAddTitle,
      children: [
        PageHeading(l10n.contactStepTitle),
        Gap.xs,
        BodyText(l10n.contactStepBody),
        Gap.lg,
        ContactForm(
          submitLabel: l10n.contactFormSendInvite,
          onSubmit: (values) => _save(context, ref, values),
        ),
      ],
    );
  }
}
