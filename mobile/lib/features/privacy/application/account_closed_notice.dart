import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';

/// What the "Your account has been closed" screen says: kept in memory only (nothing of
/// the account is stored once it is closed).
@immutable
class AccountClosed {
  const AccountClosed({this.purgeAfter, this.timezone, this.confirmed = true});

  /// When the remaining data is removed (`purge_after`); null when the server's answer
  /// was not seen.
  final DateTime? purgeAfter;

  /// The profile's timezone, to show [purgeAfter] on the person's own calendar.
  final String? timezone;

  /// The server said 202. False when the answer was lost and the request that followed
  /// was refused: the account may or may not be closed, and the screen says exactly
  /// that. Only a 202 is "closed".
  final bool confirmed;
}

/// Set once the deletion was confirmed (or could not be, see [AccountClosed.confirmed]),
/// until the person has read the final screen. While it is set, the router keeps the signed-out app on that
/// screen, whatever else happens (a late "please sign in again" included).
class AccountClosedNotice extends Notifier<AccountClosed?> {
  @override
  AccountClosed? build() {
    ref.listen<AuthStatus>(authControllerProvider, (previous, next) {
      // A new sign-in is a new account: nothing is left to explain.
      if (next == AuthStatus.signedIn) {
        state = null;
      }
    });
    return null;
  }

  void close(AccountClosed closed) => state = closed;

  void dismiss() => state = null;
}

final accountClosedNoticeProvider =
    NotifierProvider<AccountClosedNotice, AccountClosed?>(
      AccountClosedNotice.new,
    );
