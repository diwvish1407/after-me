import 'dart:async';

import 'package:afterme/core/api/models/token_response.dart';
import 'package:afterme/core/storage/secure_store.dart';

/// A [SecureStore] whose operations always fail, like a broken Keystore.
class ThrowingSecureStore implements SecureStore {
  @override
  Future<void> delete(String key) async => throw StateError('keystore');

  @override
  Future<void> deleteAll() async => throw StateError('keystore');

  @override
  Future<String?> read(String key) async => throw StateError('keystore');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('keystore');
}

/// An in-memory store whose reads wait for [release], to test races.
class GatedSecureStore extends InMemorySecureStore {
  GatedSecureStore([super.initialValues]);

  final Completer<void> _gate = Completer<void>();

  void release() => _gate.complete();

  /// Captures the value when called (like a slow platform read), returns it later.
  @override
  Future<String?> read(String key) async {
    final value = await super.read(key);
    await _gate.future;
    return value;
  }
}

/// An in-memory store that records the order of writes and deletes.
class RecordingSecureStore extends InMemorySecureStore {
  RecordingSecureStore([super.initialValues]);

  final List<String> log = [];

  /// Runs after each write (to simulate something happening meanwhile).
  Future<void> Function()? afterWrite;

  @override
  Future<void> write(String key, String value) async {
    log.add('write $key=$value');
    await super.write(key, value);
    await afterWrite?.call();
  }

  @override
  Future<void> deleteAll() {
    log.add('deleteAll');
    return super.deleteAll();
  }
}

TokenResponse tokenResponse({
  String access = 'access-1',
  String refresh = 'refresh-1',
  String userId = 'user-1',
}) => TokenResponse(
  accessToken: access,
  accessTokenExpiresAt: DateTime.utc(2026, 10, 8, 10, 15),
  refreshToken: refresh,
  sessionId: 'session-1',
  deviceId: 'device-1',
  user: TokenUser(id: userId, email: 'd@example.com', tier: 'free'),
);

RefreshResponse refreshResponse({
  String access = 'access-2',
  String refresh = 'refresh-2',
}) => RefreshResponse(
  accessToken: access,
  accessTokenExpiresAt: DateTime.utc(2026, 10, 8, 10, 30),
  refreshToken: refresh,
);
