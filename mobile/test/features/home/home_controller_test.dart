import 'dart:async';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/features/auth/application/me_controller.dart';
import 'package:afterme/features/auth/data/auth_repository.dart';
import 'package:afterme/features/checkin/application/checkin_controller.dart';
import 'package:afterme/features/checkin/application/schedule_controller.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/contacts/application/contacts_controller.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/home/application/client_checks.dart';
import 'package:afterme/features/home/application/home_controller.dart';
import 'package:afterme/features/home/application/home_status.dart';
import 'package:afterme/features/plan/application/plan_controller.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/test_app.dart';

ProviderContainer _container(TestFakes fakes) {
  final container = ProviderContainer.test(
    retry: (retryCount, error) => null,
    overrides: testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
  );
  container
    ..listen(homeControllerProvider, (_, _) {})
    ..listen(checkInControllerProvider, (_, _) {});
  return container;
}

Future<HomeData> _home(ProviderContainer c) async {
  final data = await c.read(homeControllerProvider.future);
  return data!;
}

int _homeCalls(TestFakes fakes) =>
    fakes.server.calls.where((c) => c == 'home').length;

void main() {
  group('HomeController', () {
    test('loads the aggregate and calibrates the clock offset from '
        'server_time', () async {
      final fakes = TestFakes();
      fakes.server.skew = const Duration(minutes: 45);
      final container = _container(fakes);
      final data = await _home(container);

      expect(data.snapshot.user.displayName, 'Diwakar');
      expect(data.snapshot.checkin.status, CheckInStatus.inactive);
      expect(data.stale, isFalse);
      expect(data.serverOffset, const Duration(minutes: 45));
      expect(
        data.serverNow(fakes.clock.now()),
        fakes.clock.now().add(const Duration(minutes: 45)),
      );
    });

    test('Due soon follows the server clock, not the phone\'s alone', () async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      fakes.server
        ..reminderLead = 30
        ..skew = const Duration(minutes: 45)
        ..activateNow();
      // The next deadline, on the server's clock, is in 12+ hours; move it close.
      fakes.server.nextDueAt = fakes.server.now.add(
        const Duration(minutes: 40),
      );
      final container = _container(fakes);
      final data = await _home(container);

      final deviceNow = fakes.clock.now();
      // By the phone's clock alone the deadline is 85 minutes away: not due soon.
      expect(
        homeStatus(data.snapshot, serverNow: deviceNow),
        HomeStatus.active,
      );
      // By the server's clock (offset from GET /home) it is 40 minutes away.
      expect(
        homeStatus(data.snapshot, serverNow: data.serverNow(deviceNow)),
        HomeStatus.active,
      );
      fakes.clock.advance(const Duration(minutes: 15));
      expect(
        homeStatus(data.snapshot, serverNow: data.serverNow(fakes.clock.now())),
        HomeStatus.dueSoon,
        reason: '25 minutes left on the server clock, lead is 30',
      );
      expect(
        homeStatus(data.snapshot, serverNow: fakes.clock.now()),
        HomeStatus.active,
        reason: 'the phone clock alone would say 70 minutes',
      );
    });

    test(
      'a confirmed check-in updates what Home shows, from the answer',
      () async {
        final fakes = TestFakes();
        fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
        fakes.server.activateNow();
        final container = _container(fakes);
        await _home(container);

        await container.read(checkInControllerProvider.notifier).checkIn();
        await pumpEventQueue();
        final data = await _home(container);
        final result = container.read(checkInControllerProvider).result!;
        expect(data.snapshot.checkin.lastCheckinAt, result.checkin.receivedAt);
        expect(data.snapshot.checkin.nextDueAt, result.nextDueAt);
        expect(
          _homeCalls(fakes),
          2,
          reason: 'then the aggregate is read again',
        );
      },
    );

    test('a replayed check-in answer does not move the clock offset', () async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      fakes.server.activateNow();
      // The first answer is lost on the way back; the server did record it.
      fakes.server.failAfterRecording.add(const NetworkFailure());
      final container = _container(fakes);
      final before = await _home(container);
      expect(before.serverOffset, Duration.zero);

      await container.read(checkInControllerProvider.notifier).checkIn();
      expect(
        container.read(checkInControllerProvider).phase,
        CheckInPhase.pending,
      );

      // Hours later the app is online again and the same key is sent. The server
      // answers with the ORIGINAL answer, whose server_time is three hours old.
      fakes.clock.advance(const Duration(hours: 3));
      // The aggregate read that follows fails, so only the replay is in play.
      fakes.server.failures['home'] = [const NetworkFailure()];
      fakes.timers.fireNext();
      await pumpEventQueue();

      final state = container.read(checkInControllerProvider);
      expect(state.phase, CheckInPhase.success, reason: 'it was recorded');
      expect(fakes.server.replays, 1);
      expect(
        state.result!.serverTime,
        DateTime.utc(2026, 10, 8, 12),
        reason: 'the replay carries the original server_time',
      );
      final data = await _home(container);
      expect(data.serverOffset, Duration.zero, reason: 'not moved to -3 h');
      expect(
        data.serverNow(fakes.clock.now()),
        DateTime.utc(2026, 10, 8, 15),
        reason: 'still the phone clock plus the offset from GET /home',
      );
      // Due soon is computed from that offset: a deadline 20 minutes after 15:00.
      final snapshot = data.snapshot.copyWith(
        checkin: data.snapshot.checkin.copyWith(
          nextDueAt: DateTime.utc(2026, 10, 8, 15, 20),
        ),
      );
      expect(
        homeStatus(snapshot, serverNow: data.serverNow(fakes.clock.now())),
        HomeStatus.dueSoon,
      );
    });

    test(
      'a refresh that fails keeps the last good data and marks it stale',
      () async {
        final fakes = TestFakes();
        final container = _container(fakes);
        await _home(container);
        fakes.server.failures['home'] = [const NetworkFailure()];

        final failure = await container
            .read(homeControllerProvider.notifier)
            .refresh();
        expect(failure, isA<NetworkFailure>());
        final data = container.read(homeControllerProvider).value!;
        expect(data.stale, isTrue);
        expect(data.snapshot.user.displayName, 'Diwakar');

        // The next good answer clears it.
        expect(
          await container.read(homeControllerProvider.notifier).refresh(),
          isNull,
        );
        expect(container.read(homeControllerProvider).value!.stale, isFalse);
      },
    );

    test(
      'server trouble marks stale; a non-transient failure does not',
      () async {
        final fakes = TestFakes();
        final container = _container(fakes);
        await _home(container);
        fakes.server.failures['home'] = [const ServerFailure(statusCode: 500)];
        await container.read(homeControllerProvider.notifier).refresh();
        expect(container.read(homeControllerProvider).value!.stale, isTrue);

        await container.read(homeControllerProvider.notifier).refresh();
        fakes.server.failures['home'] = [
          const ForbiddenFailure(code: 'forbidden'),
        ];
        await container.read(homeControllerProvider.notifier).refresh();
        expect(container.read(homeControllerProvider).value!.stale, isFalse);
      },
    );

    test('the first load failing is an error with the failure', () async {
      final fakes = TestFakes();
      fakes.server.failures['home'] = [const NetworkFailure()];
      final container = _container(fakes);
      await expectLater(
        container.read(homeControllerProvider.future),
        throwsA(isA<NetworkFailure>()),
      );
      expect(container.read(homeControllerProvider).hasError, isTrue);

      // Trying again works and replaces the error.
      expect(
        await container.read(homeControllerProvider.notifier).refresh(),
        isNull,
      );
      expect(container.read(homeControllerProvider).value, isNotNull);
    });

    test(
      'a refresh that fails with nothing on hand becomes the error',
      () async {
        final fakes = TestFakes();
        fakes.server.failures['home'] = [
          const NetworkFailure(),
          const NetworkFailure(),
        ];
        final container = _container(fakes);
        await container
            .read(homeControllerProvider.future)
            .then<void>((_) {}, onError: (_) {});
        final failure = await container
            .read(homeControllerProvider.notifier)
            .refresh();
        expect(failure, isA<NetworkFailure>());
        expect(container.read(homeControllerProvider).hasError, isTrue);
      },
    );

    test('refreshes that overlap are one request', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      await _home(container);
      final gate = Completer<void>();
      fakes.server.homeGate = gate.future;
      final controller = container.read(homeControllerProvider.notifier);
      final a = controller.refresh();
      final b = controller.refresh();
      gate.complete();
      await Future.wait([a, b]);
      expect(_homeCalls(fakes), 2, reason: 'the first load plus one refresh');
    });

    test(
      'an older answer cannot overwrite a check-in that landed meanwhile',
      () async {
        final fakes = TestFakes();
        fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
        fakes.server.activateNow();
        final container = _container(fakes);
        await _home(container);

        // A refresh is on its way (it was started before the check-in)...
        final gate = Completer<void>();
        fakes.server.homeGate = gate.future;
        final refreshing = container
            .read(homeControllerProvider.notifier)
            .refresh();
        await pumpEventQueue();
        // ...when the check-in is confirmed.
        await container.read(checkInControllerProvider.notifier).checkIn();
        final result = container.read(checkInControllerProvider).result!;
        gate.complete();
        await refreshing;
        await pumpEventQueue();

        final data = container.read(homeControllerProvider).value!;
        expect(data.snapshot.checkin.lastCheckinAt, result.checkin.receivedAt);
        expect(data.snapshot.checkin.nextDueAt, result.nextDueAt);
      },
    );

    test('a resolved incident closes on screen', () async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      fakes.server.activateNow();
      fakes.server.openIncident(details: {'id': 'i-1'});
      final container = _container(fakes);
      var data = await _home(container);
      expect(
        homeStatus(data.snapshot, serverNow: fakes.clock.now()),
        HomeStatus.incident,
      );
      // Home is not read again, so only the check-in's own answer is on screen.
      fakes.server.failures['home'] = [const NetworkFailure()];
      await container.read(checkInControllerProvider.notifier).checkIn();
      await pumpEventQueue();
      data = container.read(homeControllerProvider).value!;
      expect(data.snapshot.incident, isNull);
      expect(data.snapshot.checkin.status, CheckInStatus.active);
      expect(
        container.read(checkInControllerProvider).result!.incidentResolved,
        isTrue,
      );
    });

    test('reads again after a schedule change, a contact change and a '
        'timezone change', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      container.listen(scheduleControllerProvider, (_, _) {});
      container.listen(contactsControllerProvider, (_, _) {});
      container.listen(meControllerProvider, (_, _) {});
      await _home(container);
      await container.read(scheduleControllerProvider.future);
      await container.read(contactsControllerProvider.future);
      await container.read(meControllerProvider.future);
      await pumpEventQueue();
      final start = _homeCalls(fakes);

      await container
          .read(scheduleControllerProvider.notifier)
          .save(const CheckInSchedule(intervalDays: 2));
      await pumpEventQueue();
      expect(_homeCalls(fakes), start + 1, reason: 'schedule');

      await container
          .read(contactsControllerProvider.notifier)
          .addContact(
            const ContactDraft(
              name: 'Mom',
              relationship: ContactRelationship.mother,
              email: 'mom@example.com',
            ),
          );
      await pumpEventQueue();
      expect(_homeCalls(fakes), start + 2, reason: 'contacts');

      await container
          .read(meControllerProvider.notifier)
          .patchProfile(const ProfilePatch(timezone: 'Europe/London'));
      await pumpEventQueue();
      expect(_homeCalls(fakes), start + 3, reason: 'timezone');
    });

    test('a gap in a safety net that is on follows the fix: contact, then '
        'plan', () async {
      final fakes = TestFakes();
      fakes.server.activateNow();
      final container = _container(fakes);
      container
        ..listen(contactsControllerProvider, (_, _) {})
        ..listen(planControllerProvider, (_, _) {});
      await container.read(contactsControllerProvider.future);
      await container.read(planControllerProvider.future);

      SafetyNetGap? gap() => pickSafetyNetGap(
        container.read(homeControllerProvider).value!.snapshot.readiness,
      );

      await _home(container);
      expect(gap(), SafetyNetGap.noContacts, reason: 'nobody to tell');

      await container
          .read(contactsControllerProvider.notifier)
          .addContact(
            const ContactDraft(
              name: 'Mom',
              relationship: ContactRelationship.mother,
              email: 'mom@example.com',
            ),
          );
      await pumpEventQueue();
      expect(gap(), SafetyNetGap.noStages, reason: 'Home read again');

      // The password is asked for: check-ins are on and the plan changes.
      const draft = PlanDraft(
        graceMinutes: 180,
        stages: [
          PlanStageDraft(offsetMinutes: 180, contactIds: ['contact-1']),
        ],
      );
      await expectLater(
        container.read(planControllerProvider.notifier).save(draft),
        throwsA(isA<ForbiddenFailure>()),
      );
      expect(gap(), SafetyNetGap.noStages, reason: 'nothing was saved');
      fakes.auth.reauthenticated = true;
      await container.read(planControllerProvider.notifier).save(draft);
      await pumpEventQueue();
      expect(gap(), isNull, reason: 'Home read again after the plan');

      // The same contact removed (password still fresh): the gap is back.
      await container
          .read(contactsControllerProvider.notifier)
          .removeContact('contact-1');
      fakes.plan.forgetContact('contact-1');
      await pumpEventQueue();
      await container.read(homeControllerProvider.notifier).refresh();
      expect(gap(), SafetyNetGap.noContacts);
    });

    test('signing out empties it', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      await _home(container);
      (container.read(authControllerProvider.notifier) as FixedAuthController)
          .set(AuthStatus.signedOut);
      expect(await container.read(homeControllerProvider.future), isNull);
      expect(
        await container.read(homeControllerProvider.notifier).refresh(),
        isNull,
      );
    });

    test('serverNowProvider is the phone clock plus the offset', () async {
      final fakes = TestFakes();
      fakes.server.skew = const Duration(minutes: 7);
      final container = _container(fakes);
      expect(
        container.read(serverNowProvider)(),
        fakes.clock.now(),
        reason: 'nothing calibrated yet',
      );
      await _home(container);
      expect(
        container.read(serverNowProvider)(),
        fakes.clock.now().add(const Duration(minutes: 7)),
      );
    });
  });

  group('ClientChecksController', () {
    test(
      'reads the notification permission and the phone\'s timezone',
      () async {
        final fakes = TestFakes();
        fakes.notifications.current = NotificationPermission.permanentlyDenied;
        fakes.device.deviceTimezone = 'Europe/London';
        final container = _container(fakes);
        expect(
          container.read(clientChecksProvider).notifications,
          NotificationPermission.unknown,
        );
        expect(container.read(clientChecksProvider).notificationsOff, isFalse);

        await container.read(clientChecksProvider.notifier).refresh();
        final checks = container.read(clientChecksProvider);
        expect(checks.notificationsOff, isTrue);
        expect(checks.deviceTimezone, 'Europe/London');

        fakes.notifications.current = NotificationPermission.granted;
        await container.read(clientChecksProvider.notifier).refresh();
        expect(container.read(clientChecksProvider).notificationsOff, isFalse);
      },
    );
  });
}
