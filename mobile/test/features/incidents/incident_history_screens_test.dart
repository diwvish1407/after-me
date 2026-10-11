import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/incident_fixtures.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/real_fonts.dart';
import '../../helpers/test_app.dart';

/// Settings > Past incidents (USER_FLOWS.md §10, §11): the list, how each one ended, and
/// one incident in full. The test clock is 2026-10-12T12:00Z (5:30 PM in Asia/Kolkata).
Map<String, dynamic> _closed(
  int n, {
  String closedBy = 'user_checkin',
  bool messaged = false,
  List<Map<String, dynamic>>? timeline,
  List<Map<String, dynamic>> releases = const [],
}) {
  final due = DateTime.utc(2026, 10, 10, 14, 30).subtract(Duration(days: n));
  final id = '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
  return {
    ...incidentJson(
      id: id,
      status: switch (closedBy) {
        'user_checkin' => 'resolved',
        'user_safe' => 'cancelled',
        'operator_void' => 'voided',
        _ => 'resolved',
      },
      requires: null,
      contactsMessaged: messaged,
      closedAt: due.add(const Duration(minutes: 20)),
      closedBy: closedBy,
      timeline: timeline,
      releases: releases,
    ),
    'missed_due_at': iso(due),
    'anchor_at': iso(due.add(const Duration(seconds: 1))),
    'grace_ends_at': iso(due.add(const Duration(hours: 3))),
  };
}

TestFakes _world() {
  final fakes = TestFakes();
  fakes.clock.current = DateTime.utc(2026, 10, 12, 12);
  return fakes;
}

void main() {
  setUpAll(loadRoboto);

  testWidgets('Settings has the entry, and it opens the list', (tester) async {
    final fakes = _world()..incidents.addClosed(_closed(1));
    await openApp(tester, fakes: fakes, route: AppRoutes.settings);
    expect(find.text('Past incidents'), findsOneWidget);
    expect(find.text('Missed check-ins and how they ended'), findsOneWidget);
    await tapText(tester, 'Past incidents');
    await tester.pumpAndSettle();
    expect(find.textContaining('Missed check-in on'), findsOneWidget);
  });

  testWidgets('nothing yet: a calm empty state', (tester) async {
    final fakes = _world();
    await openApp(tester, fakes: fakes, route: AppRoutes.settingsIncidents);
    expect(find.text('No missed check-ins'), findsOneWidget);
    expect(
      find.text(
        'If you ever miss a check-in, what happened will be kept here.',
      ),
      findsOneWidget,
    );
  });

  group('how each one ended', () {
    testWidgets('every way an incident closes has calm words', (tester) async {
      final fakes = _world()
        ..incidents.addClosed(_closed(1))
        ..incidents.addClosed(_closed(2, closedBy: 'user_safe', messaged: true))
        ..incidents.addClosed(_closed(3, closedBy: 'user_safe'))
        ..incidents.addClosed(_closed(4, closedBy: 'account_deleted'))
        ..incidents.addClosed(_closed(5, closedBy: 'operator_void'))
        ..incidents.addClosed({
          ..._closed(6, closedBy: 'from_the_future'),
          'status': 'brand_new',
        });
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsIncidents);
      for (final text in [
        'You checked in. No one was contacted.',
        'You confirmed you were safe. An all-clear message was queued for your '
            'contacts.',
        'You confirmed you were safe. No one had been contacted.',
        'Closed when your account was deleted.',
        'Closed by AfterMe after an interruption on our side.',
        'Closed.',
      ]) {
        await tester.scrollUntilVisible(
          find.text(text),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(text), findsOneWidget, reason: text);
      }
    });

    testWidgets('an incident that is still open is said to be, and comes '
        'first', (tester) async {
      final fakes = _world()
        ..incidents.addClosed(_closed(2))
        ..incidents.open(incidentJson());
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsIncidents);
      expect(find.text('Still open.'), findsOneWidget);
      final titles = tester
          .widgetList<Text>(find.textContaining('Missed check-in on'))
          .map((t) => t.data!)
          .toList();
      expect(titles, hasLength(2));
      expect(titles.first, contains('Oct 9'));
    });

    testWidgets('the date is the deadline in the profile\'s timezone, and '
        'a row reads as one sentence', (tester) async {
      final handle = tester.ensureSemantics();
      final fakes = _world()..incidents.addClosed(_closed(1));
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsIncidents);
      // 2026-10-09T14:30Z is 8:00 PM in Asia/Kolkata.
      final title = tester
          .widget<Text>(find.textContaining('Missed check-in on'))
          .data!;
      expect(title, contains('Oct 9'));
      expect(title, contains('8:00 PM'));
      expect(
        find.bySemanticsLabel('$title. You checked in. No one was contacted.'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('pages', () {
    testWidgets('Show more loads the next page, newest first', (tester) async {
      final fakes = _world();
      for (var n = 1; n <= 22; n++) {
        fakes.incidents.addClosed(_closed(n));
      }
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsIncidents);
      await tester.scrollUntilVisible(
        find.text('Show more'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Show more'));
      await tester.pumpAndSettle();
      expect(find.text('Show more'), findsNothing);
      await tester.scrollUntilVisible(
        find.textContaining('Sep 18'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('Sep 18'), findsOneWidget);
    });

    testWidgets('a page that fails keeps the list and says so', (tester) async {
      final fakes = _world();
      for (var n = 1; n <= 22; n++) {
        fakes.incidents.addClosed(_closed(n));
      }
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsIncidents);
      fakes.incidents.failures['list'] = [const NetworkFailure()];
      await tester.scrollUntilVisible(
        find.text('Show more'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Show more'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          "You're offline or the connection dropped. Check your connection "
          'and try again.',
        ),
        findsOneWidget,
      );
      expect(find.text('Show more'), findsOneWidget);
    });

    testWidgets('a list that cannot be loaded offers to try again', (
      tester,
    ) async {
      final fakes = _world()..incidents.addClosed(_closed(1));
      fakes.incidents.failures['list'] = [const NetworkFailure()];
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsIncidents);
      expect(find.text('Try again'), findsOneWidget);
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.textContaining('Missed check-in on'), findsOneWidget);
    });

    testWidgets('pull to refresh reads the first page again', (tester) async {
      final fakes = _world()..incidents.addClosed(_closed(1));
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsIncidents);
      fakes.incidents.addClosed(_closed(2));
      await tester.fling(
        find.byType(Scrollable).first,
        const Offset(0, 400),
        800,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Missed check-in on'), findsNWidgets(2));
    });

    testWidgets('a pull to refresh that fails says so and keeps the list', (
      tester,
    ) async {
      final fakes = _world()..incidents.addClosed(_closed(1));
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsIncidents);
      fakes.incidents.failures['list'] = [const NetworkFailure()];
      await tester.fling(
        find.byType(Scrollable).first,
        const Offset(0, 400),
        800,
      );
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('Missed check-in on'), findsOneWidget);
    });
  });

  group('one incident', () {
    testWidgets('how it ended, what happened, and what was shared and seen', (
      tester,
    ) async {
      final fakes = _world();
      final id = '00000000-0000-4000-8000-000000000001';
      final closedAt = DateTime.utc(2026, 10, 9, 14, 50);
      fakes.incidents.addClosed(
        _closed(
          1,
          closedBy: 'user_safe',
          messaged: true,
          timeline: [
            reminderJson('missed', DateTime.utc(2026, 10, 9, 14, 30, 1)),
            stageJson(
              1,
              DateTime.utc(2026, 10, 9, 14, 40, 1),
              status: 'executed',
              contacts: [contactJson(momId, 'Mom', result: 'messaged')],
              releaseCount: 1,
            ),
            stageJson(
              2,
              DateTime.utc(2026, 10, 10, 14, 30, 1),
              status: 'cancelled',
              contacts: [contactJson(brotherId, 'Brother')],
            ),
          ],
          releases: [
            releaseJson(
              contactId: momId,
              contactName: 'Mom',
              position: 1,
              releasedAt: DateTime.utc(2026, 10, 9, 14, 40, 1),
              firstViewedAt: DateTime.utc(2026, 10, 9, 14, 45),
              lastViewedAt: DateTime.utc(2026, 10, 9, 14, 45),
              viewCount: 1,
              revokedAt: closedAt,
              revokeReason: 'user_safe',
            ),
          ],
        ),
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.incidentDetail(id));

      expect(find.text('Missed check-in'), findsOneWidget);
      // Under the heading, and again as the closing line of the timeline.
      expect(
        find.text(
          'You confirmed you were safe. An all-clear message was queued for your '
          'contacts.',
        ),
        findsNWidgets(2),
      );
      expect(find.textContaining('Closed '), findsOneWidget);
      expect(find.text('What happened'), findsOneWidget);
      expect(find.text('Mom was notified'), findsOneWidget);
      expect(find.text('Mom viewed “House emergency”'), findsOneWidget);
      expect(
        find.text('“House emergency” is no longer available to Mom'),
        findsOneWidget,
      );
      expect(find.text('You confirmed you were safe.'), findsWidgets);
      // The part that never ran.
      expect(find.text('Brother was due to be notified'), findsOneWidget);
      expect(find.text('Stopped before it ran'), findsOneWidget);
      // The history entry names what the incident shared, for its owner.
      await tester.scrollUntilVisible(
        find.text('What was shared'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('House emergency'), findsOneWidget);
      expect(fakes.secureScreen.secure, isTrue);
    });

    testWidgets('another incident in the same place never shows the first '
        'one\'s names', (tester) async {
      final fakes = _world()
        ..incidents.addClosed(
          _closed(
            1,
            timeline: [
              stageJson(
                1,
                DateTime.utc(2026, 10, 9, 14, 40, 1),
                status: 'executed',
                contacts: [contactJson(momId, 'Mom', result: 'messaged')],
              ),
            ],
          ),
        )
        ..incidents.addClosed(
          _closed(
            2,
            timeline: [
              stageJson(
                1,
                DateTime.utc(2026, 10, 8, 14, 40, 1),
                status: 'executed',
                contacts: [
                  contactJson(brotherId, 'Brother', result: 'messaged'),
                ],
              ),
            ],
          ),
        );
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.incidentDetail('00000000-0000-4000-8000-000000000001'),
      );
      expect(find.text('Mom was notified'), findsOneWidget);
      container
          .read(routerProvider)
          .go(AppRoutes.incidentDetail('00000000-0000-4000-8000-000000000002'));
      await tester.pumpAndSettle();
      expect(find.text('Brother was notified'), findsOneWidget);
      expect(find.text('Mom was notified'), findsNothing);
    });

    testWidgets('a row opens its incident and back returns to the list', (
      tester,
    ) async {
      final fakes = _world()..incidents.addClosed(_closed(1));
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsIncidents);
      await tester.tap(find.textContaining('Missed check-in on'));
      await tester.pumpAndSettle();
      expect(find.text('Missed check-in'), findsOneWidget);
      expect(find.text('What happened'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.textContaining('Missed check-in on'), findsOneWidget);
    });

    testWidgets('an incident that is not the person\'s is simply not '
        'found', (tester) async {
      final fakes = _world();
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.incidentDetail('00000000-0000-4000-8000-0000000000aa'),
      );
      expect(
        find.text("We couldn't find that. It may have been removed."),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('one that cannot be loaded can be tried again', (tester) async {
      final fakes = _world()..incidents.addClosed(_closed(1));
      fakes.incidents.failures['get'] = [const NetworkFailure()];
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.incidentDetail('00000000-0000-4000-8000-000000000001'),
      );
      expect(find.text('Try again'), findsOneWidget);
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.text('What happened'), findsOneWidget);
    });

    testWidgets('without a title on screen the window is not secured', (
      tester,
    ) async {
      final fakes = _world()..incidents.addClosed(_closed(1));
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.incidentDetail('00000000-0000-4000-8000-000000000001'),
      );
      expect(fakes.secureScreen.calls, isEmpty);
    });
  });

  group('routes', () {
    test('a path with an incident id is an incident page, nothing else is', () {
      expect(
        AppRoutes.isIncidentRoute(
          AppRoutes.incidentDetail('00000000-0000-4000-8000-000000000001'),
        ),
        isTrue,
      );
      expect(AppRoutes.isIncidentRoute('/settings/incidents'), isFalse);
      expect(AppRoutes.isIncidentRoute('/settings/incidents/a/b'), isFalse);
      expect(AppRoutes.isIncidentRoute('/settings/incidents/a b'), isFalse);
      expect(AppRoutes.isIncidentRoute('/people/abc'), isFalse);
    });
  });

  group('large text', () {
    testWidgets('the list and an incident fit at 2.0', (tester) async {
      final fakes = _world()
        ..incidents.addClosed(_closed(1, closedBy: 'user_safe', messaged: true))
        ..incidents.addClosed(_closed(2, closedBy: 'operator_void'));
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.settingsIncidents,
        size: const Size(320, 690),
        textScale: 2,
        roboto: true,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.textContaining('Missed check-in on').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Missed check-in'), findsOneWidget);
    });
  });
}
