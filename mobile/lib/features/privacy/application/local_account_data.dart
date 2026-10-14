import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/preferences_store.dart';
import '../../checkin/application/pending_checkin_store.dart';
import '../../notifications/application/push_coordinator.dart';
import '../../onboarding/application/onboarding_controller.dart';
import '../../onboarding/application/setup_controller.dart';

/// Removes what this phone keeps **about the account** once the account is closed.
///
/// * the pending check-in record **of that account** (an I'M OK tap the server never
///   confirmed: there is no account to send it to any more, and it is a trace of the
///   person's daily pattern). One that belongs to another account on this phone stays;
/// * the preferences that are the account's: onboarding progress and the account id it
///   belongs to. The phone's own settings (the app lock and its timeout, the notification
///   pre-prompt result) are **not** account data and stay: whoever signs in next on this
///   phone, the same person included, keeps the lock that was chosen for the device, and
///   no lock screen is raised over the closed-account page;
/// * the push registration and the FCM token on this phone (`forgetDevice`: the server's
///   copy was cleared by the deletion);
/// * and what the app holds in memory from the onboarding progress, so the next account
///   on this phone starts at the first step.
///
/// The session itself is **not** handled here: `AuthController.signOut` deletes the
/// `session.*` keys, and only those (never `deleteAll`). Every step is independent, so
/// one that fails never stops the others.
class LocalAccountData {
  LocalAccountData(this._ref);

  final Ref _ref;

  /// [userId] is the account that was closed (read before its session ended). When it is
  /// not known, every pending record on the phone is removed (the main slot and each one
  /// moved aside by another account's tap): the closed account's own cannot be told
  /// apart, and an account's trace outweighs another account's unsent tap (worth nothing
  /// after 12 hours anyway) on a phone that is, at this point, being cleaned up.
  Future<void> wipe({String? userId}) async {
    try {
      final store = _ref.read(pendingCheckInStoreProvider);
      if (userId == null || userId.isEmpty) {
        // The closed account's parked copy cannot be named: every record goes.
        await store.clearAll();
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
      await _ref.read(preferencesStoreProvider).clearAccountBound();
    } on Object {
      // The in-memory state below is reset regardless.
    }
    // Reads its values from the (now empty) preferences when rebuilt. The app lock is
    // the phone's and is not rebuilt.
    _ref
      ..invalidate(onboardingControllerProvider)
      // What onboarding saved (instruction titles) belongs to the closed account.
      ..invalidate(setupControllerProvider);
  }
}

final localAccountDataProvider = Provider<LocalAccountData>(
  LocalAccountData.new,
);
