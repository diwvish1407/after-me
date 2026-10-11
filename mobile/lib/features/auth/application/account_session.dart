import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/session_ended_notice.dart';
import '../data/auth_repository.dart';

/// Ending sessions.
class AccountSession {
  AccountSession(this._ref);

  final Ref _ref;

  /// Signs out of this device. The server is told on a best-effort basis (short
  /// timeout): the person must always be able to leave, even offline. Local state is
  /// cleared either way.
  Future<void> signOut() async {
    // Requests that are in flight may be refused because of this: that is not "your
    // session ended" (see SessionEndedNotice).
    _ref.read(sessionEndedNoticeProvider.notifier).endedByPerson();
    try {
      await _ref
          .read(authRepositoryProvider)
          .logout()
          .timeout(const Duration(seconds: 5));
    } on Object {
      // Offline or already revoked: still sign out locally.
    }
    await _ref.read(authControllerProvider.notifier).signOut();
  }

  /// Signs out of every device. Unlike [signOut] this must reach the server: if it
  /// did not, the other devices would stay signed in while the person thinks they
  /// are not. Throws an `AppFailure` and keeps the session in that case.
  Future<void> signOutEverywhere() async {
    final notice = _ref.read(sessionEndedNoticeProvider.notifier)
      ..endedByPerson();
    try {
      await _ref.read(authRepositoryProvider).logoutAll();
    } on Object catch (error) {
      notice.personStayedSignedIn();
      throw toAppFailure(error);
    }
    await _ref.read(authControllerProvider.notifier).signOut();
  }
}

final accountSessionProvider = Provider<AccountSession>(AccountSession.new);
