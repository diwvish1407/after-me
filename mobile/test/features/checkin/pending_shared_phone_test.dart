import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/checkin/application/checkin_controller.dart';
import 'package:afterme/features/checkin/application/pending_checkin_store.dart';
import 'package:afterme/features/privacy/application/local_account_data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fakes.dart';
import '../../helpers/test_app.dart';

/// Two accounts on one phone (deferred defect from the Phase 7 review): a tap that the
/// server has not confirmed belongs to the account that made it, and another account's
/// first tap on the same phone must never replace it. The server binds every check-in to
/// the session's account, so the record is only ever sent for its own owner.
PendingCheckIn _record(String user, {String key = 'k', int hour = 11}) =>
    PendingCheckIn(
      userId: user,
      idempotencyKey: '$key-$user',
      reportedAt: DateTime.utc(2026, 10, 8, hour),
    );

void main() {
  group('PendingCheckInStore with two accounts', () {
    test('a second account\'s record does not replace the first\'s', () async {
      final store = PendingCheckInStore(secure: InMemorySecureStore());
      await store.write(_record('user-1'));
      await store.write(_record('user-2', hour: 12));

      expect(await store.read('user-1'), _record('user-1'));
      expect(await store.read('user-2'), _record('user-2', hour: 12));
    });

    test('forgetting one account\'s record leaves the other\'s', () async {
      final secure = InMemorySecureStore();
      final store = PendingCheckInStore(secure: secure);
      await store.write(_record('user-1'));
      await store.write(_record('user-2', hour: 12));

      await store.clearFor('user-2');
      expect(await store.read('user-2'), isNull);
      expect(await store.read('user-1'), _record('user-1'));

      await store.clearFor('user-1');
      expect(await store.read('user-1'), isNull);
      expect(secure.values, isEmpty);
    });

    test('a record written again for the same account replaces only that '
        'account\'s', () async {
      final store = PendingCheckInStore(secure: InMemorySecureStore());
      await store.write(_record('user-1'));
      await store.write(_record('user-2', hour: 12));
      await store.write(_record('user-1', key: 'again', hour: 13));

      expect(
        await store.read('user-1'),
        _record('user-1', key: 'again', hour: 13),
      );
      expect(await store.read('user-2'), _record('user-2', hour: 12));
    });

    test('a record kept by an earlier version is still read, and moved aside '
        'rather than overwritten', () async {
      final secure = InMemorySecureStore({
        PendingCheckInStore.storageKey: _record('user-1').encode(),
      });
      final store = PendingCheckInStore(secure: secure);
      await store.write(_record('user-2', hour: 12));

      expect(await store.read('user-1'), _record('user-1'));
      expect(await store.read('user-2'), _record('user-2', hour: 12));
    });
  });

  group('M-3: what clear() and clearAll() remove', () {
    test('clear() removes the main slot only; a parked record stays', () async {
      final secure = InMemorySecureStore();
      final store = PendingCheckInStore(secure: secure);
      await store.write(_record('user-1'));
      await store.write(_record('user-2', hour: 12)); // user-1 is parked

      await store.clear();

      expect(await store.read('user-2'), isNull);
      expect(await store.read('user-1'), _record('user-1'));
      expect(secure.values.keys, ['checkin.pending.user-1']);
    });

    test('clearAll() removes the main slot and every parked record, and '
        'nothing else', () async {
      final secure = InMemorySecureStore({
        'session.refresh_token': 'refresh',
        'session.user_id': 'user-3',
        'unrelated.checkin.pending.x': 'kept',
      });
      final store = PendingCheckInStore(secure: secure);
      await store.write(_record('user-1'));
      await store.write(_record('user-2', hour: 12));
      await store.write(_record('user-3', hour: 13));
      expect(
        secure.values.keys.where((k) => k.startsWith('checkin.pending')),
        hasLength(3),
      );

      await store.clearAll();

      expect(await store.read('user-1'), isNull);
      expect(await store.read('user-2'), isNull);
      expect(await store.read('user-3'), isNull);
      expect(secure.values, {
        'session.refresh_token': 'refresh',
        'session.user_id': 'user-3',
        'unrelated.checkin.pending.x': 'kept',
      });
    });

    test('clearAll() on a store that cannot be read never throws', () async {
      final store = PendingCheckInStore(secure: ThrowingSecureStore());
      await store.clearAll();
      await store.clear();
    });

    test('clearAll() keeps going when one delete fails', () async {
      final secure = _FlakyDeleteStore({
        'checkin.pending.a': 'x',
        'checkin.pending.b': 'x',
        'checkin.pending.c': 'x',
      }, failOn: 'checkin.pending.a');
      await PendingCheckInStore(secure: secure).clearAll();
      expect(secure.values.keys, ['checkin.pending.a']);
    });
  });

  group('M-3: closing an account', () {
    Future<(ProviderContainer, TestFakes)> world() async {
      final fakes = TestFakes();
      final container = ProviderContainer.test(
        overrides: testOverrides(fakes: fakes),
      );
      final store = container.read(pendingCheckInStoreProvider);
      await store.write(_record('user-1'));
      await store.write(_record('user-2', hour: 12)); // user-1 is parked
      await store.write(_record('user-3', hour: 13)); // user-2 is parked
      return (container, fakes);
    }

    Iterable<String> pendingKeys(TestFakes fakes) =>
        fakes.secure.values.keys.where((k) => k.startsWith('checkin.pending'));

    test('a known account loses its own record, main or parked, and no '
        'other', () async {
      final (container, fakes) = await world();
      await container.read(localAccountDataProvider).wipe(userId: 'user-1');
      expect(
        pendingKeys(fakes),
        unorderedEquals(['checkin.pending', 'checkin.pending.user-2']),
      );
    });

    test('an account whose id cannot be read takes every pending record '
        'with it', () async {
      final (container, fakes) = await world();
      await container.read(localAccountDataProvider).wipe();
      expect(pendingKeys(fakes), isEmpty);
      expect(fakes.secure.values.keys, contains('session.user_id'));
    });
  });

  group('on a shared phone', () {
    test('A\'s unsent tap survives B\'s first tap and is sent when A comes '
        'back', () async {
      final fakes = TestFakes();
      // A's tap and B's tap both fail on the network.
      fakes.server.failures['checkIn'] = [
        const NetworkFailure(),
        const NetworkFailure(),
      ];
      final container = ProviderContainer.test(
        retry: (retryCount, error) => null,
        overrides: testOverrides(fakes: fakes),
      );
      container.listen(checkInControllerProvider, (_, _) {});
      final auth = container.read(authControllerProvider.notifier);
      await auth.restored;

      // A taps and the tap is not confirmed.
      await auth.signIn(tokenResponse());
      await pumpEventQueue();
      await container.read(checkInControllerProvider.notifier).checkIn();
      expect(
        container.read(checkInControllerProvider).phase,
        CheckInPhase.pending,
      );
      expect(fakes.server.checkInKeys, ['key-1']);
      await auth.signOut();
      await pumpEventQueue();

      // B signs in on the same phone and taps; that is not confirmed either.
      await auth.signIn(tokenResponse(userId: 'user-2', refresh: 'refresh-b'));
      await pumpEventQueue();
      expect(
        container.read(checkInControllerProvider).phase,
        CheckInPhase.idle,
        reason: 'A\'s tap is not B\'s',
      );
      await container.read(checkInControllerProvider.notifier).checkIn();
      expect(
        container.read(checkInControllerProvider).phase,
        CheckInPhase.pending,
      );
      expect(fakes.server.checkInKeys, ['key-1', 'key-2']);
      await auth.signOut();
      await pumpEventQueue();

      // A comes back: the tap A made is restored and sent with its own key.
      await auth.signIn(tokenResponse(refresh: 'refresh-a2'));
      await pumpEventQueue();
      expect(fakes.server.checkInKeys, [
        'key-1',
        'key-2',
        'key-1',
      ], reason: 'A\'s tap, never B\'s, goes out again with the key it had');
      expect(
        container.read(checkInControllerProvider).phase,
        CheckInPhase.success,
      );
    });
  });
}

/// Fails the deletion of one key and works for the rest.
class _FlakyDeleteStore extends InMemorySecureStore {
  _FlakyDeleteStore(super.initialValues, {required this.failOn});

  final String failOn;

  @override
  Future<void> delete(String key) async {
    if (key == failOn) {
      throw StateError('keystore');
    }
    await super.delete(key);
  }
}
