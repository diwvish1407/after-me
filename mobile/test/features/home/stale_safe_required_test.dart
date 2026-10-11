import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/design_system/check_in_button.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/features/checkin/application/checkin_controller.dart';
import 'package:afterme/features/home/application/home_controller.dart';
import 'package:afterme/features/incidents/application/safe_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/incident_fixtures.dart';
import '../../helpers/test_app.dart';

/// "Contacts were already told, use I'M SAFE" (409 `safe_required`) is true for **one
/// incident**. When that incident ends somewhere else (the web page, the lost-phone flow,
/// the operator) the answer must not outlive it: it kept Home asking for I'M SAFE and,
/// worse, turned the next incident (nobody told yet) into "Your contacts have been
/// notified".
const _stillOpen = 'inc-2';

/// An incident the server is holding, contacts told: Mom.
TestFakes _escalated({DateTime? now}) {
  final fakes = TestFakes();
  fakes.clock.current = now ?? DateTime.utc(2026, 10, 9, 17, 36, 20);
  fakes.notifications.current = NotificationPermission.granted;
  fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
  fakes.plan.seedStandard(['c1']);
  fakes.server.activateNow();
  fakes.incidents.open(escalatedJson());
  fakes.auth.reauthenticated = true;
  return fakes;
}

ProviderContainer _container(TestFakes fakes) {
  final container = ProviderContainer.test(
    retry: (retryCount, error) => null,
    overrides: testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
  );
  container
    ..listen(homeControllerProvider, (_, _) {})
    ..listen(safeControllerProvider, (_, _) {})
    ..listen(checkInControllerProvider, (_, _) {});
  return container;
}

CheckInState _tap(ProviderContainer c) => c.read(checkInControllerProvider);

/// I'M OK refused with `safe_required`, and Home read again.
Future<void> _refused(ProviderContainer container) async {
  await container.read(homeControllerProvider.future);
  await container.read(checkInControllerProvider.notifier).checkIn();
  await pumpEventQueue();
  expect(_tap(container).phase, CheckInPhase.safeRequired);
  expect(_tap(container).failure?.problem?.incidentId, incidentId);
}

CheckInButtonState _button(WidgetTester tester) =>
    tester.widget<CheckInButton>(find.byType(CheckInButton)).state;

void main() {
  group('the answer is dropped when its incident is over', () {
    test('closed somewhere else: the next read of Home clears it', () async {
      final fakes = _escalated();
      final container = _container(fakes);
      await _refused(container);

      // I'M SAFE on the web page.
      fakes.server.closeIncidentSafe();
      expect(
        await container.read(homeControllerProvider.notifier).refresh(),
        isNull,
      );

      expect(
        container.read(homeControllerProvider).value!.snapshot.incident,
        isNull,
      );
      expect(
        _tap(container).phase,
        CheckInPhase.idle,
        reason: 'it used to stay until the process was restarted',
      );
    });

    test('another incident is open now: it is not about that one', () async {
      final fakes = _escalated();
      final container = _container(fakes);
      await _refused(container);

      // The first incident ended; a new one is in its grace period.
      fakes.incidents.open(incidentJson(id: _stillOpen));
      await container.read(homeControllerProvider.notifier).refresh();

      final home = container.read(homeControllerProvider).value!;
      expect(home.snapshot.incidentDetails!.id, _stillOpen);
      expect(home.snapshot.incidentDetails!.needsSafe, isFalse);
      expect(_tap(container).phase, CheckInPhase.idle);
    });

    test('I\'M SAFE answered "already closed" clears it even when Home cannot '
        'be read', () async {
      final fakes = _escalated();
      final container = _container(fakes);
      await _refused(container);

      fakes.server.closeIncidentSafe();
      fakes.server.failures['home'] = [const NetworkFailure()];
      await expectLater(
        container.read(safeControllerProvider.notifier).markSafe(incidentId),
        throwsA(isA<InvalidStateFailure>()),
      );
      await pumpEventQueue();

      expect(container.read(safeControllerProvider).alreadyClosed, isTrue);
      expect(_tap(container).phase, CheckInPhase.idle);
    });

    test('an answer about another incident is not cleared by this one\'s '
        '"already closed"', () async {
      final fakes = _escalated();
      final container = _container(fakes);
      await _refused(container);

      fakes.incidents.failures['markSafe'] = [const InvalidStateFailure()];
      fakes.server.failures['home'] = [const NetworkFailure()];
      await expectLater(
        container.read(safeControllerProvider.notifier).markSafe('inc-other'),
        throwsA(isA<InvalidStateFailure>()),
      );
      await pumpEventQueue();

      expect(_tap(container).phase, CheckInPhase.safeRequired);
    });

    test('an answer that names no incident cannot be told apart: an open '
        'incident that says nobody was told settles it', () async {
      final fakes = _escalated()..incidents.open(incidentJson());
      fakes.server.failures['checkIn'] = [
        const ConflictFailure(code: 'safe_required'),
      ];
      final container = _container(fakes);
      await container.read(homeControllerProvider.future);
      await container.read(checkInControllerProvider.notifier).checkIn();
      await pumpEventQueue();

      expect(_tap(container).phase, CheckInPhase.idle);
    });
  });

  group('the answer stays while it is true', () {
    test('it names the open incident and the aggregate is a moment behind: '
        'the server\'s word is kept', () async {
      // Contacts were told after Home was read: the tap is refused, the incident on
      // hand still says grace. It is the same incident, and contacts are never
      // "un-told": I'M SAFE stays.
      final fakes = _escalated()..incidents.open(incidentJson());
      fakes.server.contactsMessaged = true;
      final container = _container(fakes);
      await _refused(container);

      expect(
        container
            .read(homeControllerProvider)
            .value!
            .snapshot
            .incidentDetails!
            .needsSafe,
        isFalse,
      );
      expect(_tap(container).phase, CheckInPhase.safeRequired);
      expect(_tap(container).safeRequiredApplies(incidentId), isTrue);
      expect(_tap(container).safeRequiredApplies(_stillOpen), isFalse);
    });

    test('a read that cannot be made keeps it', () async {
      final fakes = _escalated();
      final container = _container(fakes);
      await _refused(container);

      fakes.server.failures['home'] = [const NetworkFailure()];
      await container.read(homeControllerProvider.notifier).refresh();
      expect(_tap(container).phase, CheckInPhase.safeRequired);
    });
  });

  group('on screen', () {
    testWidgets('closed elsewhere, then a new incident: Home asks for I\'M OK, '
        'never "contacts have been notified"', (tester) async {
      final fakes = _escalated()..incidents.open(incidentJson());
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
      );
      expect(find.byType(CheckInButton), findsOneWidget);

      // Contacts are told after Home was read: the tap is refused.
      fakes.incidents.open(escalatedJson());
      await tester.tap(find.byType(CheckInButton));
      await tester.pumpAndSettle();
      expect(find.text("I'M SAFE"), findsOneWidget);
      expect(find.text('Your contacts have been notified'), findsOneWidget);
      expect(find.byType(CheckInButton), findsNothing);

      // I'M SAFE on the web page; Home is read again.
      fakes.server.closeIncidentSafe();
      await container.read(homeControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(find.text("Please confirm you're safe"), findsNothing);
      expect(find.text("I'M SAFE"), findsNothing);
      expect(_button(tester), CheckInButtonState.idle);

      // Days later a check-in is missed again: nobody has been told.
      fakes.incidents.open(incidentJson(id: _stillOpen));
      await container.read(homeControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(find.text('You missed your 8:00 PM check-in'), findsOneWidget);
      expect(find.text('Your contacts have been notified'), findsNothing);
      expect(find.text('No one has been notified yet'), findsNothing);
      expect(find.text("I'M SAFE"), findsNothing);
      expect(_button(tester), CheckInButtonState.idle);
      expect(
        tester.widget<CheckInButton>(find.byType(CheckInButton)).onPressed,
        isNotNull,
        reason:
            'I\'M OK is offered: it resolves an incident nobody was told of',
      );
    });

    testWidgets('the timeline screen applies the same rule', (tester) async {
      final fakes = _escalated()..incidents.open(incidentJson());
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
      );
      fakes.incidents.open(escalatedJson());
      await tester.tap(find.byType(CheckInButton));
      await tester.pumpAndSettle();
      expect(find.text("I'M SAFE"), findsOneWidget);

      fakes.server.closeIncidentSafe();
      fakes.incidents.open(incidentJson(id: _stillOpen));
      container.read(routerProvider).go(AppRoutes.homeIncident);
      await tester.pumpAndSettle();

      expect(find.text('You missed your 8:00 PM check-in'), findsOneWidget);
      expect(find.text('Your contacts have been notified'), findsNothing);
      expect(find.text("I'M SAFE"), findsNothing);
      expect(find.text("I'M OK"), findsOneWidget);
    });
  });
}
