import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../application/contacts_controller.dart';
import '../data/contacts_repository.dart';

/// Finds the contact with [id] in the contacts list and builds [builder] with it, with
/// calm loading, error (retry) and "not found" pages around it.
///
/// Once a contact has been seen, the last known version stays on screen if the list no
/// longer holds it: removing a contact then does not flash a "not found" page while the
/// screen slides away, and any later action on it fails with the normal calm message.
class ContactByIdView extends ConsumerStatefulWidget {
  const ContactByIdView({
    required this.id,
    required this.title,
    required this.builder,
    super.key,
  });

  final String id;

  /// App bar title of the loading, error and not-found pages.
  final String title;
  final Widget Function(BuildContext context, TrustedContact contact) builder;

  @override
  ConsumerState<ContactByIdView> createState() => _ContactByIdViewState();
}

class _ContactByIdViewState extends ConsumerState<ContactByIdView> {
  TrustedContact? _lastSeen;

  @override
  Widget build(BuildContext context) {
    final contacts = ref.watch(contactsControllerProvider);
    final list = contacts.value;
    if (list != null) {
      for (final contact in list) {
        if (contact.id == widget.id) {
          _lastSeen = contact;
        }
      }
    }
    final contact = _lastSeen;
    if (contact != null) {
      return widget.builder(context, contact);
    }
    return FormPage(
      title: widget.title,
      children: [
        if (list != null)
          const ErrorView(failure: NotFoundFailure())
        else if (contacts.hasError)
          ErrorView(
            failure: contacts.error is AppFailure
                ? contacts.error! as AppFailure
                : UnknownFailure(cause: contacts.error),
            onRetry: () => unawaited(
              ref.read(contactsControllerProvider.notifier).reload(),
            ),
          )
        else
          const LoadingView(),
      ],
    );
  }
}
