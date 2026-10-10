import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../application/contacts_controller.dart';
import '../data/contacts_repository.dart';
import 'contact_by_id_view.dart';
import 'contact_form.dart';

/// Builds the smallest update that turns [contact] into [values]: only the fields that
/// changed, because an empty update is refused by the server. Null when nothing changed.
ContactPatch? contactPatchFor(
  TrustedContact contact,
  ContactFormValues values,
) {
  final emailChanged =
      values.email.trim().toLowerCase() != contact.email.trim().toLowerCase();
  final labelBefore = (contact.relationshipLabel?.trim().isEmpty ?? true)
      ? null
      : contact.relationshipLabel!.trim();
  // A description is only kept for "Other".
  final labelNow = values.relationship == ContactRelationship.other
      ? values.label
      : null;
  final labelChanged = labelNow != labelBefore;
  final phoneBefore = contact.phoneE164;
  final patch = ContactPatch(
    name: values.name.trim() == contact.displayName ? null : values.name,
    relationship: values.relationship == contact.relationship
        ? null
        : values.relationship,
    relationshipLabel: labelChanged ? labelNow : null,
    clearRelationshipLabel: labelChanged && labelNow == null,
    email: emailChanged ? values.email : null,
    phone: values.phone != phoneBefore ? values.phone : null,
    clearPhone: values.phone == null && phoneBefore != null,
  );
  return patch.isEmpty ? null : patch;
}

/// Edit a trusted contact. Changing the email address warns first and, once saved,
/// re-invites the new address. While check-ins are on, changing the address of someone
/// who is in the plan needs the password again (403 `reauth_required`): the sheet is
/// shown once and the same change repeated; closing it leaves the form as it was.
class EditContactScreen extends ConsumerWidget {
  const EditContactScreen({required this.contactId, super.key});

  final String contactId;

  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    TrustedContact contact,
    ContactFormValues values,
  ) async {
    final l10n = AppLocalizations.of(context);
    final patch = contactPatchFor(contact, values);
    if (patch != null) {
      final controller = ref.read(contactsControllerProvider.notifier);
      final updated = await withReauth(
        context,
        () => controller.updateContact(contact.id, patch),
        reason: ReauthReason.contactEmail,
      );
      if (!context.mounted) {
        return;
      }
      if (updated == null) {
        // The sheet was closed: nothing was saved, the edits stay and nothing is said.
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            patch.email == null
                ? l10n.contactUpdated
                : l10n.contactUpdatedReinvited(updated.email),
          ),
        ),
      );
    }
    if (context.mounted) {
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return ContactByIdView(
      id: contactId,
      title: l10n.contactEditTitle,
      builder: (context, contact) => FormPage(
        title: l10n.contactEditTitle,
        children: [
          ContactForm(
            initial: contact,
            submitLabel: l10n.contactFormSaveChanges,
            onSubmit: (values) => _save(context, ref, contact, values),
          ),
        ],
      ),
    );
  }
}
