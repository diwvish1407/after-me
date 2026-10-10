import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Key-value storage for secrets (refresh token, session id, device id).
///
/// Only this interface is used by the rest of the app, so tests and previews can use
/// [InMemorySecureStore] and nothing sensitive ever goes to `shared_preferences`
/// (SECURITY.md §11 STORAGE).
abstract interface class SecureStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  /// Removes every value this app stored through the secure store.
  Future<void> deleteAll();
}

/// Android Keystore-backed implementation (flutter_secure_storage 11).
final class FlutterSecureStore implements SecureStore {
  FlutterSecureStore([FlutterSecureStorage? storage])
    : _storage =
          storage ?? const FlutterSecureStorage(aOptions: androidOptions);

  /// The plugin's recommended default ciphers for v11 (RSA-OAEP key wrapping +
  /// AES-GCM data encryption, no biometric binding). The app lock (Phase 2) is a
  /// separate, local control (ARCHITECTURE.md §5.5).
  ///
  /// * [AndroidOptions.storageNamespace] isolates our values, Keystore aliases and
  ///   wrapped keys from any other instance.
  /// * `migrateWithBackup` keeps data safe if a future cipher migration is
  ///   interrupted.
  /// * `resetOnError` stays true (plugin default): if the Keystore key is lost the
  ///   values are erased and the user signs in again, rather than the app failing.
  static const AndroidOptions androidOptions = AndroidOptions(
    storageNamespace: 'afterme_secure',
    migrateWithBackup: true,
  );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<void> deleteAll() => _storage.deleteAll();
}

/// In-memory implementation for tests and widget previews. Never persists anything.
class InMemorySecureStore implements SecureStore {
  InMemorySecureStore([Map<String, String>? initialValues])
    : _values = {...?initialValues};

  final Map<String, String> _values;

  /// A copy of the current contents (for assertions in tests).
  Map<String, String> get values => Map.unmodifiable(_values);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<void> deleteAll() async => _values.clear();
}

/// The app-wide secure store. Tests override it with [InMemorySecureStore].
final secureStoreProvider = Provider<SecureStore>(
  (ref) => FlutterSecureStore(),
);
