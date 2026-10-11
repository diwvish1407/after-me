import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/design_system/check_in_button.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/features/checkin/application/checkin_controller.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/home/application/home_controller.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show NavigationBar;

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/incident_fixtures.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/real_fonts.dart';
import '../../helpers/test_app.dart';

/// Home while an incident is open (USER_FLOWS.md §4): Grace and Escalating/Escalated.
///
/// The test clock is 8:00:21 PM in Asia/Kolkata (2026-10-09T14:30:21Z) unless a test
/// moves it; the incident is the contract's: due at 8:00 PM, grace until 11:00 PM.
TestFakes _world({DateTime? now}) {
  final fakes = TestFakes();
  fakes.clock.current = now ?? DateTime.utc(2026, 10, 9, 14, 30, 21);
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
  return fakes;
}

CheckInButtonState _button(WidgetTester tester) =>
    tester.widget<CheckInButton>(find.byType(CheckInButton)).state;

Future<void> _open(WidgetTester tester, TestFakes fakes) =>
    openApp(tester, fakes: fakes, route: AppRoutes.home);

void main() {
  setUpAll(loadRoboto);

  group('Grace: nobody has been told', () {
    testWidgets('says what was missed, who is told when, and offers I\'M OK', (
      tester,
    ) async {
      final fakes = _world()..incidents.open(incidentJson());
      await _open(tester, fakes);

      expect(find.text('You missed your 8:00 PM check-in'), findsOneWidget);
      expect(
        find.text('Mom will be notified at 11:00 PM unless you check in.'),
        findsOneWidget,
      );
      expect(_button(tester), CheckInButtonState.idle);
      expect(find.text("I'M OK"), findsOneWidget);
      expect(find.text("I'M SAFE"), findsNothing);
      // The neutral placeholder is gone.
      expect(find.text('Your check-in is overdue'), findsNothing);
    });

    testWidgets('lists what happens next, with the server\'s times', (
      tester,
    ) async {
      final fakes = _world()..incidents.open(incidentJson());
      await _open(tester, fakes);

      expect(find.text('What happens next'), findsOneWidget);
      expect(
        find.text('Reminder to you: you missed a check-in'),
        findsOneWidget,
      );
      expect(find.text('Sent to you'), findsOneWidget);
      expect(
        find.text("Reminder to you: we're still waiting for your check-in"),
        findsOneWidget,
      );
      expect(find.text('Today · 9:30 PM'), findsOneWidget);
      expect(
        find.text('Last reminder before your contacts are notified'),
        findsOneWidget,
      );
      expect(find.text('Today · 10:45 PM'), findsOneWidget);
      expect(find.text('Mom will be notified'), findsOneWidget);
      expect(find.text('Today · 11:00 PM'), findsOneWidget);
      expect(find.text('Scheduled'), findsNWidgets(3));
      expect(find.text('See the full timeline'), findsOneWidget);
    });

    testWidgets('names everybody the stage tells', (tester) async {
      final fakes = _world()
        ..incidents.open(
          incidentJson(
            timeline: [
              reminderJson('missed', anchor),
              stageJson(
                1,
                graceEnds,
                contacts: [
                  contactJson(momId, 'Mom'),
                  contactJson(brotherId, 'Brother'),
                ],
              ),
            ],
          ),
        );
      await _open(tester, fakes);
      expect(
        find.text(
          'Mom and Brother will be notified at 11:00 PM unless you check in.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a stage that was put back later is shown at its new time', (
      tester,
    ) async {
      final fakes = _world()
        ..incidents.open(
          incidentJson(
            timeline: [
              reminderJson('missed', anchor),
              stageJson(
                1,
                DateTime.utc(2026, 10, 9, 18, 15, 1),
                contacts: [contactJson(momId, 'Mom')],
              ),
            ],
          ),
        );
      await _open(tester, fakes);
      expect(
        find.text('Mom will be notified at 11:45 PM unless you check in.'),
        findsOneWidget,
      );
      expect(find.textContaining('11:00 PM'), findsNothing);
    });

    testWidgets('a stage whose time has come but has not run is not given a '
        'time in the past', (tester) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 9, 17, 40))
        ..incidents.open(incidentJson());
      await _open(tester, fakes);
      expect(
        find.text('Mom will be notified unless you check in.'),
        findsOneWidget,
      );
      expect(find.textContaining('11:00 PM unless'), findsNothing);
    });

    testWidgets('a held stage is said to be on hold', (tester) async {
      final fakes = _world()
        ..incidents.open(
          incidentJson(
            timeline: [
              reminderJson('missed', anchor),
              stageJson(
                1,
                graceEnds,
                status: 'held',
                contacts: [contactJson(momId, 'Mom')],
              ),
            ],
          ),
        );
      await _open(tester, fakes);
      expect(
        find.text(
          "The next step is on hold while we look into something. Tap I'M OK "
          "if you're all right.",
        ),
        findsOneWidget,
      );
      expect(find.text('On hold'), findsOneWidget);
    });

    testWidgets('without a stage in the timeline the grace period is used', (
      tester,
    ) async {
      final fakes = _world()
        ..incidents.open(
          incidentJson(timeline: [reminderJson('missed', anchor)]),
        );
      await _open(tester, fakes);
      expect(
        find.text(
          'Your trusted contacts will be notified at 11:00 PM unless you '
          'check in.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a time on another day says which day', (tester) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 9, 14, 30, 21))
        ..incidents.open(
          incidentJson(
            timeline: [
              reminderJson('missed', anchor),
              stageJson(
                1,
                DateTime.utc(2026, 10, 10, 2, 30, 1),
                contacts: [contactJson(momId, 'Mom')],
              ),
            ],
          ),
        );
      await _open(tester, fakes);
      expect(
        find.text(
          'Mom will be notified tomorrow at 8:00 AM unless you check in.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('I\'M OK resolves it: the server\'s word, then "no one was '
        'contacted"', (tester) async {
      final fakes = _world()..incidents.open(incidentJson());
      await _open(tester, fakes);

      await tester.tap(find.byType(CheckInButton));
      await tester.pumpAndSettle();
      expect(find.text('Welcome back. No one was contacted.'), findsOneWidget);
      expect(find.text('You missed your 8:00 PM check-in'), findsNothing);
      expect(find.text('What happens next'), findsNothing);
      expect(fakes.server.recorded, 1);
      // And it is in the history afterwards.
      final page = await fakes.incidents.list();
      expect(page.items.single.closedBy?.name, 'userCheckin');
    });

    testWidgets('a tap that is not received is said, and the incident stays '
        'in view', (tester) async {
      final fakes = _world()..incidents.open(incidentJson());
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      await _open(tester, fakes);

      await tester.tap(find.byType(CheckInButton));
      await tester.pumpAndSettle();
      expect(find.text("Not received yet — we'll keep trying"), findsOneWidget);
      expect(find.text('You missed your 8:00 PM check-in'), findsOneWidget);
      expect(
        find.text('Mom will be notified at 11:00 PM unless you check in.'),
        findsOneWidget,
      );
      expect(find.text('Welcome back. No one was contacted.'), findsNothing);
    });

    testWidgets('offline: the last known status is kept and said', (
      tester,
    ) async {
      final fakes = _world()..incidents.open(incidentJson());
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
      );
      fakes.server.failures['home'] = [const NetworkFailure()];
      await container.read(homeControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(find.text('Offline — showing last known status'), findsOneWidget);
      expect(find.text('You missed your 8:00 PM check-in'), findsOneWidget);
    });
  });

  group('Escalating and escalated: contacts have been told', () {
    testWidgets('says who was told and what comes next, and offers I\'M '
        'SAFE instead of I\'M OK', (tester) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 9, 17, 36, 20))
        ..incidents.open(escalatedJson());
      await _open(tester, fakes);

      expect(find.text('Your contacts have been notified'), findsOneWidget);
      expect(
        find.textContaining('Mom was notified at 11:00 PM.'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Next, Brother will be notified tomorrow at 8:00 PM, and 1 '
          'instruction will be shared with them.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining("If you're safe, tap I'M SAFE to let them know."),
        findsOneWidget,
      );
      expect(find.text("I'M SAFE"), findsOneWidget);
      expect(find.byType(CheckInButton), findsNothing);
      expect(find.text("I'M OK"), findsNothing);
      expect(find.text('You missed your 8:00 PM check-in'), findsNothing);
    });

    testWidgets('the timeline shows who was told and what is to be shared '
        'without naming it', (tester) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 9, 17, 36, 20))
        ..incidents.open(escalatedJson());
      await _open(tester, fakes);

      expect(
        find.text('What has happened and what comes next'),
        findsOneWidget,
      );
      expect(find.text('Mom was notified'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Brother will be notified'), findsOneWidget);
      expect(find.text('1 instruction to be shared'), findsOneWidget);
      expect(
        find.text('Warning to you: 1 instruction will be shared with Brother'),
        findsOneWidget,
      );
      // Nothing names an instruction that has not been released.
      expect(find.textContaining('House emergency'), findsNothing);
    });

    testWidgets('views are in the timeline: "Brother viewed “House '
        'emergency”" at 8:20 PM', (tester) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 10, 15))
        ..incidents.open(
          escalatedJson(
            stage2Ran: true,
            releases: [
              releaseJson(
                firstViewedAt: DateTime.utc(2026, 10, 10, 14, 50, 5),
                lastViewedAt: DateTime.utc(2026, 10, 10, 14, 50, 5),
                viewCount: 1,
              ),
            ],
          ),
        );
      await _open(tester, fakes);

      expect(find.text('Brother viewed “House emergency”'), findsOneWidget);
      expect(find.text('Today · 8:20 PM'), findsOneWidget);
      expect(
        find.textContaining('Mom was notified yesterday at 11:00 PM.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Brother was notified at 8:00 PM.'),
        findsOneWidget,
      );
      expect(find.textContaining('Nothing else is scheduled.'), findsOneWidget);
      expect(find.text('Brother was notified'), findsOneWidget);
      expect(find.text('1 instruction shared'), findsOneWidget);
    });

    testWidgets('a release that was taken back says so calmly', (tester) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 10, 15))
        ..incidents.open(
          escalatedJson(
            stage2Ran: true,
            releases: [
              releaseJson(
                firstViewedAt: DateTime.utc(2026, 10, 10, 14, 50, 5),
                lastViewedAt: DateTime.utc(2026, 10, 10, 14, 50, 5),
                viewCount: 1,
                revokedAt: DateTime.utc(2026, 10, 10, 14, 55),
                revokeReason: 'instruction_removed',
              ),
            ],
          ),
        );
      await _open(tester, fakes);
      expect(
        find.text('“House emergency” is no longer available to Brother'),
        findsOneWidget,
      );
      expect(
        find.text('You switched the instruction off or deleted it.'),
        findsOneWidget,
      );
    });

    testWidgets('a held stage and a stage with no one to name', (tester) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 9, 17, 36, 20))
        ..incidents.open(
          incidentJson(
            status: 'escalating',
            requires: 'safe',
            contactsMessaged: true,
            timeline: [
              stageJson(
                1,
                graceEnds,
                status: 'executed',
                contacts: [
                  contactJson(momId, 'Mom', result: 'messaged'),
                  contactJson(brotherId, 'Brother', result: 'skipped'),
                ],
              ),
              stageJson(
                2,
                DateTime.utc(2026, 10, 10, 14, 30, 1),
                status: 'held',
              ),
            ],
          ),
        );
      await _open(tester, fakes);
      expect(
        find.textContaining(
          'The next step is on hold while we look into '
          'something.',
        ),
        findsOneWidget,
      );
      // Only the person the server says was messaged is named as told.
      expect(find.text('Mom was notified'), findsOneWidget);
      expect(find.text('Nothing was sent to Brother.'), findsOneWidget);
      expect(
        find.text('Your trusted contacts will be notified'),
        findsOneWidget,
      );
    });

    testWidgets('a stage with nobody to name that is due is said plainly', (
      tester,
    ) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 10, 14, 40))
        ..incidents.open(
          incidentJson(
            status: 'escalating',
            requires: 'safe',
            contactsMessaged: true,
            timeline: [
              {...reminderJson('missed', anchor), 'variant': 'someday'},
              stageJson(
                1,
                graceEnds,
                status: 'executed',
                contacts: [contactJson(momId, 'Mom', result: 'messaged')],
              ),
              stageJson(2, DateTime.utc(2026, 10, 10, 14, 30, 1)),
            ],
          ),
        );
      await _open(tester, fakes);
      expect(find.textContaining('The next step is due.'), findsOneWidget);
      expect(find.text('Reminder to you'), findsOneWidget);
    });

    testWidgets('a stage that is due but has not run, without a time in the '
        'past', (tester) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 10, 14, 40))
        ..incidents.open(escalatedJson());
      await _open(tester, fakes);
      expect(
        find.textContaining(
          'Next, Brother will be notified, and 1 instruction will be shared '
          'with them.',
        ),
        findsOneWidget,
      );
    });
  });

  group('which action stops it', () {
    testWidgets('requires "safe" replaces I\'M OK with I\'M SAFE even while '
        'the status says grace', (tester) async {
      final fakes = _world()
        ..incidents.open(
          incidentJson(requires: 'safe', contactsMessaged: true),
        );
      await _open(tester, fakes);
      expect(find.text("I'M SAFE"), findsOneWidget);
      expect(find.byType(CheckInButton), findsNothing);
    });

    testWidgets('a `requires` this version does not know follows '
        'contacts_messaged', (tester) async {
      final told = _world()
        ..incidents.open(
          incidentJson(requires: 'review', contactsMessaged: true),
        );
      await _open(tester, told);
      expect(find.text("I'M SAFE"), findsOneWidget);

      final notTold = _world()
        ..incidents.open(incidentJson(requires: 'review'));
      await _open(tester, notTold);
      expect(find.byType(CheckInButton), findsOneWidget);
      expect(find.text("I'M SAFE"), findsNothing);
    });

    testWidgets('a status this version does not know is neither closed nor '
        'claimed', (tester) async {
      final fakes = _world()..incidents.open(incidentJson(status: 'paused'));
      await _open(tester, fakes);
      expect(find.text('You missed your 8:00 PM check-in'), findsOneWidget);
      expect(find.byType(CheckInButton), findsOneWidget);
    });

    testWidgets('safe_required: Home reads again and shows the I\'M SAFE path, '
        'not an error', (tester) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 9, 17, 36, 20))
        ..incidents.open(incidentJson());
      await _open(tester, fakes);
      expect(find.byType(CheckInButton), findsOneWidget);

      // Contacts are told after Home was read: the tap is refused with safe_required.
      fakes.incidents.open(escalatedJson());
      await tester.tap(find.byType(CheckInButton));
      await tester.pumpAndSettle();

      expect(fakes.server.recorded, 0, reason: 'nothing was recorded');
      expect(find.text('Your contacts have been notified'), findsOneWidget);
      expect(find.text("I'M SAFE"), findsOneWidget);
      expect(find.byType(CheckInButton), findsNothing);
      expect(find.textContaining('went wrong'), findsNothing);
      expect(find.textContaining("didn't go through"), findsNothing);
    });

    testWidgets('safe_required before Home has read the new state still '
        'shows I\'M SAFE', (tester) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 9, 17, 36, 20))
        ..incidents.open(incidentJson());
      fakes.server.contactsMessaged = true;
      // The aggregate keeps saying grace (a moment behind).
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
      );
      fakes.server.failures['home'] = [
        const NetworkFailure(),
        const NetworkFailure(),
      ];
      await container.read(checkInControllerProvider.notifier).checkIn();
      await tester.pumpAndSettle();
      expect(find.text("I'M SAFE"), findsOneWidget);
      expect(find.text('Your contacts have been notified'), findsOneWidget);
      // What is out of date is not repeated: nobody is named as told or as next.
      expect(find.textContaining('will be notified'), findsNothing);
      expect(
        find.text("If you're safe, tap I'M SAFE to let them know."),
        findsOneWidget,
      );
    });
  });

  group('an incident this version cannot read', () {
    testWidgets('keeps the neutral placeholder and I\'M OK', (tester) async {
      final fakes = _world()..incidents.open({'id': 'i-1'});
      await _open(tester, fakes);
      expect(find.text('Your check-in is overdue'), findsOneWidget);
      expect(find.text("Tap I'M OK if you're all right."), findsOneWidget);
      expect(_button(tester), CheckInButtonState.idle);
      expect(find.text("I'M SAFE"), findsNothing);
    });

    testWidgets('safe_required still leads to I\'M SAFE, with the id in the '
        'aggregate', (tester) async {
      final fakes = _world()..incidents.open({'id': 'i-1', 'status': 'grace'});
      fakes.server.failures['checkIn'] = [
        const ConflictFailure(code: 'safe_required'),
      ];
      await _open(tester, fakes);
      await tester.tap(find.byType(CheckInButton));
      await tester.pumpAndSettle();
      expect(find.text("Please confirm you're safe"), findsOneWidget);
      expect(
        find.text(
          "Your contacts have been notified, so confirming that you're safe "
          'is what stops your plan.',
        ),
        findsOneWidget,
      );
      expect(find.text("I'M SAFE"), findsOneWidget);
      expect(_button(tester), CheckInButtonState.disabled);
    });

    testWidgets('safe_required names the incident when the aggregate cannot', (
      tester,
    ) async {
      final fakes = _world()..incidents.open({'status': 'grace'});
      fakes.server.failures['checkIn'] = [
        const ConflictFailure(
          code: 'safe_required',
          problem: ApiProblem(
            status: 409,
            code: 'safe_required',
            incidentId: 'inc-9',
          ),
        ),
      ];
      await _open(tester, fakes);
      await tester.tap(find.byType(CheckInButton));
      await tester.pumpAndSettle();
      expect(find.text("I'M SAFE"), findsOneWidget);

      // The flow starts with the password.
      await tapText(tester, "I'M SAFE");
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsOneWidget);
    });
  });

  group('the window', () {
    testWidgets('is secure while an instruction\'s title is on screen and '
        'not otherwise', (tester) async {
      final plain = _world(now: DateTime.utc(2026, 10, 9, 17, 36, 20))
        ..incidents.open(escalatedJson());
      await _open(tester, plain);
      expect(plain.secureScreen.calls, isEmpty);

      final titled = _world(now: DateTime.utc(2026, 10, 10, 15))
        ..incidents.open(
          escalatedJson(
            stage2Ran: true,
            releases: [
              releaseJson(
                firstViewedAt: DateTime.utc(2026, 10, 10, 14, 50, 5),
                viewCount: 1,
              ),
            ],
          ),
        );
      await _open(tester, titled);
      expect(titled.secureScreen.secure, isTrue);
    });
  });

  group('time moves on', () {
    testWidgets('Home is read again about once a minute while an incident is '
        'open', (tester) async {
      final fakes = _world()..incidents.open(incidentJson());
      await _open(tester, fakes);
      int homes() => fakes.server.calls.where((c) => c == 'home').length;
      final before = homes();
      await tester.pump(const Duration(seconds: 30));
      expect(homes(), before);
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(homes(), before + 1);
    });

    testWidgets('Home is not read while the app is in the background, and is '
        'read again at once when it returns', (tester) async {
      final fakes = _world()..incidents.open(incidentJson());
      await _open(tester, fakes);
      int homes() => fakes.server.calls.where((c) => c == 'home').length;
      final before = homes();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 30));
      }
      expect(homes(), before, reason: 'a phone in a pocket reads nothing');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(homes(), before + 1);

      // And it keeps its rhythm afterwards.
      await tester.pump(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(homes(), before + 2);
    });

    testWidgets('Home is not read while another tab is on view, and is read '
        'again when it comes back', (tester) async {
      final fakes = _world()..incidents.open(incidentJson());
      await _open(tester, fakes);
      int homes() => fakes.server.calls.where((c) => c == 'home').length;
      Finder tab(String label) => find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      );

      await tester.tap(tab('People'));
      await tester.pumpAndSettle();
      final away = homes();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 30));
      }
      expect(homes(), away, reason: 'nobody is looking at it');

      await tester.tap(tab('Home'));
      await tester.pumpAndSettle();
      expect(homes(), away + 1, reason: 'what it shows may be old');
    });

    testWidgets('a stage whose time arrives is read again at once, once', (
      tester,
    ) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 9, 17, 29, 40))
        ..incidents.open(incidentJson());
      await _open(tester, fakes);
      int homes() => fakes.server.calls.where((c) => c == 'home').length;
      final before = homes();
      fakes.clock.advance(const Duration(seconds: 40));
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(homes(), before + 1);
      expect(
        find.text('Mom will be notified unless you check in.'),
        findsOneWidget,
      );
    });
  });

  group('screen readers', () {
    testWidgets('each line of the timeline is one sentence', (tester) async {
      final handle = tester.ensureSemantics();
      final fakes = _world(now: DateTime.utc(2026, 10, 10, 15))
        ..incidents.open(
          escalatedJson(
            stage2Ran: true,
            releases: [
              releaseJson(
                firstViewedAt: DateTime.utc(2026, 10, 10, 14, 50, 5),
                viewCount: 1,
              ),
            ],
          ),
        );
      await _open(tester, fakes);
      expect(
        find.bySemanticsLabel(
          'Today · 8:20 PM. Brother viewed “House emergency”',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Today · 8:00 PM. Brother was notified. Done. 1 instruction shared',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('I\'M SAFE is one button with a label and a hint', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final fakes = _world(now: DateTime.utc(2026, 10, 9, 17, 36, 20))
        ..incidents.open(escalatedJson());
      await _open(tester, fakes);
      final node = tester.getSemantics(find.bySemanticsLabel("I'M SAFE").first);
      expect(node.label, "I'M SAFE");
      expect(
        node.hint,
        "Tells the people who were notified that you're safe and stops the "
        'rest of the plan.',
      );
      expect(node.flagsCollection.isButton, isTrue);
      handle.dispose();
    });
  });

  group('large text', () {
    for (final (name, size) in const {
      'Galaxy 360x780': Size(360, 780),
      'small 320x690': Size(320, 690),
    }.entries.map((e) => (e.key, e.value))) {
      testWidgets('Grace and escalated fit at 2.0 on $name', (tester) async {
        final grace = _world()..incidents.open(incidentJson());
        await openApp(
          tester,
          fakes: grace,
          route: AppRoutes.home,
          size: size,
          textScale: 2,
          roboto: true,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('You missed your 8:00 PM check-in'), findsOneWidget);

        final told = _world(now: DateTime.utc(2026, 10, 10, 15))
          ..incidents.open(
            escalatedJson(
              stage2Ran: true,
              releases: [
                releaseJson(
                  firstViewedAt: DateTime.utc(2026, 10, 10, 14, 50, 5),
                  viewCount: 1,
                ),
              ],
            ),
          );
        await openApp(
          tester,
          fakes: told,
          route: AppRoutes.home,
          size: size,
          textScale: 2,
          roboto: true,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Your contacts have been notified'), findsOneWidget);
      });
    }
  });
}
