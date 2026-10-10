import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/token_response.dart';
import 'session_store.dart';

/// Whether the app has a session. Drives the router (ARCHITECTURE.md §5).
enum AuthStatus {
  /// Start-up: the persisted session has not been read yet.
  unknown,

  /// No session. Only public routes are reachable.
  signedOut,

  /// A refresh token is stored. The access token may still need refreshing.
  signedIn,
}

/// Owns [AuthStatus]. It is restored from secure storage on first use and changes
/// only through [signIn] and [signOut].
class AuthController extends Notifier<AuthStatus> {
  Future<void>? _restoring;

  @override
  AuthStatus build() {
    final store = ref.watch(sessionStoreProvider);
    _restoring = _restore(store);
    return AuthStatus.unknown;
  }

  /// Completes when the start-up restore has finished.
  Future<void> get restored => _restoring ?? Future<void>.value();

  Future<void> _restore(SessionStore store) async {
    AuthStatus restored;
    try {
      restored = await store.hasPersistedSession()
          ? AuthStatus.signedIn
          : AuthStatus.signedOut;
    } on Object {
      // Unreadable secure storage: fail safe to signed out; the user signs in again.
      restored = AuthStatus.signedOut;
    }
    // A sign-in or sign-out that happened meanwhile wins over the restored value.
    if (ref.mounted && state == AuthStatus.unknown) {
      state = restored;
    }
  }

  /// Starts a session from a register/verify or login response (wired in Phase 2).
  Future<void> signIn(TokenResponse tokens) async {
    final saved = await ref.read(sessionStoreProvider).saveSession(tokens);
    // A sign-out that raced the save wins: stay signed out.
    if (saved && ref.mounted) {
      state = AuthStatus.signedIn;
    }
  }

  /// Ends the session locally: clears the in-memory access token and everything in
  /// secure storage, then moves to [AuthStatus.signedOut]. The status changes even if
  /// the platform store fails.
  Future<void> signOut() async {
    try {
      await ref.read(sessionStoreProvider).clear();
    } finally {
      if (ref.mounted) {
        state = AuthStatus.signedOut;
      }
    }
  }
}

final authControllerProvider = NotifierProvider<AuthController, AuthStatus>(
  AuthController.new,
);
