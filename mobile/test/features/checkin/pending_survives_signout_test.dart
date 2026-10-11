import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/checkin/application/checkin_controller.dart';
import 'package:afterme/features/checkin/application/pending_checkin_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fakes.dart';
import '../../helpers/test_app.dart';

/// A tap the server has not confirmed must outlive the end of the session that made it
/// (`session_revoked`, a rejected refresh, "log out everywhere"), because the app tells
/// the person it is kept and will be sent once they sign in. The earlier test of this
/// used a fixed auth controller and never reached the real session store.
void main() {
  test(
    'a pending check-in survives a real sign-out, bound to its account',
    () async {
      final fakes = TestFakes();
      final container = ProviderContainer.test(
        overrides: testOverrides(fakes: fakes),
      );
      final auth = container.read(authControllerProvider.notifier);
      await auth.restored;
      await auth.signIn(tokenResponse());
      expect(
        await container.read(sessionStoreProvider).hasPersistedSession(),
        isTrue,
      );

      final store = container.read(pendingCheckInStoreProvider);
      final record = PendingCheckIn(
        userId: 'user-1',
        idempotencyKey: 'key-for-this-tap',
        reportedAt: DateTime.utc(2026, 10, 10, 12),
      );
      await store.write(record);

      await auth.signOut();

      expect(container.read(authControllerProvider), AuthStatus.signedOut);
      expect(
        await container.read(sessionStoreProvider).hasPersistedSession(),
        isFalse,
      );
      expect(fakes.secure.values.keys, [PendingCheckInStore.storageKey]);
      expect(await store.read('user-1'), record);
      // Another account that signs in on this phone never sends it.
      expect(await store.read('user-2'), isNull);
    },
  );

  test(
    'the owner of the pending check-in is the account of the session, so a '
    'preference that was not written can never hand it to the next account',
    () async {
      // The reviewer's scenario: A taps offline and signs out; B signs in on the same
      // phone while the onboarding preference still holds A's id (its write failed).
      final fakes = TestFakes();
      fakes.prefs = freshPreferences({'afterme.onboardingUserId': 'user-1'});
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      final container = ProviderContainer.test(
        retry: (retryCount, error) => null,
        overrides: testOverrides(fakes: fakes),
      );
      container.listen(checkInControllerProvider, (_, _) {});
      final auth = container.read(authControllerProvider.notifier);
      await auth.restored;
      await auth.signIn(tokenResponse());
      await pumpEventQueue();
      await container.read(checkInControllerProvider.notifier).checkIn();
      expect(
        container.read(checkInControllerProvider).phase,
        CheckInPhase.pending,
      );
      final stored = PendingCheckIn.tryDecode(
        await fakes.secure.read(PendingCheckInStore.storageKey),
      );
      expect(stored!.userId, 'user-1', reason: 'the session\'s account');
      expect(fakes.server.checkInKeys, ['key-1']);

      await auth.signOut();
      await pumpEventQueue();
      expect(
        await fakes.secure.read(SessionKeys.userId),
        isNull,
        reason: 'the owner goes with the session',
      );

      // B signs in. The preference still names A.
      await auth.signIn(tokenResponse(userId: 'user-2', refresh: 'refresh-b'));
      await pumpEventQueue();
      expect(
        await fakes.prefs.getString(PreferenceKey.onboardingUserId),
        'user-1',
      );
      expect(await fakes.secure.read(SessionKeys.userId), 'user-2');
      expect(
        container.read(checkInControllerProvider).phase,
        CheckInPhase.idle,
        reason: 'A\'s tap is not B\'s',
      );
      expect(fakes.server.checkInKeys, [
        'key-1',
      ], reason: 'nothing was sent with B\'s token for A\'s tap');
      // ... and it is still A's, waiting for A.
      expect(
        await fakes.secure.read(PendingCheckInStore.storageKey),
        stored.encode(),
      );
    },
  );

  test('a record that names nobody is never kept, read or sent, and the tap '
      'still works for as long as the process lives', () async {
    final fakes = TestFakes();
    // No session id in storage (an unreadable Keystore, a session from before the id
    // was kept): nobody to bind the tap to.
    await fakes.secure.delete(SessionKeys.userId);
    await fakes.secure.write(
      PendingCheckInStore.storageKey,
      '{"v":1,"user":"","key":"ownerless","reported_at":"2026-10-08T11:00:00Z"}',
    );
    final container = ProviderContainer.test(
      retry: (retryCount, error) => null,
      overrides: testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
    );
    container.listen(checkInControllerProvider, (_, _) {});
    await pumpEventQueue();
    expect(
      container.read(checkInControllerProvider).phase,
      CheckInPhase.idle,
      reason: 'a record without an owner is not restored',
    );
    expect(fakes.server.calls, isEmpty);

    await container.read(checkInControllerProvider.notifier).checkIn();
    expect(
      container.read(checkInControllerProvider).phase,
      CheckInPhase.success,
      reason: 'the tap itself is not refused',
    );
    expect(fakes.server.checkInKeys, ['key-1']);
  });

  group('PendingCheckInStore', () {
    PendingCheckIn record(String user) => PendingCheckIn(
      userId: user,
      idempotencyKey: 'key-$user',
      reportedAt: DateTime.utc(2026, 10, 8, 11),
    );

    test('refuses to keep or return a record without an owner', () async {
      final secure = InMemorySecureStore();
      final store = PendingCheckInStore(secure: secure);
      await store.write(record(''));
      expect(secure.values, isEmpty);

      await secure.write(PendingCheckInStore.storageKey, record('').encode());
      expect(await store.read(''), isNull);
      expect(await store.read('user-1'), isNull);
      expect(PendingCheckIn.tryDecode(record('').encode()), isNull);
    });

    test(
      'the owner is the session\'s id; unreadable storage means nobody',
      () async {
        final secure = InMemorySecureStore({SessionKeys.userId: 'user-9'});
        expect(
          await PendingCheckInStore(secure: secure).currentUserId(),
          'user-9',
        );
        expect(
          await PendingCheckInStore(secure: InMemorySecureStore())
              .currentUserId(),
          '',
        );
        expect(
          await PendingCheckInStore(secure: ThrowingSecureStore())
              .currentUserId(),
          '',
        );
      },
    );

    test('clearFor forgets only the record of that account', () async {
      final secure = InMemorySecureStore();
      final store = PendingCheckInStore(secure: secure);
      await store.write(record('user-1'));

      await store.clearFor('user-2');
      expect(await store.read('user-1'), record('user-1'));

      await store.clearFor('user-1');
      expect(secure.values, isEmpty);

      // A damaged record is nobody's: it goes.
      await secure.write(PendingCheckInStore.storageKey, 'not json');
      await store.clearFor('user-2');
      expect(secure.values, isEmpty);
    });
  });
}
