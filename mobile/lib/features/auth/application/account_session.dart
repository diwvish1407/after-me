import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../data/auth_repository.dart';

/// Ending sessions.
class AccountSession {
  AccountSession(this._ref);

  final Ref _ref;

  /// Signs out of this device. The server is told on a best-effort basis (short
  /// timeout): the person must always be able to leave, even offline. Local state is
  /// cleared either way.
  Future<void> signOut() async {
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
    try {
      await _ref.read(authRepositoryProvider).logoutAll();
    } on Object catch (error) {
      throw toAppFailure(error);
    }
    await _ref.read(authControllerProvider.notifier).signOut();
  }
}

final accountSessionProvider = Provider<AccountSession>(AccountSession.new);
