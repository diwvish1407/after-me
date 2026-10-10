import 'dart:async';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/checkin/application/checkin_controller.dart';
import 'package:afterme/features/checkin/application/pending_checkin_store.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/test_app.dart';

TestFakes _fakes({Map<String, Object>? prefs}) => TestFakes()
  ..prefs = freshPreferences({'afterme.onboardingUserId': 'user-1', ...?prefs});

ProviderContainer _container(TestFakes fakes) {
  final container = ProviderContainer.test(
    retry: (retryCount, error) => null,
    overrides: testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
  );
  // Keeps the controller alive and records every state it passes through.
  container.listen(checkInControllerProvider, (_, _) {});
  return container;
}

CheckInController _controller(ProviderContainer c) =>
    c.read(checkInControllerProvider.notifier);

CheckInState _state(ProviderContainer c) => c.read(checkInControllerProvider);

Future<String?> _stored(TestFakes fakes) =>
    fakes.secure.read(PendingCheckInStore.storageKey);

/// A tap of this account that the server never confirmed, made [age] before the test
/// clock's now (a negative [age] is a tap "in the future": the phone's clock moved back).
Future<void> _seed(
  TestFakes fakes, {
  required Duration age,
  String key = 'old-key',
  String userId = 'user-1',
}) => fakes.secure.write(
  PendingCheckInStore.storageKey,
  PendingCheckIn(
    userId: userId,
    idempotencyKey: key,
    reportedAt: fakes.clock.now().subtract(age),
  ).encode(),
);

/// Just over the limit, by a hair and by a lot.
const _tooOld = [
  Duration(hours: 12, milliseconds: 1),
  Duration(hours: 12, seconds: 1),
  Duration(hours: 30),
  Duration(days: 3),
];

void main() {
  group('a check-in that goes through', () {
    test(
      'idle -> sending -> success, and success only after the 200',
      () async {
        final fakes = _fakes();
        final gate = Completer<void>();
        fakes.server.checkInGate = gate.future;
        final container = _container(fakes);
        final phases = <CheckInPhase>[];
        container.listen(
          checkInControllerProvider,
          (_, next) => phases.add(next.phase),
        );

        expect(_state(container).phase, CheckInPhase.idle);
        final tap = _controller(container).checkIn();
        await pumpEventQueue();
        expect(_state(container).phase, CheckInPhase.sending);
        expect(
          _state(container).result,
          isNull,
          reason: 'nothing confirmed yet',
        );
        expect(fakes.server.recorded, 0);

        gate.complete();
        await tap;
        expect(_state(container).phase, CheckInPhase.success);
        final result = _state(container).result!;
        expect(result.checkin.kind, CheckInKind.ok);
        expect(result.nextDueAt, isNull, reason: 'the schedule is off');
        expect(fakes.server.recorded, 1);
        expect(phases, [CheckInPhase.sending, CheckInPhase.success]);
      },
    );

    test('the key and the time of the tap are stored before the request, and '
        'removed after the 200', () async {
      final fakes = _fakes();
      final gate = Completer<void>();
      fakes.server.checkInGate = gate.future;
      final container = _container(fakes);
      final tap = _controller(container).checkIn();
      await pumpEventQueue();

      final record = PendingCheckIn.tryDecode(await _stored(fakes))!;
      expect(record.idempotencyKey, 'key-1');
      expect(record.userId, 'user-1');
      expect(record.reportedAt, fakes.clock.now());
      expect(fakes.server.checkInKeys, ['key-1']);

      gate.complete();
      await tap;
      expect(await _stored(fakes), isNull);
    });

    test('goes back to I\'M OK after a few seconds', () async {
      final fakes = _fakes();
      final container = _container(fakes);
      await _controller(container).checkIn();
      expect(_state(container).phase, CheckInPhase.success);
      expect(fakes.timers.delays, [checkInSuccessDuration]);
      fakes.timers.fireNext();
      expect(_state(container).phase, CheckInPhase.idle);
    });

    test('the next tap after a success uses a new key', () async {
      final fakes = _fakes();
      final container = _container(fakes);
      await _controller(container).checkIn();
      await _controller(container).checkIn();
      expect(fakes.server.checkInKeys, ['key-1', 'key-2']);
      expect(fakes.server.recorded, 2);
    });

    test('a check-in while the schedule is on carries the server\'s next '
        'deadline, which the app only passes on', () async {
      final fakes = _fakes();
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      fakes.server.activateNow();
      final container = _container(fakes);
      await _controller(container).checkIn();
      final result = _state(container).result!;
      // 20:00 Asia/Kolkata is 14:30 UTC; the test clock is 12:00 UTC on Oct 8, and
      // the next deadline is at least 12 hours away: Oct 9, 14:30 UTC.
      expect(result.nextDueAt, DateTime.utc(2026, 10, 9, 14, 30));
    });
  });

  group('a check-in that is not confirmed', () {
    test('a network error keeps the tap, shows Not received yet and retries '
        'with the same key after a delay', () async {
      final fakes = _fakes();
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      final container = _container(fakes);
      await _controller(container).checkIn();

      expect(_state(container).phase, CheckInPhase.pending);
      expect(_state(container).failure, isA<NetworkFailure>());
      expect(_state(container).tappedAt, fakes.clock.now());
      expect(await _stored(fakes), isNotNull);
      expect(fakes.timers.delays, [const Duration(seconds: 5)]);

      fakes.timers.fireNext();
      await pumpEventQueue();
      expect(_state(container).phase, CheckInPhase.success);
      expect(fakes.server.checkInKeys, ['key-1', 'key-1']);
      expect(fakes.keys.issued, ['key-1']);
      expect(fakes.server.recorded, 1);
      expect(await _stored(fakes), isNull);
    });

    test('a 503 and other server errors are retried with backoff that grows '
        'and stops growing', () async {
      final fakes = _fakes();
      fakes.server.failures['checkIn'] = [
        for (var i = 0; i < 7; i++)
          ServerFailure(statusCode: i.isEven ? 503 : 500),
      ];
      final container = _container(fakes);
      await _controller(container).checkIn();
      for (var i = 0; i < 6; i++) {
        expect(_state(container).phase, CheckInPhase.pending);
        fakes.timers.fireNext();
        await pumpEventQueue();
      }
      expect(_state(container).phase, CheckInPhase.pending);
      expect(fakes.timers.delays, [
        ...checkInBackoff,
        checkInBackoff.last,
      ], reason: 'the last delay repeats while the app stays open');
      fakes.timers.fireNext();
      await pumpEventQueue();
      expect(_state(container).phase, CheckInPhase.success);
      expect(fakes.keys.issued, ['key-1']);
      expect({...fakes.server.checkInKeys}, {'key-1'});
    });

    test('an answer that was lost on the way back is replayed, not recorded '
        'twice', () async {
      final fakes = _fakes();
      fakes.server.failAfterRecording.add(const NetworkFailure());
      final container = _container(fakes);
      await _controller(container).checkIn();
      expect(_state(container).phase, CheckInPhase.pending);
      expect(fakes.server.recorded, 1, reason: 'the server did record it');

      fakes.timers.fireNext();
      await pumpEventQueue();
      expect(_state(container).phase, CheckInPhase.success);
      expect(fakes.server.recorded, 1);
      expect(fakes.server.replays, 1);
    });

    test(
      'an attempt at a tap that is not confirmed is marked as a retry',
      () async {
        final fakes = _fakes();
        fakes.server.failures['checkIn'] = [const NetworkFailure()];
        final container = _container(fakes);
        final seen = <(CheckInPhase, bool)>[];
        container.listen(
          checkInControllerProvider,
          (_, next) => seen.add((next.phase, next.retrying)),
        );
        await _controller(container).checkIn();
        fakes.timers.fireNext();
        await pumpEventQueue();
        expect(seen, [
          (CheckInPhase.sending, false),
          (CheckInPhase.pending, false),
          (CheckInPhase.sending, true),
          (CheckInPhase.success, false),
        ]);
      },
    );

    test('a second tap while one is unconfirmed reuses its key', () async {
      final fakes = _fakes();
      fakes.server.failures['checkIn'] = [
        const NetworkFailure(),
        const NetworkFailure(),
      ];
      final container = _container(fakes);
      await _controller(container).checkIn();
      await _controller(container).checkIn();
      expect(_state(container).phase, CheckInPhase.pending);
      expect(fakes.keys.issued, ['key-1'], reason: 'never a second key');
      await _controller(container).checkIn();
      expect(_state(container).phase, CheckInPhase.success);
      expect({...fakes.server.checkInKeys}, {'key-1'});
      expect(fakes.server.recorded, 1);
    });

    test('taps while the request is on the wire do not send another', () async {
      final fakes = _fakes();
      final gate = Completer<void>();
      fakes.server.checkInGate = gate.future;
      final container = _container(fakes);
      final first = _controller(container).checkIn();
      await pumpEventQueue();
      final second = _controller(container).checkIn();
      final third = _controller(container).retryNow();
      await pumpEventQueue();
      gate.complete();
      await Future.wait([first, second, third]);
      expect(fakes.server.checkInKeys, ['key-1']);
      expect(fakes.keys.issued, ['key-1']);
      expect(fakes.server.recorded, 1);
    });

    test('two taps in the same instant make one key', () async {
      final fakes = _fakes();
      final container = _container(fakes);
      await Future.wait([
        _controller(container).checkIn(),
        _controller(container).checkIn(),
      ]);
      expect(fakes.keys.issued, ['key-1']);
      expect(fakes.server.recorded, 1);
    });

    test(
      'coming back to the foreground retries now, with the same key',
      () async {
        final fakes = _fakes();
        fakes.server.failures['checkIn'] = [const NetworkFailure()];
        final container = _container(fakes);
        await _controller(container).checkIn();
        expect(fakes.timers.active, hasLength(1));

        await _controller(container).onResumed();
        expect(_state(container).phase, CheckInPhase.success);
        expect(
          fakes.timers.active.where((t) => t.delay.inSeconds == 5),
          isEmpty,
          reason: 'the backoff timer is cancelled by the retry',
        );
        expect(fakes.server.checkInKeys, ['key-1', 'key-1']);
      },
    );

    test('resuming with nothing unconfirmed does nothing', () async {
      final fakes = _fakes();
      final container = _container(fakes);
      await _controller(container).onResumed();
      await _controller(container).retryNow();
      expect(fakes.server.calls, isEmpty);
      expect(_state(container).phase, CheckInPhase.idle);
    });

    test('the tap survives the process: a new process sends the same key', () async {
      final fakes = _fakes();
      fakes.server.failAfterRecording.add(const NetworkFailure());
      final first = _container(fakes);
      await _controller(first).checkIn();
      expect(_state(first).phase, CheckInPhase.pending);
      final stored = await _stored(fakes);
      expect(stored, isNotNull);
      first.dispose();

      // "Relaunch": a new container over the same storage and the same server.
      final second = _container(fakes);
      await pumpEventQueue();
      expect(_state(second).phase, CheckInPhase.success);
      expect(fakes.keys.issued, ['key-1']);
      expect({...fakes.server.checkInKeys}, {'key-1'});
      expect(fakes.server.recorded, 1);
      expect(await _stored(fakes), isNull);
    });

    test(
      'a restored tap that is still not confirmed keeps being retried',
      () async {
        final fakes = _fakes();
        fakes.server.failures['checkIn'] = [const NetworkFailure()];
        final first = _container(fakes);
        await _controller(first).checkIn();
        first.dispose();

        fakes.server.failures['checkIn'] = [const NetworkFailure()];
        final second = _container(fakes);
        await pumpEventQueue();
        expect(_state(second).phase, CheckInPhase.pending);
        expect(await _stored(fakes), isNotNull);
        expect(_state(second).tappedAt, fakes.clock.now());
      },
    );

    test('a tap of another account is never sent', () async {
      final fakes = _fakes();
      await fakes.secure.write(
        PendingCheckInStore.storageKey,
        PendingCheckIn(
          userId: 'someone-else',
          idempotencyKey: 'their-key',
          reportedAt: DateTime.utc(2026, 10, 7),
        ).encode(),
      );
      final container = _container(fakes);
      await pumpEventQueue();
      expect(_state(container).phase, CheckInPhase.idle);
      expect(fakes.server.calls, isEmpty);
    });

    test('a damaged record is ignored', () async {
      final fakes = _fakes();
      for (final raw in [
        '',
        'not json',
        '{"v":2}',
        '{"v":1,"user":"user-1"}',
      ]) {
        await fakes.secure.write(PendingCheckInStore.storageKey, raw);
        final container = _container(fakes);
        await pumpEventQueue();
        expect(_state(container).phase, CheckInPhase.idle, reason: raw);
        container.dispose();
      }
      expect(fakes.server.calls, isEmpty);
    });

    test(
      'signing out resets the controller; nothing is sent for nobody',
      () async {
        final fakes = _fakes();
        fakes.server.failures['checkIn'] = [const NetworkFailure()];
        final container = _container(fakes);
        await _controller(container).checkIn();
        expect(_state(container).phase, CheckInPhase.pending);

        (container.read(authControllerProvider.notifier) as FixedAuthController)
            .set(AuthStatus.signedOut);
        await pumpEventQueue();
        expect(_state(container).phase, CheckInPhase.idle);
        expect(fakes.timers.active, isEmpty, reason: 'the retry timer is gone');
        // The tap stays on the phone for the account that made it.
        expect(await _stored(fakes), isNotNull);
      },
    );
  });

  group('a tap that is too old to count', () {
    test('the limit is the 12 hour minimum window', () {
      expect(pendingCheckInMaxAge, const Duration(hours: 12));
    });

    test(
      'up to exactly 12 hours old it is still sent, with its own key',
      () async {
        for (final age in [
          Duration.zero,
          const Duration(hours: 11, minutes: 59),
          const Duration(hours: 12),
        ]) {
          final fakes = _fakes();
          await _seed(fakes, age: age);
          final container = _container(fakes);
          await pumpEventQueue();
          expect(_state(container).phase, CheckInPhase.success, reason: '$age');
          expect(fakes.server.checkInKeys, ['old-key'], reason: '$age');
          expect(fakes.keys.issued, isEmpty, reason: 'no new key is made');
          expect(fakes.server.recorded, 1);
          expect(await _stored(fakes), isNull);
          container.dispose();
        }
      },
    );

    test('a phone clock that moved back never drops a tap', () async {
      for (final age in [
        const Duration(seconds: -1),
        const Duration(minutes: -5),
        const Duration(days: -3),
      ]) {
        final fakes = _fakes();
        await _seed(fakes, age: age);
        final container = _container(fakes);
        await pumpEventQueue();
        expect(_state(container).phase, CheckInPhase.success, reason: '$age');
        expect(fakes.server.checkInKeys, ['old-key'], reason: '$age');
        container.dispose();
      }
    });

    test('older than that, a stored tap is never sent: it is cleared and the '
        'person is told', () async {
      for (final age in _tooOld) {
        final fakes = _fakes();
        await _seed(fakes, age: age);
        final container = _container(fakes);
        final phases = <CheckInPhase>[];
        container.listen(
          checkInControllerProvider,
          (_, next) => phases.add(next.phase),
        );
        await pumpEventQueue();

        final state = _state(container);
        expect(phases, [
          CheckInPhase.expired,
        ], reason: '$age: never "not received yet" or "sending"');
        expect(state.phase, CheckInPhase.expired, reason: '$age');
        expect(state.tappedAt, fakes.clock.now().subtract(age));
        expect(state.isUnconfirmed, isFalse);
        expect(state.failure, isNull);
        expect(state.result, isNull, reason: 'it never counts as checked in');
        expect(fakes.server.calls, isEmpty, reason: 'no request at all');
        expect(fakes.server.checkInKeys, isEmpty);
        expect(await _stored(fakes), isNull);
        expect(fakes.timers.created, isEmpty);
        container.dispose();
      }
    });

    test('the next tap after that is a new tap with a new key', () async {
      final fakes = _fakes();
      await _seed(fakes, age: const Duration(hours: 30));
      final container = _container(fakes);
      await pumpEventQueue();
      expect(_state(container).phase, CheckInPhase.expired);

      await _controller(container).checkIn();
      expect(_state(container).phase, CheckInPhase.success);
      expect(
        _state(container).tappedAt,
        isNull,
        reason: 'the notice is gone with the tap',
      );
      expect(fakes.keys.issued, ['key-1']);
      expect(fakes.server.checkInKeys, ['key-1']);
      expect(fakes.server.recorded, 1);
      expect(await _stored(fakes), isNull);
    });

    test('a tap of another account is ignored silently, however old', () async {
      final fakes = _fakes();
      await _seed(
        fakes,
        age: const Duration(days: 3),
        key: 'their-key',
        userId: 'someone-else',
      );
      final container = _container(fakes);
      await pumpEventQueue();
      expect(_state(container).phase, CheckInPhase.idle);
      expect(fakes.server.calls, isEmpty);
      expect(
        await _stored(fakes),
        isNotNull,
        reason: 'left for the account that made it',
      );
    });

    test('it can age out while the app stays open offline: the next retry '
        'drops it', () async {
      final fakes = _fakes();
      fakes.server.failures['checkIn'] = [
        const NetworkFailure(),
        const NetworkFailure(),
      ];
      final container = _container(fakes);
      await _controller(container).checkIn();
      final tapped = fakes.clock.now();
      expect(_state(container).phase, CheckInPhase.pending);

      // Still young at the first retry, which fails again.
      fakes.clock.advance(const Duration(hours: 11, minutes: 59));
      fakes.timers.fireNext();
      await pumpEventQueue();
      expect(_state(container).phase, CheckInPhase.pending);
      expect(fakes.server.checkInKeys, ['key-1', 'key-1']);
      expect(fakes.timers.active, hasLength(1));

      // Too old at the next one: nothing is sent and the retry timer is gone.
      fakes.clock.advance(const Duration(minutes: 2));
      fakes.timers.fireNext();
      await pumpEventQueue();
      expect(_state(container).phase, CheckInPhase.expired);
      expect(_state(container).tappedAt, tapped);
      expect(fakes.server.checkInKeys, ['key-1', 'key-1']);
      expect(fakes.timers.active, isEmpty);
      expect(await _stored(fakes), isNull);
    });

    test('a retry at exactly 12 hours is still sent', () async {
      final fakes = _fakes();
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      final container = _container(fakes);
      await _controller(container).checkIn();
      fakes.clock.advance(pendingCheckInMaxAge);
      fakes.timers.fireNext();
      await pumpEventQueue();
      expect(_state(container).phase, CheckInPhase.success);
      expect(fakes.server.checkInKeys, ['key-1', 'key-1']);
    });

    test('coming back to the foreground after it aged out drops it', () async {
      final fakes = _fakes();
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      final container = _container(fakes);
      await _controller(container).checkIn();
      expect(fakes.timers.active, hasLength(1));

      fakes.clock.advance(pendingCheckInMaxAge + const Duration(seconds: 1));
      await _controller(container).onResumed();
      expect(_state(container).phase, CheckInPhase.expired);
      expect(fakes.server.checkInKeys, ['key-1'], reason: 'no second request');
      expect(fakes.timers.active, isEmpty, reason: 'the backoff timer is gone');
      expect(await _stored(fakes), isNull);
    });

    test('Try again after it aged out drops it', () async {
      final fakes = _fakes();
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      final container = _container(fakes);
      await _controller(container).checkIn();

      fakes.clock.advance(const Duration(days: 2));
      await _controller(container).retryNow();
      expect(_state(container).phase, CheckInPhase.expired);
      expect(fakes.server.checkInKeys, ['key-1']);
      expect(fakes.timers.active, isEmpty);
      expect(await _stored(fakes), isNull);

      // Nothing is left to retry.
      await _controller(container).retryNow();
      await _controller(container).onResumed();
      expect(fakes.server.checkInKeys, ['key-1']);
      expect(_state(container).phase, CheckInPhase.expired);
    });

    test('the end of a 429 wait does not send a tap that aged out', () async {
      final fakes = _fakes();
      fakes.server.failures['checkIn'] = [
        const RateLimitedFailure(retryAfter: Duration(minutes: 20)),
      ];
      final container = _container(fakes);
      await _controller(container).checkIn();
      expect(_state(container).phase, CheckInPhase.rateLimited);

      fakes.clock.advance(pendingCheckInMaxAge + const Duration(seconds: 1));
      fakes.timers.fireNext();
      await pumpEventQueue();
      expect(_state(container).phase, CheckInPhase.expired);
      expect(_state(container).retryAt, isNull);
      expect(fakes.server.checkInKeys, ['key-1']);
      expect(await _stored(fakes), isNull);
    });

    test('a tap kept for a sign-in is dropped once it is too old', () async {
      final fakes = _fakes();
      fakes.server.failures['checkIn'] = [
        const UnauthorizedFailure(code: 'unauthenticated'),
      ];
      final container = _container(fakes);
      await _controller(container).checkIn();
      expect(_state(container).phase, CheckInPhase.signInRequired);

      fakes.clock.advance(const Duration(hours: 13));
      await _controller(container).onResumed();
      expect(_state(container).phase, CheckInPhase.expired);
      expect(fakes.server.checkInKeys, ['key-1']);
    });

    test('a tap kept for an update is replaced by a new tap once it is too '
        'old', () async {
      final fakes = _fakes();
      fakes.server.failures['checkIn'] = [const UpgradeRequiredFailure()];
      final container = _container(fakes);
      await _controller(container).checkIn();
      expect(_state(container).phase, CheckInPhase.failed);
      expect(await _stored(fakes), isNotNull);

      fakes.clock.advance(const Duration(hours: 13));
      await _controller(container).checkIn();
      expect(_state(container).phase, CheckInPhase.success);
      expect(fakes.server.checkInKeys, ['key-1', 'key-2']);
      expect(fakes.keys.issued, ['key-1', 'key-2']);
      expect(fakes.server.recorded, 1);
      expect(await _stored(fakes), isNull);
    });

    test('dismissing the notice goes back to idle and touches nothing '
        'else', () async {
      final fakes = _fakes();
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      final container = _container(fakes);
      await _controller(container).checkIn();
      expect(_state(container).phase, CheckInPhase.pending);
      _controller(container).dismissExpiredNotice();
      expect(_state(container).phase, CheckInPhase.pending);

      fakes.clock.advance(const Duration(hours: 13));
      await _controller(container).retryNow();
      expect(_state(container).phase, CheckInPhase.expired);
      _controller(container).dismissExpiredNotice();
      expect(_state(container), const CheckInState());
    });

    test('signing out clears the notice', () async {
      final fakes = _fakes();
      await _seed(fakes, age: const Duration(days: 1));
      final container = _container(fakes);
      await pumpEventQueue();
      expect(_state(container).phase, CheckInPhase.expired);

      (container.read(authControllerProvider.notifier) as FixedAuthController)
          .set(AuthStatus.signedOut);
      await pumpEventQueue();
      expect(_state(container).phase, CheckInPhase.idle);
    });

    test('a storage failure does not keep a tap alive past its age', () async {
      final fakes = _fakes();
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      final container = ProviderContainer.test(
        retry: (retryCount, error) => null,
        overrides: [
          ...testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
          pendingCheckInStoreProvider.overrideWithValue(
            PendingCheckInStore(
              secure: _BrokenSecureStore(),
              prefs: _BrokenPreferences(),
            ),
          ),
        ],
      );
      container.listen(checkInControllerProvider, (_, _) {});
      await _controller(container).checkIn();
      expect(_state(container).phase, CheckInPhase.pending);

      fakes.clock.advance(const Duration(hours: 13));
      await _controller(container).retryNow();
      expect(_state(container).phase, CheckInPhase.expired);
      expect(fakes.server.checkInKeys, ['key-1']);
    });
  });

  group('answers that are not retried blindly', () {
    test(
      '409 safe_required: nothing recorded, I\'M SAFE is needed, no retry',
      () async {
        final fakes = _fakes();
        fakes.server.failures['checkIn'] = [
          const ConflictFailure(code: 'safe_required'),
        ];
        final container = _container(fakes);
        await _controller(container).checkIn();
        expect(_state(container).phase, CheckInPhase.safeRequired);
        expect(_state(container).isUnconfirmed, isFalse);
        expect(await _stored(fakes), isNull);
        expect(fakes.timers.active, isEmpty);
        expect(fakes.server.recorded, 0);
      },
    );

    test('429: a calm wait, the same key sent again once it is over', () async {
      final fakes = _fakes();
      fakes.server.failures['checkIn'] = [
        const RateLimitedFailure(retryAfter: Duration(minutes: 20)),
      ];
      final container = _container(fakes);
      await _controller(container).checkIn();

      var state = _state(container);
      expect(state.phase, CheckInPhase.rateLimited);
      expect(state.isUnconfirmed, isTrue);
      expect(state.retryAt, fakes.clock.now().add(const Duration(minutes: 20)));
      expect(fakes.timers.delays, [const Duration(minutes: 20)]);
      expect(await _stored(fakes), isNotNull);

      // Taps and resumes during the wait send nothing.
      await _controller(container).checkIn();
      await _controller(container).onResumed();
      expect(fakes.server.checkInKeys, ['key-1']);

      fakes.clock.advance(const Duration(minutes: 20));
      fakes.timers.fireNext();
      await pumpEventQueue();
      state = _state(container);
      expect(state.phase, CheckInPhase.success);
      expect(fakes.server.checkInKeys, ['key-1', 'key-1']);
    });

    test('429 without Retry-After waits a minute; after the wait a tap '
        'sends again', () async {
      final fakes = _fakes();
      fakes.server.failures['checkIn'] = [const RateLimitedFailure()];
      final container = _container(fakes);
      await _controller(container).checkIn();
      expect(fakes.timers.delays, [const Duration(minutes: 1)]);
      fakes.clock.advance(const Duration(minutes: 2));
      await _controller(container).checkIn();
      expect(_state(container).phase, CheckInPhase.success);
    });

    test(
      '401 that survived the silent refresh: the tap is kept for later',
      () async {
        final fakes = _fakes();
        fakes.server.failures['checkIn'] = [
          const UnauthorizedFailure(code: 'unauthenticated'),
        ];
        final container = _container(fakes);
        await _controller(container).checkIn();
        expect(_state(container).phase, CheckInPhase.signInRequired);
        expect(_state(container).isUnconfirmed, isTrue);
        expect(await _stored(fakes), isNotNull);
        expect(fakes.timers.active, isEmpty);

        await _controller(container).onResumed();
        expect(_state(container).phase, CheckInPhase.success);
        expect({...fakes.server.checkInKeys}, {'key-1'});
      },
    );

    test('426: kept, because it works after an update', () async {
      final fakes = _fakes();
      fakes.server.failures['checkIn'] = [const UpgradeRequiredFailure()];
      final container = _container(fakes);
      await _controller(container).checkIn();
      expect(_state(container).phase, CheckInPhase.failed);
      expect(_state(container).failure, isA<UpgradeRequiredFailure>());
      expect(await _stored(fakes), isNotNull);
      await _controller(container).checkIn();
      expect(_state(container).phase, CheckInPhase.success);
      expect({...fakes.server.checkInKeys}, {'key-1'});
    });

    test(
      'an answer retrying cannot change is dropped; the next tap is new',
      () async {
        for (final failure in <AppFailure>[
          const ValidationFailure(code: 'validation_failed'),
          const ForbiddenFailure(code: 'forbidden'),
          const NotFoundFailure(),
          const ConflictFailure(code: 'invalid_state'),
        ]) {
          final fakes = _fakes();
          fakes.server.failures['checkIn'] = [failure];
          final container = _container(fakes);
          await _controller(container).checkIn();
          expect(
            _state(container).phase,
            CheckInPhase.failed,
            reason: '$failure',
          );
          expect(_state(container).failure, failure);
          expect(await _stored(fakes), isNull);
          expect(fakes.timers.active, isEmpty);

          await _controller(container).checkIn();
          expect(_state(container).phase, CheckInPhase.success);
          expect(fakes.server.checkInKeys, ['key-1', 'key-2']);
          container.dispose();
        }
      },
    );

    test('a storage failure never stops a check-in', () async {
      final fakes = _fakes();
      final container = ProviderContainer.test(
        retry: (retryCount, error) => null,
        overrides: [
          ...testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
          pendingCheckInStoreProvider.overrideWithValue(
            PendingCheckInStore(
              secure: _BrokenSecureStore(),
              prefs: _BrokenPreferences(),
            ),
          ),
        ],
      );
      container.listen(checkInControllerProvider, (_, _) {});
      await _controller(container).checkIn();
      expect(_state(container).phase, CheckInPhase.success);
    });
  });

  group('PendingCheckIn', () {
    test('round-trips and compares by value', () {
      final record = PendingCheckIn(
        userId: 'u',
        idempotencyKey: 'k',
        reportedAt: DateTime.utc(2026, 10, 8, 12),
      );
      final copy = PendingCheckIn.tryDecode(record.encode());
      expect(copy, record);
      expect(copy.hashCode, record.hashCode);
      expect(copy!.reportedAt.isUtc, isTrue);
      expect(PendingCheckIn.tryDecode(null), isNull);
      expect(PendingCheckIn.tryDecode('[]'), isNull);
      expect(
        PendingCheckIn.tryDecode(
          '{"v":1,"user":"u","key":"","reported_at":"x"}',
        ),
        isNull,
      );
      expect(
        PendingCheckIn.tryDecode(
          '{"v":1,"user":"u","key":"k","reported_at":"yesterday"}',
        ),
        isNull,
      );
      expect(
        PendingCheckIn.tryDecode(
          '{"v":1,"user":"u","key":"k","reported_at":3}',
        ),
        isNull,
      );
    });

    test('is too old only when made more than 12 hours before now', () {
      final record = PendingCheckIn(
        userId: 'u',
        idempotencyKey: 'k',
        reportedAt: DateTime.utc(2026, 10, 8, 12),
      );
      final at = record.reportedAt;
      expect(record.isStaleAt(at), isFalse);
      expect(
        record.isStaleAt(at.add(const Duration(hours: 12))),
        isFalse,
        reason: 'exactly at the limit',
      );
      expect(
        record.isStaleAt(at.add(const Duration(hours: 12, microseconds: 1))),
        isTrue,
      );
      expect(record.isStaleAt(at.add(const Duration(days: 30))), isTrue);
      // The clock moved back: a negative age.
      expect(record.isStaleAt(at.subtract(const Duration(days: 30))), isFalse);
      // Compared as instants, whatever zone either side is in.
      expect(
        record.isStaleAt(
          at.add(const Duration(hours: 12, seconds: 1)).toLocal(),
        ),
        isTrue,
      );
    });

    test('CheckInState compares by value', () {
      const a = CheckInState(phase: CheckInPhase.pending);
      expect(a, const CheckInState(phase: CheckInPhase.pending));
      expect(
        a.hashCode,
        const CheckInState(phase: CheckInPhase.pending).hashCode,
      );
      expect(a, isNot(const CheckInState()));
    });
  });
}

/// Preferences whose every call fails, like unreadable storage.
class _BrokenPreferences extends PreferencesStore {
  _BrokenPreferences() : super(SharedPreferencesAsync());

  @override
  Future<String?> getString(PreferenceKey key) async =>
      throw StateError('storage');

  @override
  Future<void> setString(PreferenceKey key, String value) async =>
      throw StateError('storage');

  @override
  Future<void> remove(PreferenceKey key) async => throw StateError('storage');
}

/// Secure storage whose every call fails, like a lost Keystore key.
class _BrokenSecureStore implements SecureStore {
  @override
  Future<String?> read(String key) async => throw StateError('storage');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('storage');

  @override
  Future<void> delete(String key) async => throw StateError('storage');

  @override
  Future<void> deleteAll() async => throw StateError('storage');
}
