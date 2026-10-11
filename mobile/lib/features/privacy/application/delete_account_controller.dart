import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/session_ended_notice.dart';
import '../../auth/application/me_controller.dart';
import '../../checkin/application/pending_checkin_store.dart';
import '../data/privacy_repository.dart';
import 'account_closed_notice.dart';
import 'local_account_data.dart';

/// The word the person types to confirm the deletion (the server accepts exactly this).
const deleteConfirmationWord = 'DELETE';

@immutable
class DeleteAccountState {
  const DeleteAccountState({this.outcomeUnknown = false});

  /// An earlier request ended without an answer (offline, a timeout, a server error): it
  /// may or may not have been carried out. The request is safe to repeat; if the next one
  /// is answered with 401 the account **may** be closed, and that is said as "we couldn't
  /// confirm", never as a fact.
  final bool outcomeUnknown;
}

/// How a request that ended the session came out.
enum AccountDeletionOutcome {
  /// The server answered 202: the account is closed. What the phone keeps about it is
  /// gone.
  closed,

  /// The request did not get its answer, and the next one was refused as 401. The account
  /// may be closed or may not: the session was ended and **nothing else was touched**.
  /// The next sign-in proves which it is.
  unconfirmed,
}

/// Closes the account (`DELETE /v1/me`) and puts this phone back to a clean sign-in.
///
/// It lives outside the screen on purpose: once the server answers 202 **every session
/// is already revoked**, the app is bounced to the sign-in routes by the router, and the
/// screen that asked is gone. Everything that must still happen (clearing what the phone
/// keeps, ending the local session, the final screen) is done here, in order, whatever
/// the screen is doing.
///
/// What the person is told follows only what the server confirmed:
/// * `202`: closed, with the purge date. Only this clears what the phone keeps.
/// * `401` **after** a request whose outcome was unknown: not confirmed. A 401 can also be
///   the session ending for an unrelated reason (log out everywhere, a password reset on
///   the web, a refresh token reused), with the account alive and its schedule running.
///   The person is signed out of the stale session, told plainly that it could not be
///   confirmed and that signing in again settles it, and **nothing is deleted** here: a
///   check-in the server has not confirmed is still sent after the next sign-in.
/// * everything else: not closed. The failure is thrown for the screen to word.
class DeleteAccountController extends Notifier<DeleteAccountState> {
  @override
  DeleteAccountState build() => const DeleteAccountState();

  /// Makes the request. Returns what happened once the session is over (the local
  /// clean-up is done too); throws an `AppFailure` when nothing was confirmed and the
  /// session goes on. The body is always `{"confirm": "DELETE"}` and the same call can
  /// be made again (`withReauth` does).
  Future<AccountDeletionOutcome> request() async {
    // Read before the session ends: the profile and the account's id are gone afterwards.
    final timezone = ref.read(meControllerProvider).value?.profile.timezone;
    final userId = await ref.read(pendingCheckInStoreProvider).currentUserId();
    final AccountDeletion deletion;
    try {
      deletion = await ref.read(privacyRepositoryProvider).deleteAccount();
    } on Object catch (error) {
      final failure = toAppFailure(error);
      if (failure is UnauthorizedFailure && state.outcomeUnknown) {
        await _endUnconfirmed(timezone: timezone);
        return AccountDeletionOutcome.unconfirmed;
      }
      if (_leavesOutcomeOpen(failure)) {
        state = const DeleteAccountState(outcomeUnknown: true);
      }
      throw failure;
    }
    // The server answered 202: the account is closed, whatever happens on this phone
    // from here on. Nothing below may turn into a failure ("not confirmed" would be a
    // lie), and no step may stop the others.
    await _endClosed(
      purgeAfter: deletion.purgeAfter,
      timezone: timezone,
      userId: userId,
    );
    return AccountDeletionOutcome.closed;
  }

  /// A failure that does not say whether the server acted: no answer came, or it was
  /// not a usable one. A refusal (403, 422, 429) is an answer: nothing was done.
  static bool _leavesOutcomeOpen(AppFailure failure) => switch (failure) {
    NetworkFailure() || ServerFailure() || UnknownFailure() => true,
    _ => false,
  };

  Future<void> _endClosed({
    required DateTime? purgeAfter,
    required String? timezone,
    required String userId,
  }) async {
    // The final screen first: the redirect that follows the sign-out must land on it.
    ref
        .read(accountClosedNoticeProvider.notifier)
        .close(AccountClosed(purgeAfter: purgeAfter, timezone: timezone));
    final ended = ref.read(sessionEndedNoticeProvider.notifier);
    ended.clear();
    await _signOut();
    // A request that was in flight may have been refused (401) after the session ended;
    // "please sign in again" would be the wrong thing to say now.
    ended.clear();
    try {
      await ref.read(localAccountDataProvider).wipe(userId: userId);
    } on Object {
      // Every step of the wipe is independent and swallows its own failure; this is
      // only a net. The account is closed either way.
    }
    if (ref.mounted) {
      state = const DeleteAccountState();
    }
  }

  Future<void> _endUnconfirmed({required String? timezone}) async {
    ref
        .read(accountClosedNoticeProvider.notifier)
        .close(AccountClosed(timezone: timezone, confirmed: false));
    // The session was refused: end it the normal way, and only it. The local pending
    // check-in, the preferences and the app lock stay as they are.
    await _signOut();
    if (ref.mounted) {
      state = const DeleteAccountState();
    }
  }

  /// The existing sign-out path: the in-memory token and the `session.*` keys, nothing
  /// else. The status changes even when the platform store fails, and that failure goes
  /// no further: the session is over.
  Future<void> _signOut() async {
    try {
      await ref.read(authControllerProvider.notifier).signOut();
    } on Object {
      // Signed out regardless (see AuthController.signOut).
    }
  }

  /// A fresh start when the screen opens.
  void reset() => state = const DeleteAccountState();
}

final deleteAccountControllerProvider =
    NotifierProvider<DeleteAccountController, DeleteAccountState>(
      DeleteAccountController.new,
    );
