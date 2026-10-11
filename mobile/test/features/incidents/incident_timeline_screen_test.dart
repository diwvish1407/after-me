import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/features/checkin/application/pending_checkin_store.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/incident_fixtures.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/real_fonts.dart';
import '../../helpers/test_app.dart';

/// The incident timeline screen (USER_FLOWS.md §4): the whole story, from Home.
///
/// The test clock is 2026-10-10T15:00Z unless a test moves it: 8:30 PM in Asia/Kolkata.
TestFakes _world({DateTime? now}) {
  final fakes = TestFakes();
  fakes.clock.current = now ?? DateTime.utc(2026, 10, 10, 15);
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

void main() {
  setUpAll(loadRoboto);

  testWidgets('"See the full timeline" opens it from Home and back returns', (
    tester,
  ) async {
    final fakes = _world(now: DateTime.utc(2026, 10, 9, 17, 36, 20))
      ..incidents.open(escalatedJson());
    await openApp(tester, fakes: fakes, route: AppRoutes.home);
    await tapText(tester, 'See the full timeline');
    await tester.pumpAndSettle();

    expect(find.text('Timeline'), findsOneWidget);
    expect(find.text('Your contacts have been notified'), findsOneWidget);
    expect(find.text("I'M SAFE"), findsOneWidget);
    expect(find.text('What has happened and what comes next'), findsOneWidget);
    expect(find.text('What was shared'), findsOneWidget);
    expect(find.text('No instructions have been shared.'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Your contacts have been notified'), findsOneWidget);
    expect(find.text('See the full timeline'), findsOneWidget);
  });

  testWidgets('a stage that is to share something says how many, never what', (
    tester,
  ) async {
    final fakes = _world(now: DateTime.utc(2026, 10, 9, 17, 36, 20))
      ..incidents.open(escalatedJson());
    await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
    expect(find.text('1 instruction to be shared'), findsOneWidget);
    expect(find.text('Brother will be notified'), findsOneWidget);
    expect(find.textContaining('House emergency'), findsNothing);
    expect(fakes.secureScreen.calls, isEmpty);
  });

  group('what was shared', () {
    testWidgets('each record: with whom, when, and what became of it', (
      tester,
    ) async {
      final fakes = _world()
        ..incidents.open(
          escalatedJson(
            stage2Ran: true,
            releases: [
              releaseJson(
                firstViewedAt: DateTime.utc(2026, 10, 10, 14, 50, 5),
                lastViewedAt: DateTime.utc(2026, 10, 10, 14, 55),
                viewCount: 3,
              ),
              releaseJson(
                contactId: momId,
                contactName: 'Mom',
                instructionId: '00000000-0000-4000-8000-000000000021',
                title: 'Spare keys',
              ),
              releaseJson(
                contactId: brotherId,
                contactName: 'Brother',
                instructionId: '00000000-0000-4000-8000-000000000022',
                title: null,
                revokedAt: DateTime.utc(2026, 10, 10, 14, 58),
                revokeReason: 'hold_rollback',
              ),
            ],
          ),
        );
      await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
      await tester.scrollUntilVisible(
        find.text('What was shared'),
        200,
        scrollable: find.byType(Scrollable).first,
      );

      expect(find.text('House emergency'), findsOneWidget);
      expect(find.text('Shared with Brother'), findsNWidgets(2));
      expect(find.text('Shared Today · 8:00 PM'), findsNWidgets(3));
      expect(
        find.text('Viewed 3 times, most recently Today · 8:25 PM'),
        findsOneWidget,
      );
      expect(find.text('Spare keys'), findsOneWidget);
      expect(find.text('Shared with Mom'), findsOneWidget);
      expect(find.text('Not viewed yet'), findsNWidgets(2));
      // No title: never blank, never a guess.
      expect(find.text('An instruction'), findsOneWidget);
      expect(
        find.text('No longer available since Today · 8:28 PM'),
        findsOneWidget,
      );
      // In the timeline and in the record of what was shared.
      expect(
        find.text('It was withdrawn after an interruption on our side.'),
        findsNWidgets(2),
      );
      expect(fakes.secureScreen.secure, isTrue, reason: 'titles are shown');
    });

    testWidgets('the wording of every reason a release is taken back', (
      tester,
    ) async {
      const reasons = {
        'user_checkin': 'You checked in.',
        'user_safe': 'You confirmed you were safe.',
        'operator': 'It was taken back by AfterMe.',
        'contact_removed': 'They were removed from your plan.',
        'contact_opted_out': 'They asked not to be contacted.',
        'instruction_removed':
            'You switched the instruction off or deleted it.',
        'recipient_removed': 'You stopped sharing it with them.',
        'hold_rollback': 'It was withdrawn after an interruption on our side.',
        'something_new': 'It is no longer available.',
      };
      for (final MapEntry(key: code, value: words) in reasons.entries) {
        final fakes = _world()
          ..incidents.open(
            escalatedJson(
              stage2Ran: true,
              releases: [
                releaseJson(
                  revokedAt: DateTime.utc(2026, 10, 10, 14, 58),
                  revokeReason: code,
                ),
              ],
            ),
          );
        await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
        expect(find.text(words), findsWidgets, reason: code);
      }
    });
  });

  group('the lines of the timeline', () {
    testWidgets('a stage that was stopped, one on hold and one the app has no '
        'word for', (tester) async {
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
                contacts: [contactJson(momId, 'Mom', result: 'messaged')],
              ),
              stageJson(
                2,
                DateTime.utc(2026, 10, 10, 14, 30, 1),
                status: 'cancelled',
                contacts: [contactJson(brotherId, 'Brother')],
              ),
              stageJson(
                3,
                DateTime.utc(2026, 10, 11, 14, 30, 1),
                status: 'snoozed',
                contacts: [contactJson(brotherId, 'Brother')],
              ),
              {
                ...reminderJson('missed', anchor),
                'kind': 'push_nudge',
                'scheduled_for': iso(DateTime.utc(2026, 10, 12, 14)),
              },
              reminderJson(
                'last_chance',
                DateTime.utc(2026, 10, 13, 14),
                status: 'cancelled',
              ),
            ],
          ),
        );
      await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
      expect(find.text('Brother was due to be notified'), findsOneWidget);
      expect(find.text('Stopped before it ran'), findsOneWidget);
      // A stage with a status the app does not know claims nothing; an entry of a
      // kind it does not know is still listed, with the status the server gave.
      expect(find.text('Another step in your plan'), findsNWidgets(2));
      expect(find.text('Status not available'), findsOneWidget);
      expect(find.text('Done'), findsNWidgets(2));
      expect(find.text('Not sent'), findsOneWidget);
    });

    testWidgets('a stage with nobody listed and a stage that told no one', (
      tester,
    ) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 9, 17, 36, 20))
        ..incidents.open(
          incidentJson(
            status: 'escalating',
            requires: 'checkin',
            timeline: [
              stageJson(
                1,
                graceEnds,
                status: 'executed',
                contacts: [contactJson(momId, 'Mom', result: 'skipped')],
              ),
              stageJson(2, DateTime.utc(2026, 10, 10, 14, 30, 1)),
              stageJson(
                3,
                DateTime.utc(2026, 10, 11, 14, 30, 1),
                status: 'cancelled',
              ),
            ],
          ),
        );
      await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
      expect(find.text('The stage ran, but no one was notified'), findsOne);
      expect(find.text('Nothing was sent to Mom.'), findsOneWidget);
      expect(find.text('Your trusted contacts will be notified'), findsOne);
      expect(
        find.text('Your trusted contacts were due to be notified'),
        findsOneWidget,
      );
    });

    testWidgets('the warning without a stage to name', (tester) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 9, 17, 36, 20))
        ..incidents.open(
          incidentJson(
            timeline: [warningJson(2, DateTime.utc(2026, 10, 10, 13, 30, 1))],
          ),
        );
      await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
      expect(
        find.text('Warning to you before something is shared'),
        findsOneWidget,
      );
    });
  });

  group('around the edges', () {
    testWidgets('I\'M OK in the grace period checks in, and the screen then '
        'says nothing is open', (tester) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 9, 14, 30, 21))
        ..incidents.open(incidentJson());
      await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
      expect(find.text('You missed your 8:00 PM check-in'), findsOneWidget);
      expect(find.text('What happens next'), findsOneWidget);
      await tapText(tester, "I'M OK");
      await tester.pumpAndSettle();
      expect(fakes.server.recorded, 1);
      expect(find.text('No missed check-in right now'), findsOneWidget);
      expect(find.text("I'M OK"), findsNothing);
    });

    testWidgets('an I\'M OK that is not received is said', (tester) async {
      final fakes = _world(now: DateTime.utc(2026, 10, 9, 14, 30, 21))
        ..incidents.open(incidentJson());
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
      await tapText(tester, "I'M OK");
      await tester.pumpAndSettle();
      expect(find.text("Not received yet — we'll keep trying"), findsOneWidget);
      expect(find.text('You missed your 8:00 PM check-in'), findsOneWidget);
      // Trying again goes through with the same key.
      await tapText(tester, "I'M OK");
      await tester.pumpAndSettle();
      expect(fakes.server.checkInKeys, ['key-1', 'key-1']);
      expect(find.text('No missed check-in right now'), findsOneWidget);
    });

    testWidgets('nothing open: calm, with a way to the history', (
      tester,
    ) async {
      final fakes = _world();
      await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
      expect(find.text('No missed check-in right now'), findsOneWidget);
      await tapText(tester, 'Past incidents');
      await tester.pumpAndSettle();
      expect(find.text('No missed check-ins'), findsOneWidget);
    });

    testWidgets('an incident this version cannot read is said plainly', (
      tester,
    ) async {
      final fakes = _world()..incidents.open({'id': 'i-1'});
      await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
      expect(find.text('Your check-in is overdue'), findsOneWidget);
      expect(find.text('What was shared'), findsNothing);
    });

    testWidgets('Home that cannot be read says so and can be tried again', (
      tester,
    ) async {
      final fakes = _world()..incidents.open(incidentJson());
      fakes.server.failures['home'] = [
        const NetworkFailure(),
        const NetworkFailure(),
      ];
      await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
      expect(find.text('Try again'), findsOneWidget);
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsNothing);
      expect(find.text('What happens next'), findsOneWidget);
    });

    testWidgets('pull to refresh reads Home again', (tester) async {
      final fakes = _world()..incidents.open(incidentJson());
      await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
      int homes() => fakes.server.calls.where((c) => c == 'home').length;
      final before = homes();
      await tester.fling(
        find.byType(Scrollable).first,
        const Offset(0, 400),
        800,
      );
      await tester.pumpAndSettle();
      expect(homes(), greaterThan(before));
    });

    testWidgets('offline: the last known status is kept and said', (
      tester,
    ) async {
      final fakes = _world()..incidents.open(incidentJson());
      await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
      fakes.server.failures['home'] = [const NetworkFailure()];
      await tester.fling(
        find.byType(Scrollable).first,
        const Offset(0, 400),
        800,
      );
      await tester.pumpAndSettle();
      expect(find.text('Offline — showing last known status'), findsOneWidget);
      expect(find.text('You missed your 8:00 PM check-in'), findsOneWidget);
    });
  });

  group('I\'M OK that is not recorded says so here as well as on Home', () {
    // The timeline screen offers I'M OK while nobody has been told. A tap that was
    // refused or too old to count used to say nothing there: the button just sat idle.
    testWidgets('a refused tap says it did not go through', (tester) async {
      final fakes = _world()..incidents.open(incidentJson());
      fakes.server.failures['checkIn'] = [
        const ValidationFailure(code: 'validation_failed'),
      ];
      await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
      await tester.tap(find.text("I'M OK"));
      await tester.pumpAndSettle();

      expect(find.text("That check-in didn't go through"), findsOneWidget);
      expect(find.text('Some details need another look.'), findsOneWidget);
      expect(
        find.text("I'M OK"),
        findsOneWidget,
        reason: 'it can be tapped again',
      );
      expect(fakes.server.recorded, 0);
    });

    testWidgets('a rate limit says when it will be sent again', (tester) async {
      final fakes = _world()..incidents.open(incidentJson());
      fakes.server.failures['checkIn'] = [
        const RateLimitedFailure(retryAfter: Duration(minutes: 10)),
      ];
      await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
      await tester.tap(find.text("I'M OK"));
      await tester.pumpAndSettle();

      expect(find.text("Not received yet — we'll keep trying"), findsOneWidget);
      expect(
        find.textContaining("We'll send your check-in again in"),
        findsOneWidget,
      );
    });

    testWidgets('a tap that was too old to count is said, and can be '
        'dismissed', (tester) async {
      final fakes = _world()..incidents.open(incidentJson());
      // Tapped 30 hours ago and never confirmed.
      await fakes.secure.write(
        PendingCheckInStore.storageKey,
        PendingCheckIn(
          userId: 'user-1',
          idempotencyKey: 'old-key',
          reportedAt: fakes.clock.now().subtract(const Duration(hours: 30)),
        ).encode(),
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);

      expect(
        find.text("Your earlier check-in wasn't received"),
        findsOneWidget,
      );
      expect(fakes.server.checkInKeys, isEmpty, reason: 'it is never sent');
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(find.text("Your earlier check-in wasn't received"), findsNothing);
    });
  });

  group('large text', () {
    testWidgets('fits at 2.0 on a small phone', (tester) async {
      final fakes = _world()
        ..incidents.open(
          escalatedJson(
            stage2Ran: true,
            releases: [
              releaseJson(
                firstViewedAt: DateTime.utc(2026, 10, 10, 14, 50, 5),
                lastViewedAt: DateTime.utc(2026, 10, 10, 14, 55),
                viewCount: 3,
                revokedAt: DateTime.utc(2026, 10, 10, 14, 58),
                revokeReason: 'user_safe',
              ),
            ],
          ),
        );
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.homeIncident,
        size: const Size(320, 690),
        textScale: 2,
        roboto: true,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Timeline'), findsOneWidget);
    });
  });
}
