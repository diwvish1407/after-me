import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

/// Whether the session was ended **for** the person (revoked from another device,
/// password changed or reset elsewhere, "log out everywhere", a refresh that could not
/// continue) rather than by them. Sign-in then explains it calmly ("Please sign in
/// again.", USER_FLOWS.md §14) instead of the app silently dropping to Welcome, which a
/// returning person could take for a lost account.
///
/// It lasts until the next successful sign-in.
///
/// A sign-out the person asked for is not "ended for them": requests that were in flight
/// when they signed out can be refused (401) because of it, and must not make the next
/// sign-in say "Please sign in again" as if the session had been taken away.
class SessionEndedNotice extends Notifier<bool> {
  bool _endedByPerson = false;

  @override
  bool build() {
    ref.listen<AuthStatus>(authControllerProvider, (previous, next) {
      if (next == AuthStatus.signedIn) {
        state = false;
        _endedByPerson = false;
      }
    });
    return false;
  }

  /// The session ended without the person asking for it. Ignored while the person is
  /// signing out themselves ([endedByPerson]).
  void raise() {
    if (!_endedByPerson) {
      state = true;
    }
  }

  /// The person is signing out: whatever the server refuses from here on is a result of
  /// that, not of the session being taken away.
  void endedByPerson() {
    _endedByPerson = true;
    state = false;
  }

  /// The sign-out did not happen (the server could not be reached for a sign-out
  /// everywhere): the session goes on, and a later refusal is a real one.
  void personStayedSignedIn() => _endedByPerson = false;

  /// The explanation is no longer true or needed (the account was closed on purpose:
  /// "Please sign in again" would be the wrong thing to say).
  void clear() => state = false;
}

final sessionEndedNoticeProvider = NotifierProvider<SessionEndedNotice, bool>(
  SessionEndedNotice.new,
);
