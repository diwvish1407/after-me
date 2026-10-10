import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/token_response.dart';
import '../storage/secure_store.dart';

/// Secure-storage keys for the session (ARCHITECTURE.md §5.4).
abstract final class SessionKeys {
  static const refreshToken = 'session.refresh_token';
  static const sessionId = 'session.session_id';
  static const deviceId = 'session.device_id';
}

/// Holds the current session.
///
/// * The **access token** lives in memory only and is lost when the process ends
///   (ARCHITECTURE.md §5.3). After a cold start the API client obtains a new one
///   with the refresh token.
/// * The **refresh token, session id and device id** live in [SecureStore].
///
/// Every [clear] bumps [generation]. Work that started before a sign-out (for
/// example a token refresh that was already in flight) compares generations and
/// can never resurrect a session that the user or the server ended.
class SessionStore {
  SessionStore(this._secure);

  final SecureStore _secure;

  String? _accessToken;
  DateTime? _accessTokenExpiresAt;
  int _generation = 0;

  /// The in-memory access token, or null when none has been obtained yet.
  String? get accessToken => _accessToken;

  DateTime? get accessTokenExpiresAt => _accessTokenExpiresAt;

  /// Incremented whenever the session is cleared.
  int get generation => _generation;

  Future<String?> readRefreshToken() => _secure.read(SessionKeys.refreshToken);

  Future<String?> readSessionId() => _secure.read(SessionKeys.sessionId);

  Future<String?> readDeviceId() => _secure.read(SessionKeys.deviceId);

  /// Whether a persisted session exists (used to restore the auth status).
  Future<bool> hasPersistedSession() async {
    final refreshToken = await readRefreshToken();
    return refreshToken != null && refreshToken.isNotEmpty;
  }

  /// Persists a new session from a register/verify or login response. The secure
  /// values are written before the access token becomes usable.
  ///
  /// Returns false (and stores nothing) when the session was cleared while the
  /// values were being written, so callers must not report a signed-in state.
  Future<bool> saveSession(TokenResponse tokens) async {
    final generation = _generation;
    await _secure.write(SessionKeys.refreshToken, tokens.refreshToken);
    await _secure.write(SessionKeys.sessionId, tokens.sessionId);
    await _secure.write(SessionKeys.deviceId, tokens.deviceId);
    if (generation != _generation) {
      // Cleared while we were writing: do not keep a half-written session.
      await _deleteSessionKeys();
      return false;
    }
    _accessToken = tokens.accessToken;
    _accessTokenExpiresAt = tokens.accessTokenExpiresAt;
    return true;
  }

  /// Stores the result of a token refresh.
  ///
  /// The rotated refresh token is persisted **before** the new access token is made
  /// available, so a crash between the two can never leave the app holding only the
  /// already-consumed refresh token. Returns false (and stores nothing) when the
  /// session was cleared after [expectedGeneration] was read.
  Future<bool> saveRefreshedTokens(
    RefreshResponse tokens, {
    required int expectedGeneration,
  }) async {
    if (expectedGeneration != _generation) {
      return false;
    }
    await _secure.write(SessionKeys.refreshToken, tokens.refreshToken);
    if (expectedGeneration != _generation) {
      // A sign-out raced with the write; undo it so the session stays ended.
      await _secure.delete(SessionKeys.refreshToken);
      return false;
    }
    _accessToken = tokens.accessToken;
    _accessTokenExpiresAt = tokens.accessTokenExpiresAt;
    return true;
  }

  /// Ends the session: forgets the access token and removes the session keys from the
  /// secure store. Memory is cleared first, so even if the platform store fails the
  /// token is no longer usable.
  ///
  /// Only the `session.*` keys go. The pending check-in (a tap the server has not
  /// confirmed yet, tied to its account) lives in the same store and must survive a
  /// session that ended under it (`session_revoked`, a rejected refresh, a password
  /// change elsewhere): it is sent once the person signs in again.
  Future<void> clear() async {
    _generation++;
    _accessToken = null;
    _accessTokenExpiresAt = null;
    await _deleteSessionKeys();
  }

  Future<void> _deleteSessionKeys() async {
    for (final key in const [
      SessionKeys.refreshToken,
      SessionKeys.sessionId,
      SessionKeys.deviceId,
    ]) {
      await _secure.delete(key);
    }
  }
}

final sessionStoreProvider = Provider<SessionStore>(
  (ref) => SessionStore(ref.watch(secureStoreProvider)),
);
