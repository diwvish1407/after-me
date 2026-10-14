import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/design_system/check_in_button.dart';
import 'package:afterme/core/design_system/status_banner.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/home/application/home_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/home_fixtures.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/incident_fixtures.dart';
import '../../helpers/real_fonts.dart';
import '../../helpers/semantics_audit.dart';
import '../../helpers/test_app.dart';

/// A service interruption (a Hold: nothing is sent to contacts, deadlines are shifted
/// when it ends). `GET /v1/home` says so in `service.interruption`; Home then says it
/// calmly and no sentence names a time at which anybody will be told.
///
/// The test clock is 8:00:21 PM in Asia/Kolkata (2026-10-09T14:30:21Z), the contract's
/// incident: due at 8:00 PM, grace until 11:00 PM, Mom is told then.

const _title = "We're having a service interruption";
const _body =
    'Nothing is sent to your contacts, and your deadlines move later. '
    'You can still check in.';
const _paused = 'Paused during the interruption';

TestFakes _world({DateTime? now, bool interruption = false}) {
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
  fakes.server
    ..activateNow()
    ..serviceInterruption = interruption;
  return fakes;
}

/// Active, nothing open, a deadline tomorrow evening.
TestFakes _activeWorld({bool interruption = false}) =>
    _world(now: DateTime.utc(2026, 10, 9, 6), interruption: interruption);

CheckInButtonState _button(WidgetTester tester) =>
    tester.widget<CheckInButton>(find.byType(CheckInButton)).state;

Future<ProviderContainer> _open(
  WidgetTester tester,
  TestFakes fakes, {
  String route = AppRoutes.home,
}) => openApp(tester, fakes: fakes, route: route);

/// Every `StatusBanner` that carries the interruption title.
Finder get _banner => find.byWidgetPredicate(
  (w) => w is StatusBanner && w.title == _title && w.message == _body,
);

int _homeReads(TestFakes fakes) =>
    fakes.server.calls.where((c) => c == 'home').length;

/// What the person is not given while the interruption is on: the time of the stage.
void _expectNoStageTime(WidgetTester tester) {
  expect(find.textContaining('11:00 PM'), findsNothing);
  expect(find.textContaining('11:45 PM'), findsNothing);
}

void main() {
  setUpAll(loadRoboto);

  group('the state', () {
    testWidgets('is false until Home is read, and for a server that does not '
        'say', (tester) async {
      final fakes = _activeWorld();
      final container = await _open(tester, fakes);
      expect(container.read(serviceInterruptionProvider), isFalse);
      expect(
        container
            .read(homeControllerProvider)
            .value!
            .snapshot
            .service
            .interruption,
        isFalse,
      );
      expect(_banner, findsNothing);
    });

    testWidgets('follows the aggregate: on, then off again', (tester) async {
      final fakes = _activeWorld(interruption: true);
      final container = await _open(tester, fakes);
      expect(container.read(serviceInterruptionProvider), isTrue);

      fakes.server.serviceInterruption = false;
      await container.read(homeControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(container.read(serviceInterruptionProvider), isFalse);
      expect(_banner, findsNothing);

      fakes.server.serviceInterruption = true;
      await container.read(homeControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(container.read(serviceInterruptionProvider), isTrue);
      expect(_banner, findsOneWidget);
    });

    testWidgets('a failed read keeps the last known answer, marked stale', (
      tester,
    ) async {
      final fakes = _activeWorld(interruption: true);
      final container = await _open(tester, fakes);
      fakes.server.failures['home'] = [
        const NetworkFailure(),
        const NetworkFailure(),
        const NetworkFailure(),
      ];
      await container.read(homeControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(container.read(homeControllerProvider).value!.stale, isTrue);
      expect(container.read(serviceInterruptionProvider), isTrue);
      expect(_banner, findsOneWidget);
    });

    test('the Home fixture carries the flag', () {
      expect(homeSnapshot(interruption: true).serviceInterruption, isTrue);
      expect(homeSnapshot().serviceInterruption, isFalse);
    });
  });

  group('the banner on Home', () {
    testWidgets('is calm, says what holds, and leaves I\'M OK alone', (
      tester,
    ) async {
      final fakes = _activeWorld(interruption: true);
      await _open(tester, fakes);

      expect(find.text(_title), findsOneWidget);
      expect(find.text(_body), findsOneWidget);
      expect(
        tester.widget<StatusBanner>(_banner).kind,
        StatusBannerKind.info,
        reason: 'information, not an alarm',
      );
      expect(find.textContaining('!'), findsNothing);
      // Everything else on Home is as it was.
      expect(find.text("You're checked in"), findsOneWidget);
      expect(_button(tester), CheckInButtonState.idle);
      expect(find.text("I'M OK"), findsOneWidget);
      // No new control, no dialog.
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.descendant(of: _banner, matching: find.byType(TextButton)),
        findsNothing,
      );
    });

    testWidgets('is the first thing on the page', (tester) async {
      final fakes = _activeWorld(interruption: true);
      await _open(tester, fakes);
      final banner = tester.getTopLeft(_banner).dy;
      expect(
        banner,
        lessThan(tester.getTopLeft(find.text('Hello, Diwakar')).dy),
      );
      expect(
        banner,
        lessThan(tester.getTopLeft(find.byType(CheckInButton)).dy),
      );
    });

    testWidgets('is not there when the flag is false', (tester) async {
      final fakes = _activeWorld();
      await _open(tester, fakes);
      expect(find.text(_title), findsNothing);
      expect(find.text(_body), findsNothing);
    });

    testWidgets('is not shown while check-ins are off (nothing to move, no '
        'check-in to use)', (tester) async {
      final fakes = TestFakes();
      fakes.server.serviceInterruption = true;
      await _open(tester, fakes);
      expect(find.text("Let's finish your plan"), findsOneWidget);
      expect(find.text(_title), findsNothing);
    });

    testWidgets('is a live region: announced when it appears, with its words', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final fakes = _activeWorld(interruption: true);
      await _open(tester, fakes);
      final live = liveRegionLabels(tester).join('\n');
      expect(live, contains(_title));
      expect(live, contains(_body));
      handle.dispose();
    });

    testWidgets('I\'M OK works: the check-in is recorded and the banner stays '
        'while it lasts', (tester) async {
      final fakes = _activeWorld(interruption: true);
      await _open(tester, fakes);
      await tester.tap(find.byType(CheckInButton));
      await tester.pumpAndSettle();
      expect(fakes.server.recorded, 1);
      expect(find.textContaining('Checked in. Next check-in'), findsOneWidget);
      expect(_banner, findsOneWidget);
    });

    testWidgets('appears when the app comes back to the foreground', (
      tester,
    ) async {
      final fakes = _activeWorld();
      await _open(tester, fakes);
      expect(_banner, findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      fakes.server.serviceInterruption = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(_banner, findsOneWidget);
    });

    testWidgets('appears on pull to refresh', (tester) async {
      final fakes = _activeWorld();
      await _open(tester, fakes);
      fakes.server.serviceInterruption = true;
      await tester.fling(
        find.byType(SingleChildScrollView).first,
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(_banner, findsOneWidget);
    });
  });

  group('picked up by the reading Home does by itself', () {
    testWidgets('an incident is open: a Hold that starts shows within a '
        'minute, and its end does too', (tester) async {
      final fakes = _world()..incidents.open(incidentJson());
      await _open(tester, fakes);
      expect(_banner, findsNothing);
      expect(
        find.text('Mom will be notified at 11:00 PM unless you check in.'),
        findsOneWidget,
      );

      fakes.server.serviceInterruption = true;
      await tester.pump(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(_banner, findsOneWidget);
      expect(
        find.text('Mom will be notified unless you check in. $_paused.'),
        findsOneWidget,
      );
      _expectNoStageTime(tester);

      fakes.server.serviceInterruption = false;
      await tester.pump(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(_banner, findsNothing);
      expect(
        find.text('Mom will be notified at 11:00 PM unless you check in.'),
        findsOneWidget,
        reason: 'the normal text returns',
      );
    });

    testWidgets('the deadline passed and no incident is open yet: Home is read '
        'about once a minute, and the banner shows', (tester) async {
      // Checked in, then a day and a half goes by: the deadline has passed, and a Hold
      // keeps the server from opening an incident.
      final fakes = _activeWorld();
      await _open(tester, fakes);
      fakes.server.serviceInterruption = true;
      fakes.clock.advance(const Duration(days: 2));

      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(find.textContaining('check-in is due'), findsOneWidget);
      expect(_banner, findsOneWidget, reason: 'read when the deadline passed');

      final before = _homeReads(fakes);
      fakes.server.serviceInterruption = false;
      await tester.pump(const Duration(seconds: 30));
      expect(_homeReads(fakes), before);
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(_homeReads(fakes), before + 1);
      expect(_banner, findsNothing, reason: 'the end of the Hold is seen');
    });

    testWidgets('an interruption is on and nothing else is open: Home is read '
        'about once a minute to see its end', (tester) async {
      final fakes = _activeWorld(interruption: true);
      await _open(tester, fakes);
      final before = _homeReads(fakes);
      fakes.server.serviceInterruption = false;

      await tester.pump(const Duration(seconds: 30));
      expect(_homeReads(fakes), before);
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(_homeReads(fakes), before + 1);
      expect(_banner, findsNothing);
    });

    testWidgets('with nothing open and no interruption Home is not read '
        'again by the timer (as before)', (tester) async {
      final fakes = _activeWorld();
      await _open(tester, fakes);
      final before = _homeReads(fakes);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 30));
      }
      expect(_homeReads(fakes), before);
    });
  });

  group(
    'Home, an incident in grace: no time at which contacts will be told',
    () {
      testWidgets('names the contact, without a time', (tester) async {
        final fakes = _world(interruption: true)
          ..incidents.open(incidentJson());
        await _open(tester, fakes);

        expect(find.text('You missed your 8:00 PM check-in'), findsOneWidget);
        expect(
          find.text('Mom will be notified unless you check in. $_paused.'),
          findsOneWidget,
        );
        _expectNoStageTime(tester);
        expect(_banner, findsOneWidget);
        // The way out is still I'M OK, unchanged.
        expect(_button(tester), CheckInButtonState.idle);
        expect(find.text("I'M OK"), findsOneWidget);
        expect(find.text("I'M SAFE"), findsNothing);
      });

      testWidgets('the stage in the timeline says it is paused instead of its '
          'time; the person\'s own reminders keep theirs', (tester) async {
        final fakes = _world(interruption: true)
          ..incidents.open(incidentJson());
        await _open(tester, fakes);

        expect(find.text('What happens next'), findsOneWidget);
        expect(find.text(_paused), findsOneWidget);
        expect(find.text('Mom will be notified'), findsOneWidget);
        expect(find.text('Today · 11:00 PM'), findsNothing);
        // What does not depend on the Hold: reminders to the person go on.
        expect(find.text('Today · 9:30 PM'), findsOneWidget);
        expect(find.text('Today · 10:45 PM'), findsOneWidget);
      });

      testWidgets(
        'the stage\'s time has already passed: still no time, and not '
        '"due" either',
        (tester) async {
          final fakes = _world(
            now: DateTime.utc(2026, 10, 9, 17, 40),
            interruption: true,
          )..incidents.open(incidentJson());
          await _open(tester, fakes);
          expect(
            find.text('Mom will be notified unless you check in. $_paused.'),
            findsOneWidget,
          );
          expect(find.text('Today · 11:00 PM'), findsNothing);
          expect(find.text(_paused), findsOneWidget);
        },
      );

      testWidgets('a stage put back to 11:45 PM shows neither time', (
        tester,
      ) async {
        final fakes = _world(interruption: true)
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
        _expectNoStageTime(tester);
        expect(
          find.text('Mom and Brother will be notified'),
          findsNothing,
          reason: 'only Mom is named',
        );
        expect(
          find.text('Mom will be notified unless you check in. $_paused.'),
          findsOneWidget,
        );
      });

      testWidgets('everybody the stage tells is named, without a time', (
        tester,
      ) async {
        final fakes = _world(interruption: true)
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
            'Mom and Brother will be notified unless you check in. $_paused.',
          ),
          findsOneWidget,
        );
        _expectNoStageTime(tester);
      });

      testWidgets('no stage in the timeline: the generic sentence, without the '
          'end of the grace period', (tester) async {
        final fakes = _world(interruption: true)
          ..incidents.open(
            incidentJson(timeline: [reminderJson('missed', anchor)]),
          );
        await _open(tester, fakes);
        expect(
          find.text(
            'Your trusted contacts will be notified unless you check in. '
            '$_paused.',
          ),
          findsOneWidget,
        );
        _expectNoStageTime(tester);
      });

      testWidgets('a held stage keeps its own wording (it states no time)', (
        tester,
      ) async {
        final fakes = _world(interruption: true)
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
        expect(find.text('Today · 11:00 PM'), findsNothing);
        expect(find.text(_paused), findsOneWidget);
      });

      testWidgets('the original wording is back when the flag is false', (
        tester,
      ) async {
        final fakes = _world()..incidents.open(incidentJson());
        await _open(tester, fakes);
        expect(
          find.text('Mom will be notified at 11:00 PM unless you check in.'),
          findsOneWidget,
        );
        expect(find.text('Today · 11:00 PM'), findsOneWidget);
        expect(find.text(_paused), findsNothing);
        expect(find.textContaining('interruption'), findsNothing);
      });
    },
  );

  group('Home, contacts have been notified', () {
    final afterStageOne = DateTime.utc(2026, 10, 9, 17, 36, 20);

    testWidgets('what happens next is paused, who was told is not changed', (
      tester,
    ) async {
      final fakes = _world(now: afterStageOne, interruption: true)
        ..incidents.open(escalatedJson());
      await _open(tester, fakes);

      expect(find.text('Your contacts have been notified'), findsOneWidget);
      final text = tester
          .widgetList<StatusBanner>(find.byType(StatusBanner))
          .map((b) => b.message)
          .firstWhere((m) => m.contains('Mom was notified'));
      expect(text, contains('Mom was notified at 11:00 PM.'));
      expect(
        text,
        contains(
          'Next, Brother will be notified, and 1 instruction will be shared '
          'with them. $_paused.',
        ),
      );
      expect(text, isNot(contains('tomorrow')));
      expect(text, isNot(contains('8:00 PM')));
      // I'M SAFE is as it was.
      expect(find.text("I'M SAFE"), findsOneWidget);
      expect(_banner, findsOneWidget);
    });

    testWidgets('the timeline pauses the warning and the stage, and keeps what '
        'happened', (tester) async {
      final fakes = _world(now: afterStageOne, interruption: true)
        ..incidents.open(escalatedJson());
      await _open(tester, fakes);

      expect(find.text(_paused), findsNWidgets(2));
      expect(find.text('Tomorrow · 8:00 PM'), findsNothing);
      expect(find.text('Tomorrow · 7:00 PM'), findsNothing);
      // The stage that ran keeps its time.
      expect(find.text('Today · 11:00 PM'), findsOneWidget);
      expect(find.text('Brother will be notified'), findsOneWidget);
      expect(find.text('1 instruction to be shared'), findsOneWidget);
    });

    testWidgets('a stage without a named contact is said to be paused', (
      tester,
    ) async {
      final json = escalatedJson();
      final timeline = (json['timeline'] as List).cast<Map<String, dynamic>>();
      final fakes = _world(now: afterStageOne, interruption: true)
        ..incidents.open({
          ...json,
          'timeline': [
            for (final item in timeline)
              if (item['kind'] == 'execute_stage' &&
                  item['stage_position'] == 2)
                {...item, 'contacts': <Map<String, dynamic>>[]}
              else
                item,
          ],
        });
      await _open(tester, fakes);
      expect(
        find.textContaining('The next step is paused during the interruption.'),
        findsOneWidget,
      );
      expect(find.textContaining('The next step is due'), findsNothing);
    });

    testWidgets('a stage that shares nothing: names, no instruction count', (
      tester,
    ) async {
      final json = escalatedJson();
      final timeline = (json['timeline'] as List).cast<Map<String, dynamic>>();
      final fakes = _world(now: afterStageOne, interruption: true)
        ..incidents.open({
          ...json,
          'timeline': [
            for (final item in timeline)
              if (item['kind'] == 'execute_stage' &&
                  item['stage_position'] == 2)
                {...item, 'release_count': 0}
              else
                item,
          ],
        });
      await _open(tester, fakes);
      expect(
        find.textContaining('Next, Brother will be notified. $_paused.'),
        findsOneWidget,
      );
    });

    testWidgets('a stage whose time has passed is not "due" while paused', (
      tester,
    ) async {
      final fakes = _world(
        now: DateTime.utc(2026, 10, 10, 15),
        interruption: true,
      )..incidents.open(escalatedJson());
      await _open(tester, fakes);
      expect(
        find.textContaining(
          'Next, Brother will be notified, and 1 instruction will be shared '
          'with them. $_paused.',
        ),
        findsOneWidget,
      );
      expect(find.text(_paused), findsNWidgets(2));
    });

    testWidgets('the original wording is back when the flag is false', (
      tester,
    ) async {
      final fakes = _world(now: afterStageOne)..incidents.open(escalatedJson());
      await _open(tester, fakes);
      expect(
        find.textContaining(
          'Next, Brother will be notified tomorrow at 8:00 PM, and 1 '
          'instruction will be shared with them.',
        ),
        findsOneWidget,
      );
      expect(find.text('Tomorrow · 8:00 PM'), findsOneWidget);
      expect(find.text(_paused), findsNothing);
    });
  });

  group('the incident timeline screen', () {
    testWidgets('says it too: the banner, the sentence and the lines', (
      tester,
    ) async {
      final fakes = _world(
        now: DateTime.utc(2026, 10, 9, 17, 36, 20),
        interruption: true,
      )..incidents.open(escalatedJson());
      await _open(tester, fakes, route: AppRoutes.homeIncident);

      expect(_banner, findsOneWidget);
      expect(find.text('Your contacts have been notified'), findsOneWidget);
      expect(find.text(_paused), findsNWidgets(2));
      expect(find.text('Tomorrow · 8:00 PM'), findsNothing);
      expect(find.text("I'M SAFE"), findsOneWidget);
      final message = tester
          .widgetList<StatusBanner>(find.byType(StatusBanner))
          .map((b) => b.message)
          .firstWhere((m) => m.contains('Mom was notified'));
      expect(message, isNot(contains('tomorrow')));
      expect(message, contains(_paused));
    });

    testWidgets('grace: the sentence and the stage are time-free, and I\'M OK '
        'is there', (tester) async {
      final fakes = _world(interruption: true)..incidents.open(incidentJson());
      await _open(tester, fakes, route: AppRoutes.homeIncident);
      expect(_banner, findsOneWidget);
      expect(
        find.text('Mom will be notified unless you check in. $_paused.'),
        findsOneWidget,
      );
      expect(find.text('Today · 11:00 PM'), findsNothing);
      expect(find.text("I'M OK"), findsOneWidget);
    });

    testWidgets('the original wording and times are back when the flag is '
        'false', (tester) async {
      final fakes = _world()..incidents.open(incidentJson());
      await _open(tester, fakes, route: AppRoutes.homeIncident);
      expect(_banner, findsNothing);
      expect(
        find.text('Mom will be notified at 11:00 PM unless you check in.'),
        findsOneWidget,
      );
      expect(find.text('Today · 11:00 PM'), findsOneWidget);
    });

    testWidgets('an incident opened from the history says paused too', (
      tester,
    ) async {
      final fakes = _world(interruption: true)..incidents.open(incidentJson());
      await _open(tester, fakes, route: AppRoutes.incidentDetail(incidentId));
      expect(find.text(_paused), findsOneWidget);
      expect(find.text('Today · 11:00 PM'), findsNothing);
    });
  });
}
