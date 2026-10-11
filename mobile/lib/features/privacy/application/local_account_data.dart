import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/security/app_lock/app_lock_controller.dart';
import '../../../core/storage/preferences_store.dart';
import '../../checkin/application/pending_checkin_store.dart';
import '../../notifications/application/push_coordinator.dart';
import '../../onboarding/application/onboarding_controller.dart';

/// Removes what this phone keeps **about the account** once the account is closed.
///
/// * the pending check-in record **of that account** (an I'M OK tap the server never
///   confirmed: there is no account to send it to any more, and it is a trace of the
///   person's daily pattern). One that belongs to another account on this phone stays;
/// * the preferences: onboarding progress and the account id it belongs to, the app lock
///   and its timeout, the notification pre-prompt result;
/// * the push registration and the FCM token on this phone (`forgetDevice`: the server's
///   copy was cleared by the deletion);
/// * and what the app holds in memory from them, so the next account on this phone starts
///   clean (no app lock carried over, no onboarding position).
///
/// The session itself is **not** handled here: `AuthController.signOut` deletes the
/// `session.*` keys, and only those (never `deleteAll`). Every step is independent, so
/// one that fails never stops the others.
class LocalAccountData {
  LocalAccountData(this._ref);

  final Ref _ref;

  /// [userId] is the account that was closed (read before its session ended). When it is
  /// not known the record is removed whoever it names: an account's trace outweighs
  /// another account's unsent tap on a phone that is, at this point, being cleaned up.
  Future<void> wipe({String? userId}) async {
    try {
      final store = _ref.read(pendingCheckInStoreProvider);
      if (userId == null || userId.isEmpty) {
        await store.clear();
      } else {
        await store.clearFor(userId);
      }
    } on Object {
      // Nothing more to do; the record belongs to an account that no longer exists.
    }
    try {
      // The push registration of this phone and its FCM token (the server's own copy was
      // cleared by the deletion itself).
      await _ref.read(pushCoordinatorProvider).forgetDevice();
    } on Object {
      // Independent of every other step.
    }
    try {
      await _ref.read(preferencesStoreProvider).clear();
    } on Object {
      // The in-memory state below is reset regardless.
    }
    // Both read their values from the (now empty) preferences when rebuilt.
    _ref
      ..invalidate(onboardingControllerProvider)
      ..invalidate(appLockControllerProvider);
  }
}

final localAccountDataProvider = Provider<LocalAccountData>(
  LocalAccountData.new,
);
