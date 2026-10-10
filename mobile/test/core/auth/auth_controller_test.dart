import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fakes.dart';

ProviderContainer _container(SecureStore store) => ProviderContainer.test(
  overrides: [secureStoreProvider.overrideWithValue(store)],
);

void main() {
  group('AuthController', () {
    test('starts unknown, then signedOut without a stored session', () async {
      final container = _container(InMemorySecureStore());
      expect(container.read(authControllerProvider), AuthStatus.unknown);
      await container.read(authControllerProvider.notifier).restored;
      expect(container.read(authControllerProvider), AuthStatus.signedOut);
    });

    test('restores signedIn when a refresh token is stored', () async {
      final container = _container(
        InMemorySecureStore({SessionKeys.refreshToken: 'refresh-1'}),
      );
      container.read(authControllerProvider);
      await container.read(authControllerProvider.notifier).restored;
      expect(container.read(authControllerProvider), AuthStatus.signedIn);
    });

    test('an unreadable secure store fails safe to signedOut', () async {
      final container = _container(ThrowingSecureStore());
      container.read(authControllerProvider);
      await container.read(authControllerProvider.notifier).restored;
      expect(container.read(authControllerProvider), AuthStatus.signedOut);
    });

    test(
      'a sign-out during restore is not overwritten by the restored value',
      () async {
        final store = GatedSecureStore({SessionKeys.refreshToken: 'refresh-1'});
        final container = _container(store);
        final controller = container.read(authControllerProvider.notifier);

        // signOut's deleteAll does not wait for the gate.
        await controller.signOut();
        store.release();
        await controller.restored;

        expect(container.read(authControllerProvider), AuthStatus.signedOut);
      },
    );

    test('signIn persists the session and moves to signedIn', () async {
      final secure = InMemorySecureStore();
      final container = _container(secure);
      final controller = container.read(authControllerProvider.notifier);
      await controller.restored;

      await controller.signIn(tokenResponse());

      expect(container.read(authControllerProvider), AuthStatus.signedIn);
      expect(container.read(sessionStoreProvider).accessToken, 'access-1');
      expect(secure.values[SessionKeys.refreshToken], 'refresh-1');
    });

    test('a sign-out racing signIn leaves the app signed out', () async {
      final secure = RecordingSecureStore();
      final container = _container(secure);
      final controller = container.read(authControllerProvider.notifier);
      await controller.restored;
      var signedOut = false;
      secure.afterWrite = () async {
        if (!signedOut) {
          signedOut = true;
          await controller.signOut();
        }
      };

      await controller.signIn(tokenResponse());

      expect(container.read(authControllerProvider), AuthStatus.signedOut);
      expect(container.read(sessionStoreProvider).accessToken, isNull);
      expect(secure.values, isEmpty);
    });

    test('signOut clears everything and moves to signedOut', () async {
      final secure = InMemorySecureStore();
      final container = _container(secure);
      final controller = container.read(authControllerProvider.notifier);
      await controller.restored;
      await controller.signIn(tokenResponse());

      await controller.signOut();

      expect(container.read(authControllerProvider), AuthStatus.signedOut);
      expect(container.read(sessionStoreProvider).accessToken, isNull);
      expect(secure.values, isEmpty);
    });

    test('signOut still signs out when the platform store fails', () async {
      final container = _container(ThrowingSecureStore());
      final controller = container.read(authControllerProvider.notifier);
      await controller.restored;

      await expectLater(controller.signOut(), throwsStateError);
      expect(container.read(authControllerProvider), AuthStatus.signedOut);
    });
  });
}
