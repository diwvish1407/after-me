import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/auth/application/me_controller.dart';
import 'package:afterme/features/auth/data/auth_repository.dart';
import 'package:afterme/features/checkin/application/checkin_controller.dart';
import 'package:afterme/features/checkin/application/checkin_history_controller.dart';
import 'package:afterme/features/checkin/application/schedule_controller.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/test_app.dart';

ProviderContainer _container(TestFakes fakes) {
  final container = ProviderContainer.test(
    retry: (retryCount, error) => null,
    overrides: testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
  );
  container.listen(scheduleControllerProvider, (_, _) {});
  return container;
}

ScheduleController _controller(ProviderContainer c) =>
    c.read(scheduleControllerProvider.notifier);

void main() {
  group('ScheduleController', () {
    test(
      'a confirmed check-in refreshes the deadline on this screen',
      () async {
        final fakes = TestFakes();
        fakes.server.activateNow();
        final container = _container(fakes);
        container.listen(checkInControllerProvider, (_, _) {});
        final before = (await container.read(
          scheduleControllerProvider.future,
        ))!;
        expect(before.lastCheckinAt, isNull);

        fakes.clock.advance(const Duration(hours: 5));
        await container.read(checkInControllerProvider.notifier).checkIn();
        await pumpEventQueue();

        final after = container.read(scheduleControllerProvider).value!;
        expect(after.lastCheckinAt, fakes.clock.now());
        expect(after.nextDueAt, isNotNull);
        expect(
          after.version,
          before.version,
        ); // a check-in is not a schedule edit
      },
    );

    test('If-Match comes from the version, not from the ETag header', () {
      final snapshot = ScheduleSnapshot.fromJson(const {
        'interval_days': 1,
        'due_local_time': '20:00',
        'reminder_lead_minutes': 60,
        'timezone': 'Asia/Kolkata',
        'status': 'active',
        'next_due_at': null,
        'last_checkin_at': null,
        'version': 4,
      });
      expect(snapshot.copyWith(etag: 'W/"sched-4"').ifMatch, '"sched-4"');
      expect(snapshot.copyWith(etag: null).ifMatch, '"sched-4"');
      expect(snapshot.copyWith(etag: '"sched-9"').ifMatch, '"sched-4"');
    });

    test('loads the schedule the server has', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      final snapshot = await container.read(scheduleControllerProvider.future);
      expect(snapshot!.status, CheckInStatus.inactive);
      expect(snapshot.version, 1);
      expect(snapshot.ifMatch, '"sched-1"');
    });

    test(
      'save sends the ETag of what is on hand and keeps the new one',
      () async {
        final fakes = TestFakes();
        final container = _container(fakes);
        await container.read(scheduleControllerProvider.future);
        final saved = await _controller(container).save(
          const CheckInSchedule(
            intervalDays: 7,
            dueMinutes: 9 * 60,
            reminderLeadMinutes: 0,
          ),
        );
        expect(fakes.server.ifMatches, ['"sched-1"']);
        expect(saved.version, 2);
        expect(saved.intervalDays, 7);
        expect(saved.reminderLeadMinutes, 0);
        expect(container.read(scheduleControllerProvider).value, saved);
        expect(fakes.server.status, CheckInStatus.inactive);
      },
    );

    test('while on, a save restarts the clock on the server', () async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      fakes.server.activateNow();
      final before = fakes.server.nextDueAt;
      fakes.clock.advance(const Duration(days: 1));
      final container = _container(fakes);
      await container.read(scheduleControllerProvider.future);
      final saved = await _controller(container)
          .save(const CheckInSchedule(dueMinutes: 21 * 60));
      expect(saved.nextDueAt, isNot(before));
      expect(saved.nextDueAt, fakes.server.nextDueAt);
      expect(saved.nextDueAt!.isAfter(fakes.clock.now()), isTrue);
    });

    test('a stale save (412) reads the latest schedule and says so', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      await container.read(scheduleControllerProvider.future);
      // Changed from another device meanwhile.
      fakes.server
        ..intervalDays = 3
        ..version = 2;

      await expectLater(
        _controller(container).save(const CheckInSchedule(intervalDays: 2)),
        throwsA(
          isA<ConflictFailure>().having(
            (f) => f.code,
            'code',
            'precondition_failed',
          ),
        ),
      );
      final now = container.read(scheduleControllerProvider).value!;
      expect(now.version, 2);
      expect(now.intervalDays, 3, reason: 'the latest, not the draft');

      // Saving again with what is now on screen works.
      final saved = await _controller(container)
          .save(const CheckInSchedule(intervalDays: 2));
      expect(fakes.server.ifMatches, ['"sched-1"', '"sched-2"']);
      expect(saved.version, 3);
    });

    test('a missing If-Match (428) also reads again', () async {
      final fakes = TestFakes();
      fakes.server.failures['save'] = [
        const ConflictFailure(code: 'precondition_required'),
      ];
      final container = _container(fakes);
      await container.read(scheduleControllerProvider.future);
      fakes.server.version = 5;
      await expectLater(
        _controller(container).save(const CheckInSchedule()),
        throwsA(isA<ConflictFailure>()),
      );
      expect(container.read(scheduleControllerProvider).value!.version, 5);
    });

    test('an open incident (409) is thrown and nothing is re-read', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      await container.read(scheduleControllerProvider.future);
      fakes.server.openIncident();
      final reads = fakes.server.calls.where((c) => c == 'get').length;
      await expectLater(
        _controller(container).save(const CheckInSchedule()),
        throwsA(
          isA<ConflictFailure>().having((f) => f.code, 'code', 'incident_open'),
        ),
      );
      expect(fakes.server.calls.where((c) => c == 'get').length, reads);
    });

    test('a save before the schedule was read reads it first', () async {
      final fakes = TestFakes();
      fakes.server.failures['get'] = [const NetworkFailure()];
      final container = _container(fakes);
      await expectLater(
        container.read(scheduleControllerProvider.future),
        throwsA(isA<NetworkFailure>()),
      );
      final saved = await _controller(container)
          .save(const CheckInSchedule(intervalDays: 2));
      expect(fakes.server.ifMatches, ['"sched-1"']);
      expect(saved.intervalDays, 2);
    });

    test(
      'activate turns it on; unmet requirements are a typed failure',
      () async {
        final fakes = TestFakes();
        final container = _container(fakes);
        await container.read(scheduleControllerProvider.future);
        await expectLater(
          _controller(container).activate(),
          throwsA(
            isA<ActivationRequirementsFailure>().having(
              (f) => f.requirements,
              'requirements',
              ['no_contacts', 'no_stages'],
            ),
          ),
        );
        expect(
          container.read(scheduleControllerProvider).value!.status,
          CheckInStatus.inactive,
        );

        // A contact is not enough: the plan needs a stage that tells them.
        fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
        await expectLater(
          _controller(container).activate(),
          throwsA(
            isA<ActivationRequirementsFailure>().having(
              (f) => f.requirements,
              'requirements',
              ['no_stages'],
            ),
          ),
        );
        fakes.plan.seedStandard(['c1']);
        final active = await _controller(container).activate();
        expect(active.status, CheckInStatus.active);
        expect(active.nextDueAt, isNotNull);
        expect(container.read(scheduleControllerProvider).value, active);

        // Already on: unchanged.
        expect(await _controller(container).activate(), active);
      },
    );

    test('deactivate needs a recent re-authentication', () async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      fakes.server.activateNow();
      final container = _container(fakes);
      await container.read(scheduleControllerProvider.future);
      await expectLater(
        _controller(container).deactivate(),
        throwsA(
          isA<ForbiddenFailure>().having(
            (f) => f.code,
            'code',
            'reauth_required',
          ),
        ),
      );
      expect(fakes.server.status, CheckInStatus.active);

      fakes.auth.reauthenticated = true;
      final off = await _controller(container).deactivate();
      expect(off.status, CheckInStatus.inactive);
      expect(off.nextDueAt, isNull);
    });

    group('making the interval longer while check-ins are on', () {
      Future<(TestFakes, ProviderContainer)> active({int interval = 1}) async {
        final fakes = TestFakes();
        fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
        fakes.server.intervalDays = interval;
        fakes.server.activateNow();
        final container = _container(fakes);
        await container.read(scheduleControllerProvider.future);
        return (fakes, container);
      }

      test(
        'needs a recent re-authentication; the same save then works',
        () async {
          final (fakes, container) = await active();
          await expectLater(
            _controller(container).save(const CheckInSchedule(intervalDays: 7)),
            throwsA(
              isA<ForbiddenFailure>().having(
                (f) => f.code,
                'code',
                'reauth_required',
              ),
            ),
          );
          // Nothing changed, nothing was re-read: the next save is the same request.
          expect(fakes.server.intervalDays, 1);
          expect(fakes.server.version, 2);
          expect(container.read(scheduleControllerProvider).value!.version, 2);
          expect(fakes.server.calls.where((c) => c == 'get'), hasLength(1));

          fakes.auth.reauthenticated = true;
          final saved = await _controller(container)
              .save(const CheckInSchedule(intervalDays: 7));
          expect(saved.intervalDays, 7);
          expect(fakes.server.ifMatches, ['"sched-2"', '"sched-2"']);
        },
      );

      test('shortening, or changing the time or the reminder only, needs '
          'nothing', () async {
        final (fakes, container) = await active(interval: 7);
        final controller = _controller(container);
        expect(fakes.auth.reauthenticated, isFalse);

        await controller.save(const CheckInSchedule(intervalDays: 2));
        expect(fakes.server.intervalDays, 2);
        await controller.save(
          const CheckInSchedule(intervalDays: 2, dueMinutes: 21 * 60),
        );
        expect(fakes.server.dueMinutes, 21 * 60);
        await controller.save(
          const CheckInSchedule(
            intervalDays: 2,
            dueMinutes: 21 * 60,
            reminderLeadMinutes: 30,
          ),
        );
        expect(fakes.server.reminderLead, 30);
        // The same interval again is not a longer one.
        await controller.save(
          const CheckInSchedule(
            intervalDays: 2,
            dueMinutes: 21 * 60,
            reminderLeadMinutes: 30,
          ),
        );
        expect(fakes.server.calls.where((c) => c == 'save'), hasLength(4));
      });

      test('is not asked for while check-ins are off', () async {
        final fakes = TestFakes();
        final container = _container(fakes);
        await container.read(scheduleControllerProvider.future);
        final saved = await _controller(container)
            .save(const CheckInSchedule(intervalDays: 30));
        expect(saved.intervalDays, 30);
        expect(fakes.server.status, CheckInStatus.inactive);
      });

      test('is answered after the If-Match and the incident checks, like the '
          'server', () async {
        final (fakes, container) = await active();
        fakes.server.version = 5;
        await expectLater(
          _controller(container).save(const CheckInSchedule(intervalDays: 7)),
          throwsA(
            isA<ConflictFailure>().having(
              (f) => f.code,
              'code',
              'precondition_failed',
            ),
          ),
        );

        final (other, incident) = await active();
        other.server.openIncident();
        await expectLater(
          _controller(incident).save(const CheckInSchedule(intervalDays: 7)),
          throwsA(
            isA<ConflictFailure>().having(
              (f) => f.code,
              'code',
              'incident_open',
            ),
          ),
        );
      });
    });

    test('reload returns the failure and keeps what is on hand', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      final first = await container.read(scheduleControllerProvider.future);
      fakes.server.failures['get'] = [const NetworkFailure()];
      expect(await _controller(container).reload(), isA<NetworkFailure>());
      expect(container.read(scheduleControllerProvider).value, first);
      expect(await _controller(container).reload(), isNull);
    });

    test(
      'reload without anything on hand makes the failure the state',
      () async {
        final fakes = TestFakes();
        fakes.server.failures['get'] = [
          const NetworkFailure(),
          const NetworkFailure(),
        ];
        final container = _container(fakes);
        await container
            .read(scheduleControllerProvider.future)
            .then<void>((_) {}, onError: (_) {});
        expect(await _controller(container).reload(), isA<NetworkFailure>());
        expect(container.read(scheduleControllerProvider).hasError, isTrue);
      },
    );

    test('a timezone change reads the schedule again (new version, new '
        'deadline)', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      container.listen(meControllerProvider, (_, _) {});
      await container.read(scheduleControllerProvider.future);
      await container.read(meControllerProvider.future);
      final reads = fakes.server.calls.where((c) => c == 'get').length;

      fakes.server
        ..timezone = 'Europe/London'
        ..version = 2;
      await container
          .read(meControllerProvider.notifier)
          .patchProfile(const ProfilePatch(timezone: 'Europe/London'));
      await pumpEventQueue();
      expect(fakes.server.calls.where((c) => c == 'get').length, reads + 1);
      final now = container.read(scheduleControllerProvider).value!;
      expect(now.timezone, 'Europe/London');
      expect(now.version, 2);
    });

    test('signed out there is no schedule', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      await container.read(scheduleControllerProvider.future);
      (container.read(authControllerProvider.notifier) as FixedAuthController)
          .set(AuthStatus.signedOut);
      expect(await container.read(scheduleControllerProvider.future), isNull);
    });
  });

  group('CheckInHistoryController', () {
    ProviderContainer historyContainer(TestFakes fakes) {
      final container = ProviderContainer.test(
        retry: (retryCount, error) => null,
        overrides: testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
      );
      container.listen(checkInHistoryControllerProvider, (_, _) {});
      return container;
    }

    var tap = 0;
    Future<void> record(TestFakes fakes, int count) async {
      for (var i = 0; i < count; i++) {
        fakes.clock.advance(const Duration(minutes: 1));
        await fakes.server.checkIn(idempotencyKey: 'key-history-${tap++}-0000');
      }
    }

    test('the first page, then the next page by cursor', () async {
      final fakes = TestFakes();
      await record(fakes, 25);
      final container = historyContainer(fakes);
      var state = await container.read(checkInHistoryControllerProvider.future);
      expect(state.items, hasLength(20));
      expect(state.hasMore, isTrue);
      expect(
        state.items.first.receivedAt.isAfter(state.items.last.receivedAt),
        isTrue,
        reason: 'newest first',
      );

      await container
          .read(checkInHistoryControllerProvider.notifier)
          .loadMore();
      state = container.read(checkInHistoryControllerProvider).value!;
      expect(state.items, hasLength(25));
      expect(state.hasMore, isFalse);
      expect(state.loadingMore, isFalse);
      expect({for (final i in state.items) i.id}, hasLength(25));

      // Nothing more to load: no request.
      final calls = fakes.server.calls.length;
      await container
          .read(checkInHistoryControllerProvider.notifier)
          .loadMore();
      expect(fakes.server.calls.length, calls);
    });

    test('a failed "Show more" keeps the list and says why', () async {
      final fakes = TestFakes();
      await record(fakes, 25);
      final container = historyContainer(fakes);
      await container.read(checkInHistoryControllerProvider.future);
      fakes.server.failures['history'] = [const NetworkFailure()];
      final controller = container.read(
        checkInHistoryControllerProvider.notifier,
      );
      await controller.loadMore();
      var state = container.read(checkInHistoryControllerProvider).value!;
      expect(state.items, hasLength(20));
      expect(state.moreFailure, isA<NetworkFailure>());
      expect(state.loadingMore, isFalse);

      await controller.loadMore();
      state = container.read(checkInHistoryControllerProvider).value!;
      expect(state.items, hasLength(25));
      expect(state.moreFailure, isNull);
    });

    test('reload starts again from the first page and keeps the list on '
        'failure', () async {
      final fakes = TestFakes();
      await record(fakes, 3);
      final container = historyContainer(fakes);
      await container.read(checkInHistoryControllerProvider.future);
      await record(fakes, 1);
      final controller = container.read(
        checkInHistoryControllerProvider.notifier,
      );
      expect(await controller.reload(), isNull);
      expect(
        container.read(checkInHistoryControllerProvider).value!.items,
        hasLength(4),
      );

      fakes.server.failures['history'] = [const NetworkFailure()];
      expect(await controller.reload(), isA<NetworkFailure>());
      expect(
        container.read(checkInHistoryControllerProvider).value!.items,
        hasLength(4),
      );
    });

    test('the first load failing is an error that reload can clear', () async {
      final fakes = TestFakes();
      fakes.server.failures['history'] = [
        const NetworkFailure(),
        const NetworkFailure(),
      ];
      final container = historyContainer(fakes);
      await container
          .read(checkInHistoryControllerProvider.future)
          .then<void>((_) {}, onError: (_) {});
      final controller = container.read(
        checkInHistoryControllerProvider.notifier,
      );
      expect(await controller.reload(), isA<NetworkFailure>());
      expect(container.read(checkInHistoryControllerProvider).hasError, isTrue);
      expect(await controller.reload(), isNull);
      expect(container.read(checkInHistoryControllerProvider).value, isNotNull);
    });

    test('signed out it is empty', () async {
      final fakes = TestFakes();
      final container = ProviderContainer.test(
        retry: (retryCount, error) => null,
        overrides: testOverrides(
          authStatus: AuthStatus.signedOut,
          fakes: fakes,
        ),
      );
      container.listen(checkInHistoryControllerProvider, (_, _) {});
      final state = await container.read(
        checkInHistoryControllerProvider.future,
      );
      expect(state.items, isEmpty);
      expect(state.hasMore, isFalse);
      expect(fakes.server.calls, isEmpty);
    });
  });
}
