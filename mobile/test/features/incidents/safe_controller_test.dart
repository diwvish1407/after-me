import 'dart:async';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/checkin/application/checkin_controller.dart';
import 'package:afterme/features/checkin/application/schedule_controller.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/home/application/home_controller.dart';
import 'package:afterme/features/incidents/application/safe_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/incident_fixtures.dart';
import '../../helpers/test_app.dart';

/// Contacts were told: Mom, and the server wants I'M SAFE. The test clock is moved to
/// the minute after the stage ran.
TestFakes _escalated() {
  final fakes = TestFakes();
  fakes.clock.current = DateTime.utc(2026, 10, 9, 17, 36, 20);
  fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
  fakes.plan.seedStandard(['c1']);
  fakes.server.activateNow();
  fakes.incidents.open(
    incidentJson(
      status: 'escalating',
      requires: 'safe',
      contactsMessaged: true,
      timeline: [
        reminderJson('missed', anchor),
        stageJson(
          1,
          graceEnds,
          status: 'executed',
          contacts: [contactJson(momId, 'Mom', result: 'messaged')],
        ),
      ],
    ),
  );
  fakes.auth.reauthenticated = true;
  return fakes;
}

ProviderContainer _container(TestFakes fakes) {
  final container = ProviderContainer.test(
    retry: (retryCount, error) => null,
    overrides: testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
  );
  container
    ..listen(safeControllerProvider, (_, _) {})
    ..listen(homeControllerProvider, (_, _) {})
    ..listen(checkInControllerProvider, (_, _) {});
  return container;
}

SafeController _controller(ProviderContainer c) =>
    c.read(safeControllerProvider.notifier);

SafeState _state(ProviderContainer c) => c.read(safeControllerProvider);

void main() {
  group('I\'M SAFE that goes through', () {
    test(
      'idle -> sending -> success, and success only after the 200',
      () async {
        final fakes = _escalated();
        final gate = Completer<void>();
        fakes.incidents.safeGate = gate.future;
        final container = _container(fakes);
        final phases = <SafePhase>[];
        container.listen(
          safeControllerProvider,
          (_, next) => phases.add(next.phase),
        );

        expect(_state(container).phase, SafePhase.idle);
        final call = _controller(container).markSafe(incidentId);
        await pumpEventQueue();
        expect(_state(container).phase, SafePhase.sending);
        expect(_state(container).isSending, isTrue);
        expect(
          _state(container).result,
          isNull,
          reason: 'nothing confirmed yet',
        );
        expect(fakes.incidents.stopped, 0);

        gate.complete();
        final result = await call;
        expect(_state(container).phase, SafePhase.success);
        expect(_state(container).result, result);
        expect(result.allClearSentTo.single.displayName, 'Mom');
        expect(result.nextDueAt, isNotNull);
        expect(fakes.incidents.stopped, 1);
        expect(phases, [SafePhase.sending, SafePhase.success]);
      },
    );

    test('sends one idempotency key', () async {
      final fakes = _escalated();
      final container = _container(fakes);
      await _controller(container).markSafe(incidentId);
      expect(fakes.incidents.safeKeys, ['key-1']);
    });

    test('the key made in the app is a random UUID the server accepts', () {
      final container = ProviderContainer.test();
      final make = container.read(safeKeyGeneratorProvider);
      final first = make();
      expect(first, matches(RegExp(r'^[A-Za-z0-9_.:-]{16,64}$')));
      expect(make(), isNot(first));
    });

    test('two taps while it is on the wire send one request', () async {
      final fakes = _escalated();
      final gate = Completer<void>();
      fakes.incidents.safeGate = gate.future;
      final container = _container(fakes);
      final first = _controller(container).markSafe(incidentId);
      final second = _controller(container).markSafe(incidentId);
      expect(identical(first, second), isTrue);
      gate.complete();
      await Future.wait([first, second]);
      expect(fakes.incidents.safeKeys, ['key-1']);
      expect(fakes.incidents.stopped, 1);
    });

    test(
      'Home shows the incident closed straight away and reads again',
      () async {
        final fakes = _escalated();
        final container = _container(fakes);
        var data = (await container.read(homeControllerProvider.future))!;
        expect(data.snapshot.incidentDetails, isNotNull);
        expect(data.snapshot.checkin.status, CheckInStatus.incidentOpen);

        // The aggregate is not read again, so only the answer of I'M SAFE is on screen.
        fakes.server.failures['home'] = [const NetworkFailure()];
        final result = await _controller(container).markSafe(incidentId);
        await pumpEventQueue();
        data = container.read(homeControllerProvider).value!;
        expect(data.snapshot.incident, isNull);
        expect(data.snapshot.checkin.status, CheckInStatus.active);
        expect(data.snapshot.checkin.nextDueAt, result.nextDueAt);
        expect(data.snapshot.checkin.lastCheckinAt, result.serverTime);
      },
    );

    test(
      'Home that has not loaded yet reads again instead of guessing',
      () async {
        final fakes = _escalated();
        final container = _container(fakes);
        // Home is still loading when the answer arrives.
        final result = await _controller(container).markSafe(incidentId);
        final data = (await container.read(homeControllerProvider.future))!;
        expect(data.snapshot.incident, isNull);
        expect(data.snapshot.checkin.status, CheckInStatus.active);
        expect(result.incidentId, incidentId);
      },
    );

    test('a schedule that is off has no next deadline in the answer', () async {
      final fakes = _escalated();
      fakes.incidents.scheduleOffAfterSafe = true;
      final container = _container(fakes);
      var data = (await container.read(homeControllerProvider.future))!;
      expect(data.snapshot.incident, isNotNull);
      fakes.server.failures['home'] = [const NetworkFailure()];
      final result = await _controller(container).markSafe(incidentId);
      expect(result.nextDueAt, isNull);
      await pumpEventQueue();
      data = container.read(homeControllerProvider).value!;
      expect(data.snapshot.checkin.status, CheckInStatus.inactive);
      expect(data.snapshot.checkin.nextDueAt, isNull);
    });

    test('a check-in that was told to confirm safety is cleared', () async {
      final fakes = _escalated();
      final container = _container(fakes);
      await container.read(homeControllerProvider.future);
      await container.read(checkInControllerProvider.notifier).checkIn();
      expect(
        container.read(checkInControllerProvider).phase,
        CheckInPhase.safeRequired,
      );
      await _controller(container).markSafe(incidentId);
      await pumpEventQueue();
      expect(
        container.read(checkInControllerProvider).phase,
        CheckInPhase.idle,
      );
    });

    test(
      'the schedule is read again: the incident that locked it is over',
      () async {
        final fakes = _escalated();
        final container = _container(fakes);
        container.listen(scheduleControllerProvider, (_, _) {});
        final before = await container.read(scheduleControllerProvider.future);
        expect(before!.status, CheckInStatus.incidentOpen);
        await _controller(container).markSafe(incidentId);
        await pumpEventQueue();
        final after = container.read(scheduleControllerProvider).value!;
        expect(after.status, CheckInStatus.active);
      },
    );
  });

  group('SafeState', () {
    test('is a value', () {
      const a = SafeState(phase: SafePhase.sending, incidentId: 'i-1');
      const b = SafeState(phase: SafePhase.sending, incidentId: 'i-1');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const SafeState()));
      expect(const SafeState().isSending, isFalse);
      expect(const SafeState().notConfirmed, isFalse);
    });
  });

  group('I\'M SAFE that is not confirmed', () {
    test(
      'a network failure is not a success, and the retry reuses the key',
      () async {
        final fakes = _escalated();
        fakes.incidents.failures['markSafe'] = [const NetworkFailure()];
        final container = _container(fakes);

        await expectLater(
          _controller(container).markSafe(incidentId),
          throwsA(isA<NetworkFailure>()),
        );
        expect(_state(container).phase, SafePhase.failed);
        expect(_state(container).notConfirmed, isTrue);
        expect(_state(container).result, isNull);
        expect(fakes.incidents.stopped, 0);

        await _controller(container).markSafe(incidentId);
        expect(_state(container).phase, SafePhase.success);
        expect(fakes.incidents.safeKeys, ['key-1', 'key-1']);
        expect(fakes.incidents.stopped, 1);
      },
    );

    test('an answer lost after the server stopped it is replayed, not '
        'stopped again', () async {
      final fakes = _escalated();
      fakes.incidents.failAfterRecording.add(const NetworkFailure());
      final container = _container(fakes);

      await expectLater(
        _controller(container).markSafe(incidentId),
        throwsA(isA<NetworkFailure>()),
      );
      expect(fakes.incidents.stopped, 1, reason: 'the server did record it');
      expect(_state(container).phase, SafePhase.failed);

      final result = await _controller(container).markSafe(incidentId);
      expect(fakes.incidents.stopped, 1);
      expect(fakes.incidents.replays, 1);
      expect(fakes.incidents.safeKeys, ['key-1', 'key-1']);
      expect(result.allClearSentTo.single.displayName, 'Mom');
      expect(_state(container).phase, SafePhase.success);
    });

    test('a rate limit is an answer, not "we do not know": nothing was '
        'processed', () async {
      final fakes = _escalated();
      fakes.incidents.failures['markSafe'] = [
        const RateLimitedFailure(retryAfter: Duration(minutes: 10)),
        const NetworkFailure(),
      ];
      final container = _container(fakes);
      await expectLater(
        _controller(container).markSafe(incidentId),
        throwsA(isA<RateLimitedFailure>()),
      );
      expect(_state(container).phase, SafePhase.failed);
      expect(_state(container).notConfirmed, isFalse);

      await expectLater(
        _controller(container).markSafe(incidentId),
        throwsA(isA<NetworkFailure>()),
      );
      expect(_state(container).notConfirmed, isTrue);
    });

    test('a server error and a rate limit keep the key too', () async {
      final fakes = _escalated();
      fakes.incidents.failures['markSafe'] = [
        const ServerFailure(statusCode: 503),
        const RateLimitedFailure(retryAfter: Duration(minutes: 1)),
        const UnauthorizedFailure(code: 'token_expired'),
      ];
      final container = _container(fakes);
      for (var i = 0; i < 3; i++) {
        await expectLater(
          _controller(container).markSafe(incidentId),
          throwsA(isA<AppFailure>()),
        );
      }
      await _controller(container).markSafe(incidentId);
      expect(fakes.incidents.safeKeys, ['key-1', 'key-1', 'key-1', 'key-1']);
      expect(fakes.incidents.stopped, 1);
    });

    test(
      '403 reauth_required keeps the key and says the password is needed',
      () async {
        final fakes = _escalated();
        fakes.auth.reauthenticated = false;
        final container = _container(fakes);
        await expectLater(
          _controller(container).markSafe(incidentId),
          throwsA(
            isA<ForbiddenFailure>().having(
              (f) => f.code,
              'code',
              'reauth_required',
            ),
          ),
        );
        expect(_state(container).needsPassword, isTrue);
        expect(_state(container).notConfirmed, isFalse);
        expect(fakes.incidents.stopped, 0);

        fakes.auth.reauthenticated = true;
        await _controller(container).markSafe(incidentId);
        expect(fakes.incidents.safeKeys, ['key-1', 'key-1']);
        expect(fakes.incidents.stopped, 1);
      },
    );

    test('409 invalid_state: already closed, nothing to retry, a new key '
        'next time', () async {
      final fakes = _escalated();
      fakes.incidents.failures['markSafe'] = [const InvalidStateFailure()];
      final container = _container(fakes);
      await expectLater(
        _controller(container).markSafe(incidentId),
        throwsA(isA<InvalidStateFailure>()),
      );
      expect(_state(container).alreadyClosed, isTrue);
      expect(_state(container).notConfirmed, isFalse);

      _controller(container).reset();
      expect(_state(container).phase, SafePhase.idle);
      await _controller(container).markSafe(incidentId);
      expect(fakes.incidents.safeKeys, ['key-1', 'key-2']);
    });

    test(
      'an incident that is not open is an invalid_state from the server',
      () async {
        final fakes = _escalated();
        final container = _container(fakes);
        await expectLater(
          _controller(container)
              .markSafe('00000000-0000-4000-8000-0000000000ff'),
          throwsA(isA<InvalidStateFailure>()),
        );
        expect(_state(container).alreadyClosed, isTrue);
      },
    );

    test('refusals that retrying cannot change drop the key', () async {
      final fakes = _escalated();
      fakes.incidents.failures['markSafe'] = [
        const NotFoundFailure(),
        const ValidationFailure(code: 'validation_failed'),
        const ForbiddenFailure(code: 'forbidden'),
      ];
      final container = _container(fakes);
      for (var i = 0; i < 3; i++) {
        await expectLater(
          _controller(container).markSafe(incidentId),
          throwsA(isA<AppFailure>()),
        );
        expect(_state(container).notConfirmed, isFalse);
      }
      await _controller(container).markSafe(incidentId);
      expect(fakes.incidents.safeKeys, ['key-1', 'key-2', 'key-3', 'key-4']);
    });

    test('another incident is another intent with its own key', () async {
      final fakes = _escalated();
      fakes.incidents.failures['markSafe'] = [const NetworkFailure()];
      final container = _container(fakes);
      await expectLater(
        _controller(container).markSafe('someone-elses'),
        throwsA(isA<NetworkFailure>()),
      );
      await _controller(container).markSafe(incidentId);
      expect(fakes.incidents.safeKeys, ['key-1', 'key-2']);
    });

    test(
      'reset does not forget a key that is still waiting for an answer',
      () async {
        final fakes = _escalated();
        final gate = Completer<void>();
        fakes.incidents.safeGate = gate.future;
        final container = _container(fakes);
        final call = _controller(container).markSafe(incidentId);
        await pumpEventQueue();
        _controller(container).reset();
        expect(_state(container).phase, SafePhase.sending);
        gate.complete();
        await call;
        expect(_state(container).phase, SafePhase.success);
      },
    );
  });
}
