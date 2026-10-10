import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

/// Whether the session was ended **for** the person (revoked from another device,
/// password changed or reset elsewhere, "log out everywhere", a refresh that could not
/// continue) rather than by them. Sign-in then explains it calmly ("Please sign in
/// again.", USER_FLOWS.md §14) instead of the app silently dropping to Welcome, which a
/// returning person could take for a lost account.
///
/// It lasts until the next successful sign-in.
class SessionEndedNotice extends Notifier<bool> {
  @override
  bool build() {
    ref.listen<AuthStatus>(authControllerProvider, (previous, next) {
      if (next == AuthStatus.signedIn) {
        state = false;
      }
    });
    return false;
  }

  /// The session ended without the person asking for it.
  void raise() => state = true;
}

final sessionEndedNoticeProvider = NotifierProvider<SessionEndedNotice, bool>(
  SessionEndedNotice.new,
);
