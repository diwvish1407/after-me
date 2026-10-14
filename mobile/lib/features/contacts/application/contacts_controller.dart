import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/session_epoch.dart';
import '../../../core/freshness/stale_data.dart';
import '../../home/application/home_inputs.dart';
import '../data/contacts_repository.dart';

/// Orders contacts like the server does: priority, then creation time.
List<TrustedContact> sortContacts(Iterable<TrustedContact> contacts) {
  final indexed = contacts.toList().asMap().entries.toList()
    ..sort((a, b) {
      final byPriority = a.value.priority.compareTo(b.value.priority);
      if (byPriority != 0) {
        return byPriority;
      }
      final aTime = a.value.createdAt;
      final bTime = b.value.createdAt;
      if (aTime != null && bTime != null) {
        final byTime = aTime.compareTo(bTime);
        if (byTime != 0) {
          return byTime;
        }
      }
      return a.key.compareTo(b.key);
    });
  return [for (final entry in indexed) entry.value];
}

/// The signed-in user's trusted contacts (`GET /contacts`) and every change to them.
///
/// The list is replaced only with what the server confirmed: a contact appears after a
/// successful create, changes after a successful update and disappears after a
/// successful delete. Every method throws an `AppFailure` on error. The plan limits are
/// re-read after a change to the number of contacts ([entitlementsProvider]).
class ContactsController extends AsyncNotifier<List<TrustedContact>> {
  /// A read or a change that was started for the account that signed out must never
  /// land in the one that signed in after it.
  final SessionEpoch _session = SessionEpoch();

  bool _alive(int session) => ref.mounted && _session.isCurrent(session);

  @override
  Future<List<TrustedContact>> build() async {
    _session.next();
    if (ref.watch(authControllerProvider) != AuthStatus.signedIn) {
      return const [];
    }
    // Home follows this counter (not this controller, whose read a listener would
    // start): the aggregate counts verified contacts.
    listenSelf((previous, next) {
      final before = previous?.value;
      final after = next.value;
      if (before != null && after != null && !listEquals(before, after)) {
        ref.read(homeInputChangesProvider.notifier).bump();
      }
    });
    final repository = ref.watch(contactsRepositoryProvider);
    try {
      return sortContacts(await repository.list());
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  ContactsRepository get _repository => ref.read(contactsRepositoryProvider);

  List<TrustedContact> get _current => state.value ?? const [];

  Future<T> _run<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  /// Reads the list again and returns the failure, or null. The list already on screen
  /// stays when the refresh fails (and People says it is the last information we have);
  /// with no list yet, the failure becomes the state.
  Future<AppFailure?> reload() async {
    final session = _session.current;
    if (!state.hasValue) {
      state = const AsyncLoading<List<TrustedContact>>();
    }
    try {
      final contacts = sortContacts(await _run(_repository.list));
      if (!_alive(session)) {
        return null;
      }
      state = AsyncData(contacts);
      ref.read(staleDataProvider.notifier).clear(DataArea.contacts);
      return null;
    } on AppFailure catch (failure) {
      if (!_alive(session)) {
        return null;
      }
      if (!state.hasValue) {
        state = AsyncError<List<TrustedContact>>(failure, StackTrace.current);
      } else {
        ref.read(staleDataProvider.notifier).mark(DataArea.contacts);
      }
      return failure;
    }
  }

  /// Adds a contact and queues the invitation.
  Future<TrustedContact> addContact(ContactDraft draft) async {
    final session = _session.current;
    final contact = await _run(() => _repository.create(draft));
    if (_alive(session)) {
      state = AsyncData(sortContacts([..._current, contact]));
      ref.invalidate(entitlementsProvider);
    }
    return contact;
  }

  /// Changes a contact. Changing the email re-invites (the server resets the status).
  ///
  /// While check-ins are on, changing the email of a contact who is in a plan stage or
  /// receives an active instruction, or switching such a contact off (`is_active` false),
  /// needs a recent password (403 `reauth_required`, SECURITY.md §7): wrap the call in
  /// `withReauth`. The list is left as it was, so the same call can be made again. Other
  /// edits never ask.
  Future<TrustedContact> updateContact(String id, ContactPatch patch) async {
    final session = _session.current;
    final contact = await _run(() => _repository.update(id, patch));
    if (_alive(session)) {
      _replace(contact);
    }
    return contact;
  }

  /// Removes a contact. While check-ins are on, removing a contact who is in a plan
  /// stage or receives an active instruction needs a recent password (403
  /// `reauth_required`, SECURITY.md §7): wrap the call in `withReauth`. The list is left
  /// as it was, so the same call can be made again. Someone who is in no stage and
  /// receives nothing never asks.
  Future<void> removeContact(String id) async {
    final session = _session.current;
    await _run(() => _repository.delete(id));
    if (!_alive(session)) {
      return;
    }
    state = AsyncData([
      for (final contact in _current)
        if (contact.id != id) contact,
    ]);
    ref.invalidate(entitlementsProvider);
  }

  /// Queues the invitation again, then reads the contact so the history is current.
  /// A failed re-read is ignored: the invitation was queued.
  Future<void> resendInvitation(String id) async {
    final session = _session.current;
    await _run(() => _repository.resendInvitation(id));
    try {
      final contact = await _repository.get(id);
      if (_alive(session)) {
        _replace(contact);
      }
    } on Object {
      // The invitation is queued; the history catches up on the next refresh.
    }
  }

  void _replace(TrustedContact updated) {
    state = AsyncData(
      sortContacts([
        for (final contact in _current)
          if (contact.id == updated.id) updated else contact,
      ]),
    );
  }
}

final contactsControllerProvider =
    AsyncNotifierProvider<ContactsController, List<TrustedContact>>(
      ContactsController.new,
    );

/// The plan limits and usage (`GET /me/entitlements`). Re-read whenever the number of
/// contacts changes. A failure leaves the limit unknown: the server still enforces it.
final entitlementsProvider = FutureProvider.autoDispose<Entitlements>((
  ref,
) async {
  if (ref.watch(authControllerProvider) != AuthStatus.signedIn) {
    throw StateError('not signed in');
  }
  try {
    return await ref.watch(contactsRepositoryProvider).entitlements();
  } on Object catch (error) {
    throw toAppFailure(error);
  }
});

/// What the People screen says about the readiness of the contacts (USER_FLOWS §4,
/// the contact-related readiness banners).
enum PeopleReadiness {
  /// Nothing to say.
  ready,

  /// Contacts exist but nobody has accepted yet.
  nobodyAccepted,

  /// Some contacts the plan depends on have not accepted yet.
  planWaiting,

  /// Contacts declined, opted out or could not be reached.
  unreachable,
}

/// The highest-priority readiness hint (unreachable, then waiting). With no contacts
/// the empty state speaks for itself. [planContactIds] are the contacts the plan notifies.
PeopleReadiness peopleReadiness(
  List<TrustedContact> contacts, {
  Set<String> planContactIds = const {},
}) {
  if (contacts.isEmpty) {
    return PeopleReadiness.ready;
  }
  final anyAccepted = contacts.any((c) => c.isAccepted);
  final affected = [
    for (final contact in contacts)
      if (!contact.isAccepted &&
          (!anyAccepted || planContactIds.contains(contact.id)))
        contact,
  ];
  if (affected.isEmpty) {
    return PeopleReadiness.ready;
  }
  if (affected.any((c) => c.isUnreachable)) {
    return PeopleReadiness.unreachable;
  }
  return anyAccepted
      ? PeopleReadiness.planWaiting
      : PeopleReadiness.nobodyAccepted;
}

/// How many contacts cannot be notified (declined, opted out or bounced).
int unreachableCount(List<TrustedContact> contacts) =>
    contacts.where((c) => c.isUnreachable).length;
