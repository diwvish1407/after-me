import 'package:afterme/core/storage/preferences_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InMemorySecureStore', () {
    test('reads, writes, deletes and clears', () async {
      final store = InMemorySecureStore({'a': '1'});
      expect(await store.read('a'), '1');
      expect(await store.read('missing'), isNull);

      await store.write('b', '2');
      expect(store.values, {'a': '1', 'b': '2'});

      await store.delete('a');
      expect(await store.read('a'), isNull);

      await store.deleteAll();
      expect(store.values, isEmpty);
    });

    test('exposes an unmodifiable snapshot', () {
      final store = InMemorySecureStore({'a': '1'});
      expect(() => store.values['b'] = '2', throwsUnsupportedError);
    });
  });

  group('FlutterSecureStore', () {
    test('delegates to flutter_secure_storage', () async {
      FlutterSecureStorage.setMockInitialValues({'k': 'v'});
      final store = FlutterSecureStore();
      expect(await store.read('k'), 'v');
      await store.write('x', 'y');
      expect(await store.read('x'), 'y');
      await store.delete('x');
      expect(await store.read('x'), isNull);
      await store.deleteAll();
      expect(await store.read('k'), isNull);
    });

    test('uses the namespaced default Android ciphers', () {
      final options = FlutterSecureStore.androidOptions.toMap();
      expect(options['storageNamespace'], 'afterme_secure');
      expect(
        options['keyCipherAlgorithm'],
        'RSA_ECB_OAEPwithSHA_256andMGF1Padding',
      );
      expect(options['storageCipherAlgorithm'], 'AES_GCM_NoPadding');
      expect(options['migrateWithBackup'], 'true');
    });
  });

  group('PreferencesStore', () {
    setUp(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    test('stores typed values under namespaced keys', () async {
      final prefs = SharedPreferencesAsync();
      final store = PreferencesStore(prefs);

      await store.setString(PreferenceKey.onboardingStep, 'schedule');
      await store.setBool(PreferenceKey.appLockEnabled, value: true);
      await store.setInt(PreferenceKey.appLockTimeoutMinutes, 5);

      expect(await store.getString(PreferenceKey.onboardingStep), 'schedule');
      expect(await store.getBool(PreferenceKey.appLockEnabled), isTrue);
      expect(await store.getInt(PreferenceKey.appLockTimeoutMinutes), 5);
      expect(await prefs.getString('afterme.onboardingStep'), 'schedule');

      await store.remove(PreferenceKey.onboardingStep);
      expect(await store.getString(PreferenceKey.onboardingStep), isNull);
    });

    test('clear removes only AfterMe keys', () async {
      final prefs = SharedPreferencesAsync();
      await prefs.setString('other.key', 'kept');
      final store = PreferencesStore(prefs);
      await store.setBool(PreferenceKey.appLockEnabled, value: false);

      await store.clear();

      expect(await store.getBool(PreferenceKey.appLockEnabled), isNull);
      expect(await prefs.getString('other.key'), 'kept');
    });
  });
}
