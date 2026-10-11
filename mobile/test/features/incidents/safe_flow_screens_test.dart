import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/design_system/check_in_button.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/incidents/application/safe_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/incident_fixtures.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/real_fonts.dart';
import '../../helpers/test_app.dart';

/// I'M SAFE (USER_FLOWS.md §7): the password, the confirmation that says who is told and
/// what was already seen, and the server's answer; and every way it can go wrong.
///
/// The test clock is 2026-10-10T15:00Z, 8:30 PM in Asia/Kolkata: stage 2 ran at 8:00 PM,
/// Brother opened "House emergency" at 8:20 PM.
TestFakes _world({
  List<Map<String, dynamic>>? releases,
  Map<String, dynamic>? incident,
}) {
  final fakes = TestFakes();
  fakes.clock.current = DateTime.utc(2026, 10, 10, 15);
  fakes.notifications.current = NotificationPermission.granted;
  fakes.contacts = InMemoryContactsRepository(
    tier: 'premium',
    initial: [
      testContact(),
      testContact(
        id: 'c2',
        name: 'Brother',
        relationship: ContactRelationship.sibling,
        email: 'brother@example.com',
        priority: 2,
      ),
    ],
  );
  fakes.plan.seedStandard(['c1']);
  fakes.server.activateNow();
  fakes.incidents.open(
    incident ??
        escalatedJson(
          stage2Ran: true,
          releases:
              releases ??
              [
                releaseJson(
                  firstViewedAt: DateTime.utc(2026, 10, 10, 14, 50, 5),
                  lastViewedAt: DateTime.utc(2026, 10, 10, 14, 50, 5),
                  viewCount: 1,
                ),
              ],
        ),
  );
  return fakes;
}

Future<void> _password(WidgetTester tester, TestFakes fakes) async {
  expect(find.text("Confirm it's you"), findsOneWidget);
  await typeInto(tester, 'Password', fakes.auth.password);
  await tapText(tester, 'Confirm');
  await tester.pumpAndSettle();
}

/// Home → I'M SAFE → password → the confirmation sheet.
Future<void> _toConfirmation(WidgetTester tester, TestFakes fakes) async {
  await tapText(tester, "I'M SAFE");
  await tester.pumpAndSettle();
  await _password(tester, fakes);
  expect(find.text("Confirm you're safe"), findsOneWidget);
}

Future<void> _openHome(WidgetTester tester, TestFakes fakes) =>
    openApp(tester, fakes: fakes, route: AppRoutes.home);

void main() {
  setUpAll(loadRoboto);

  group('the way through', () {
    testWidgets('password, confirmation, then what the server answered', (
      tester,
    ) async {
      final fakes = _world();
      await _openHome(tester, fakes);

      await tapText(tester, "I'M SAFE");
      await tester.pumpAndSettle();
      expect(
        find.text(
          "Confirming that you're safe stops your plan and tells the people "
          'who were notified, so it needs your password.',
        ),
        findsOneWidget,
      );
      expect(fakes.incidents.safeKeys, isEmpty, reason: 'nothing sent yet');
      await _password(tester, fakes);

      // The confirmation: who is told, what is taken back, what was seen.
      expect(find.text("We'll tell Mom and Brother you're safe."), findsOne);
      expect(
        find.text(
          'Information shared with Brother will no longer be available.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          "Brother viewed “House emergency” at 8:20 PM. That can't be undone.",
        ),
        findsOneWidget,
      );
      expect(
        find.text('Escalation stops. Your check-in schedule restarts.'),
        findsOneWidget,
      );
      expect(find.text("Confirm I'm safe"), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      expect(fakes.incidents.safeKeys, isEmpty, reason: 'still nothing sent');

      await tapText(tester, "Confirm I'm safe");
      await tester.pumpAndSettle();

      expect(find.text("You're marked safe"), findsOneWidget);
      expect(
        find.textContaining('An all-clear is being sent to Mom and Brother.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Your next check-in is tomorrow at 8:00 PM.'),
        findsOneWidget,
      );
      expect(fakes.incidents.safeKeys, ['key-1']);
      expect(fakes.incidents.stopped, 1);

      await tapText(tester, 'Done');
      await tester.pumpAndSettle();
      // Home is the active state again, with no incident.
      expect(find.text("You're checked in"), findsOneWidget);
      expect(find.text("I'M SAFE"), findsNothing);
      expect(find.text('Your contacts have been notified'), findsNothing);
      expect(find.byType(CheckInButton), findsOneWidget);
    });

    testWidgets('two quick taps on I\'M SAFE open one password sheet', (
      tester,
    ) async {
      final fakes = _world();
      await _openHome(tester, fakes);
      final button = find.text("I'M SAFE");
      await tester.tap(button);
      await tester.tap(button, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsOneWidget);
      await _password(tester, fakes);
      expect(find.text("Confirm you're safe"), findsOneWidget);
      await tapText(tester, 'Not now');
      await tester.pumpAndSettle();
      // And the flow can be started again afterwards.
      await tapText(tester, "I'M SAFE");
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsOneWidget);
    });

    testWidgets('a wrong password stays on the password sheet and sends '
        'nothing', (tester) async {
      final fakes = _world();
      await _openHome(tester, fakes);
      await tapText(tester, "I'M SAFE");
      await tester.pumpAndSettle();
      await typeInto(tester, 'Password', 'not the password');
      await tapText(tester, 'Confirm');
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(find.text("Confirm you're safe"), findsNothing);
      expect(fakes.incidents.safeKeys, isEmpty);
    });

    testWidgets('closing the password sheet changes nothing', (tester) async {
      final fakes = _world();
      await _openHome(tester, fakes);
      await tapText(tester, "I'M SAFE");
      await tester.pumpAndSettle();
      await tapText(tester, 'Cancel');
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(find.text("Confirm you're safe"), findsNothing);
      expect(fakes.incidents.calls, isEmpty);
      expect(find.text("I'M SAFE"), findsOneWidget);
    });

    testWidgets('"Not now" closes the confirmation and sends nothing', (
      tester,
    ) async {
      final fakes = _world();
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);
      await tapText(tester, 'Not now');
      await tester.pumpAndSettle();
      expect(find.text("Confirm you're safe"), findsNothing);
      expect(fakes.incidents.safeKeys, isEmpty);
      expect(fakes.incidents.stopped, 0);
      expect(find.text("I'M SAFE"), findsOneWidget);
    });
  });

  group('what the confirmation says', () {
    testWidgets('only what applies: nothing shared, nothing viewed', (
      tester,
    ) async {
      final fakes = _world(releases: const []);
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);
      expect(find.text("We'll tell Mom and Brother you're safe."), findsOne);
      expect(find.textContaining('will no longer be available'), findsNothing);
      expect(find.textContaining("can't be undone"), findsNothing);
      expect(
        find.text('Escalation stops. Your check-in schedule restarts.'),
        findsOneWidget,
      );
    });

    testWidgets('something shared and not yet opened', (tester) async {
      final fakes = _world(releases: [releaseJson()]);
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);
      expect(
        find.text(
          'Information shared with Brother will no longer be available.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining("can't be undone"), findsNothing);
    });

    testWidgets('a view of something whose title cannot be shown', (
      tester,
    ) async {
      final fakes = _world(
        releases: [
          releaseJson(
            title: null,
            firstViewedAt: DateTime.utc(2026, 10, 10, 14, 50, 5),
            viewCount: 1,
          ),
        ],
      );
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);
      expect(
        find.text(
          "Brother viewed an instruction at 8:20 PM. That can't be undone.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('a view on another day says the date', (tester) async {
      final fakes = _world(
        releases: [
          releaseJson(
            firstViewedAt: DateTime.utc(2026, 10, 9, 14, 50, 5),
            viewCount: 1,
          ),
        ],
      );
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);
      // The date as well as the time, in the profile's zone (a view yesterday would
      // otherwise read as one today).
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Text &&
              (w.data ?? '').startsWith(
                'Brother viewed “House emergency” at ',
              ) &&
              (w.data ?? '').contains('Oct 9') &&
              (w.data ?? '').contains('8:20 PM') &&
              (w.data ?? '').endsWith("That can't be undone."),
        ),
        findsOneWidget,
      );
    });

    testWidgets('it reads the incident again, so a view since Home was read '
        'is on it', (tester) async {
      final fakes = _world(releases: const []);
      await _openHome(tester, fakes);
      expect(fakes.secureScreen.calls, isEmpty, reason: 'no title on Home');
      // Brother opened it after Home was last read.
      fakes.incidents.open(
        escalatedJson(
          stage2Ran: true,
          releases: [
            releaseJson(
              firstViewedAt: DateTime.utc(2026, 10, 10, 14, 58),
              viewCount: 1,
            ),
          ],
        ),
      );
      await tapText(tester, "I'M SAFE");
      await tester.pumpAndSettle();
      await _password(tester, fakes);
      expect(
        find.text(
          "Brother viewed “House emergency” at 8:28 PM. That can't be undone.",
        ),
        findsOneWidget,
      );
      // The title is on screen: the window is secure while the sheet shows it.
      expect(fakes.secureScreen.secure, isTrue);
      await tapText(tester, 'Not now');
      await tester.pumpAndSettle();
      expect(fakes.secureScreen.secure, isFalse);
    });

    testWidgets('without the incident\'s details it still asks plainly', (
      tester,
    ) async {
      final fakes = _world(incident: {'id': incidentId, 'status': 'grace'});
      fakes.server.failures['checkIn'] = [
        const ConflictFailure(code: 'safe_required'),
      ];
      await _openHome(tester, fakes);
      await tester.tap(find.byType(CheckInButton));
      await tester.pumpAndSettle();
      fakes.incidents.failures['get'] = [const NetworkFailure()];
      await _toConfirmation(tester, fakes);
      expect(
        find.text("We'll tell the people who were notified that you're safe."),
        findsOneWidget,
      );
      expect(
        find.text('Escalation stops. Your check-in schedule restarts.'),
        findsOneWidget,
      );
    });

    testWidgets('nobody notified yet says there is no one to tell', (
      tester,
    ) async {
      final fakes = _world(incident: incidentJson(requires: 'safe'));
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);
      expect(
        find.text(
          'No one has been notified yet, so there is no one to send an '
          'all-clear to.',
        ),
        findsOneWidget,
      );
      await tapText(tester, "Confirm I'm safe");
      await tester.pumpAndSettle();
      expect(find.text("You're marked safe"), findsOneWidget);
      expect(
        find.textContaining(
          'No one had been notified, so no all-clear was '
          'needed.',
        ),
        findsOneWidget,
      );
    });
  });

  group('while it is on the wire', () {
    testWidgets('the buttons are off, a second tap sends nothing more, and '
        'success waits for the 200', (tester) async {
      final fakes = _world();
      final gate = Completer<void>();
      fakes.incidents.safeGate = gate.future;
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);

      await tapText(tester, "Confirm I'm safe");
      await tester.pump();
      await tester.pump();
      FilledButton confirm() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, "Confirm I'm safe"),
      );
      expect(confirm().onPressed, isNull);
      // A second tap on the disabled button does nothing.
      await tester.tap(
        find.widgetWithText(FilledButton, "Confirm I'm safe"),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(fakes.incidents.safeKeys, ['key-1']);
      expect(find.text("You're marked safe"), findsNothing);
      expect(fakes.incidents.stopped, 0);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text("You're marked safe"), findsOneWidget);
      expect(fakes.incidents.safeKeys, ['key-1']);
      expect(fakes.incidents.stopped, 1);
    });

    testWidgets('the Home button is off meanwhile', (tester) async {
      final fakes = _world();
      final gate = Completer<void>();
      fakes.incidents.safeGate = gate.future;
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
      );
      await _toConfirmation(tester, fakes);
      await tapText(tester, "Confirm I'm safe");
      await tester.pump();
      expect(container.read(safeControllerProvider).isSending, isTrue);
      gate.complete();
      await tester.pumpAndSettle();
    });
  });

  group('when it is not confirmed', () {
    testWidgets('a network failure says so, and "Try again" sends the same '
        'key', (tester) async {
      final fakes = _world();
      fakes.incidents.failures['markSafe'] = [const NetworkFailure()];
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);
      await tapText(tester, "Confirm I'm safe");
      await tester.pumpAndSettle();

      expect(find.text("We couldn't confirm that"), findsOneWidget);
      expect(find.textContaining('it is not marked as done'), findsOneWidget);
      expect(find.text("You're marked safe"), findsNothing);
      expect(find.textContaining('An all-clear'), findsNothing);
      expect(fakes.incidents.stopped, 0);

      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.text("You're marked safe"), findsOneWidget);
      expect(fakes.incidents.safeKeys, ['key-1', 'key-1']);
      expect(fakes.incidents.stopped, 1);
    });

    testWidgets('an answer lost on the way back is not applied twice', (
      tester,
    ) async {
      final fakes = _world();
      fakes.incidents.failAfterRecording.add(const NetworkFailure());
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);
      await tapText(tester, "Confirm I'm safe");
      await tester.pumpAndSettle();
      expect(find.text("We couldn't confirm that"), findsOneWidget);
      expect(fakes.incidents.stopped, 1);

      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.text("You're marked safe"), findsOneWidget);
      expect(fakes.incidents.stopped, 1);
      expect(fakes.incidents.replays, 1);
    });

    testWidgets('"Not now" after a failure leaves the incident open', (
      tester,
    ) async {
      final fakes = _world();
      fakes.incidents.failures['markSafe'] = [const NetworkFailure()];
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);
      await tapText(tester, "Confirm I'm safe");
      await tester.pumpAndSettle();
      await tapText(tester, 'Not now');
      await tester.pumpAndSettle();
      expect(find.text("I'M SAFE"), findsOneWidget);
      expect(find.text('Your contacts have been notified'), findsOneWidget);
    });

    testWidgets('already closed is said calmly and Home catches up', (
      tester,
    ) async {
      final fakes = _world();
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);
      // Closed somewhere else while the sheet was open.
      fakes.incidents.failures['markSafe'] = [const InvalidStateFailure()];
      fakes.server.closeIncidentSafe();
      await tapText(tester, "Confirm I'm safe");
      await tester.pumpAndSettle();

      expect(find.text('This was already closed'), findsOneWidget);
      expect(find.text("You're marked safe"), findsNothing);
      expect(find.textContaining('went wrong'), findsNothing);
      await tapText(tester, 'Done');
      await tester.pumpAndSettle();
      expect(find.text("I'M SAFE"), findsNothing);
      expect(find.text("You're checked in"), findsOneWidget);
    });

    testWidgets('closed already when the confirmation opens', (tester) async {
      final fakes = _world();
      await _openHome(tester, fakes);
      await tapText(tester, "I'M SAFE");
      await tester.pumpAndSettle();
      // The person checked in on the web while the password sheet was open.
      fakes.incidents.addClosed({
        ...fakes.server.incident!,
        'status': 'cancelled',
        'requires': null,
        'closed_at': iso(DateTime.utc(2026, 10, 10, 14, 59)),
        'closed_by': 'user_safe',
      });
      fakes.server.closeIncidentSafe();
      await _password(tester, fakes);
      expect(find.text('This was already closed'), findsOneWidget);
      expect(find.text("Confirm I'm safe"), findsNothing);
      expect(fakes.incidents.safeKeys, isEmpty);
    });

    testWidgets('the server asking for the password again asks once and '
        'sends the same key', (tester) async {
      final fakes = _world();
      fakes.incidents.failures['markSafe'] = [
        const ForbiddenFailure(code: 'reauth_required'),
      ];
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);
      await tapText(tester, "Confirm I'm safe");
      await tester.pumpAndSettle();
      // The password sheet again, on top of the confirmation.
      expect(find.text("Confirm it's you"), findsOneWidget);
      await _password(tester, fakes);
      expect(find.text("You're marked safe"), findsOneWidget);
      expect(fakes.incidents.safeKeys, ['key-1', 'key-1']);
      expect(fakes.incidents.stopped, 1);
    });

    testWidgets('a password the server still asks for right after it was '
        'accepted is said, not looped on in silence', (tester) async {
      final fakes = _world();
      fakes.incidents.failures['markSafe'] = [
        const ForbiddenFailure(code: 'reauth_required'),
        const ForbiddenFailure(code: 'reauth_required'),
      ];
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);
      await tapText(tester, "Confirm I'm safe");
      await tester.pumpAndSettle();
      // The sheet, the password, and the very same answer again.
      await _password(tester, fakes);

      expect(find.text("Confirm you're safe"), findsOneWidget);
      expect(
        find.text(
          'For your security, please confirm your password to continue.',
        ),
        findsOneWidget,
        reason: 'a notice, instead of the password sheet opening again',
      );
      expect(find.text("You're marked safe"), findsNothing);
      expect(fakes.incidents.stopped, 0);

      // Trying again works (the notice goes with the attempt) and keeps the key.
      await tapText(tester, "Confirm I'm safe");
      await tester.pumpAndSettle();
      expect(find.text("You're marked safe"), findsOneWidget);
      expect(fakes.incidents.safeKeys, ['key-1', 'key-1', 'key-1']);
    });

    testWidgets('closing that password sheet leaves the confirmation as it '
        'was, with no error', (tester) async {
      final fakes = _world();
      fakes.incidents.failures['markSafe'] = [
        const ForbiddenFailure(code: 'reauth_required'),
      ];
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);
      await tapText(tester, "Confirm I'm safe");
      await tester.pumpAndSettle();
      await tapText(tester, 'Cancel');
      await tester.pumpAndSettle();
      expect(find.text("Confirm you're safe"), findsOneWidget);
      expect(find.textContaining('password again'), findsNothing);
      expect(find.text("Confirm I'm safe"), findsOneWidget);
      expect(fakes.incidents.stopped, 0);
    });

    testWidgets('too many attempts is said as that, not as "we do not know '
        'whether this went through"', (tester) async {
      final fakes = _world();
      fakes.incidents.failures['markSafe'] = [
        const RateLimitedFailure(retryAfter: Duration(minutes: 10)),
      ];
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);
      await tapText(tester, "Confirm I'm safe");
      await tester.pumpAndSettle();

      expect(find.text("We couldn't confirm that"), findsNothing);
      expect(find.textContaining('Try again in 10 minutes'), findsOneWidget);
      expect(find.text("Confirm you're safe"), findsOneWidget);
      expect(find.text("Confirm I'm safe"), findsOneWidget);
    });

    testWidgets('a refusal that is not retryable is said with the app\'s own '
        'words', (tester) async {
      final fakes = _world();
      fakes.incidents.failures['markSafe'] = [
        const ForbiddenFailure(code: 'forbidden'),
      ];
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);
      await tapText(tester, "Confirm I'm safe");
      await tester.pumpAndSettle();
      expect(find.text("Confirm you're safe"), findsOneWidget);
      expect(
        find.text("That isn't available for your account."),
        findsOneWidget,
        reason: 'the confirmation stays, with a calm notice above it',
      );
      expect(find.text("You're marked safe"), findsNothing);
    });
  });

  group('from the timeline screen', () {
    testWidgets('the same flow, and the screen then says nothing is open', (
      tester,
    ) async {
      final fakes = _world();
      await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
      expect(find.text('Timeline'), findsOneWidget);
      await tapText(tester, "I'M SAFE");
      await tester.pumpAndSettle();
      await _password(tester, fakes);
      await tapText(tester, "Confirm I'm safe");
      await tester.pumpAndSettle();
      expect(find.text("You're marked safe"), findsOneWidget);
      await tapText(tester, 'Done');
      await tester.pumpAndSettle();
      expect(find.text('No missed check-in right now'), findsOneWidget);
      expect(find.text("I'M SAFE"), findsNothing);
    });
  });

  group('screen readers', () {
    testWidgets('the confirmation has a heading and labelled buttons, and the '
        'answer is announced when it appears', (tester) async {
      final handle = tester.ensureSemantics();
      final fakes = _world();
      await _openHome(tester, fakes);
      await _toConfirmation(tester, fakes);

      expect(
        tester
            .getSemantics(find.text("Confirm you're safe"))
            .flagsCollection
            .isHeader,
        isTrue,
      );
      final confirm = tester.getSemantics(
        find.widgetWithText(FilledButton, "Confirm I'm safe"),
      );
      expect(confirm.label, contains("Confirm I'm safe"));
      expect(confirm.flagsCollection.isButton, isTrue);
      expect(confirm.flagsCollection.isEnabled, Tristate.isTrue);
      final cancel = tester.getSemantics(
        find.widgetWithText(OutlinedButton, 'Not now'),
      );
      expect(cancel.flagsCollection.isButton, isTrue);

      await tapText(tester, "Confirm I'm safe");
      await tester.pumpAndSettle();
      final answer = tester.getSemantics(find.text("You're marked safe"));
      expect(answer.flagsCollection.isHeader, isTrue);
      // The sheet's content is one live region, so it is read out as it appears.
      final node = tester.getSemantics(find.text("You're marked safe"));
      var live = node.flagsCollection.isLiveRegion;
      for (
        var ancestor = node.parent;
        ancestor != null && !live;
        ancestor = ancestor.parent
      ) {
        live = ancestor.flagsCollection.isLiveRegion;
      }
      expect(live, isTrue);
      handle.dispose();
    });
  });

  group('large text', () {
    testWidgets('the confirmation and the answer fit at 2.0', (tester) async {
      final fakes = _world();
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
        size: const Size(320, 690),
        textScale: 2,
        roboto: true,
      );
      await _toConfirmation(tester, fakes);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text("Confirm I'm safe"));
      await tapText(tester, "Confirm I'm safe");
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text("You're marked safe"), findsOneWidget);
    });
  });
}
