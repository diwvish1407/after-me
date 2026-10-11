import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/features/home/data/models/home_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/fake_activity_server.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/real_fonts.dart';
import '../../helpers/test_app.dart';

/// Settings > Activity (USER_FLOWS.md §11) and the short list on Home. The test clock is
/// 2026-10-08T12:00Z, which is 5:30 PM on 8 October in Asia/Kolkata (the profile's zone).
const _offline =
    "You're offline or the connection dropped. Check your connection and try "
    'again.';

TestFakes _world() => TestFakes();

void main() {
  setUpAll(loadRoboto);

  testWidgets('Settings has the entry, and it opens the feed', (tester) async {
    final fakes = _world();
    fakes.activity.items = [activityItem('checkin.recorded')];
    await openApp(tester, fakes: fakes, route: AppRoutes.settings);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('What happened on your account'), findsOneWidget);
    await tapText(tester, 'Activity');
    await tester.pumpAndSettle();
    expect(find.text('You checked in'), findsOneWidget);
  });

  testWidgets('nothing yet: a calm empty state', (tester) async {
    await openApp(tester, fakes: _world(), route: AppRoutes.settingsActivity);
    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.textContaining('who viewed what you shared'), findsOneWidget);
  });

  testWidgets('entries are composed from action and params and grouped by '
      'day in the profile timezone', (tester) async {
    final fakes = _world();
    fakes.activity.items = [
      activityItem(
        'release.viewed',
        id: 5,
        at: DateTime.utc(2026, 10, 8, 9),
        params: {
          'contact_display_name': 'Brother',
          'instruction_titles': ['House emergency'],
        },
      ),
      activityItem(
        'checkin.recorded',
        id: 4,
        at: DateTime.utc(2026, 10, 8, 3),
        params: {'kind': 'ok', 'source': 'app'},
      ),
      activityItem(
        'contact.accepted',
        id: 3,
        at: DateTime.utc(2026, 10, 7, 12),
        params: {'contact_display_name': 'Mom'},
      ),
      activityItem(
        'auth.logout_all',
        id: 2,
        at: DateTime.utc(2026, 10, 5, 12),
        params: {'sessions_revoked': 2},
      ),
    ];
    await openApp(tester, fakes: fakes, route: AppRoutes.settingsActivity);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Monday, October 5, 2026'), findsOneWidget);
    expect(find.text('Brother viewed "House emergency"'), findsOneWidget);
    expect(find.text('You checked in'), findsOneWidget);
    expect(find.text('Mom accepted your invitation'), findsOneWidget);
    expect(find.text('You signed out everywhere'), findsOneWidget);
    expect(find.text('2 sessions ended'), findsOneWidget);
    // 09:00Z is 2:30 PM in Kolkata, 03:00Z is 8:30 AM: never the phone's zone.
    expect(find.text('2:30 PM'), findsOneWidget);
    expect(find.text('8:30 AM'), findsOneWidget);
    // Today's two entries are under one heading, newest first.
    final order = [
      for (final text in [
        'Today',
        'Brother viewed "House emergency"',
        'You checked in',
        'Yesterday',
        'Mom accepted your invitation',
      ])
        tester.getTopLeft(find.text(text)).dy,
    ];
    expect(order, orderedEquals([...order]..sort()));
  });

  testWidgets('an action this version does not know is shown generically, a '
      'null name or title never breaks a line', (tester) async {
    final fakes = _world();
    fakes.activity.items = [
      activityItem('billing.v9.brand_new', id: 3, params: {'x': 1}),
      activityItem(
        'instruction.recipients_changed',
        id: 2,
        params: {'instruction_title': null, 'added': 1, 'removed': 0},
      ),
      activityItem(
        'release.viewed',
        id: 1,
        params: {
          'contact_display_name': null,
          'instruction_titles': <String>[],
        },
      ),
    ];
    await openApp(tester, fakes: fakes, route: AppRoutes.settingsActivity);
    expect(find.text('Something changed on your account'), findsOneWidget);
    expect(
      find.text('The people who receive one of your instructions were changed'),
      findsOneWidget,
    );
    expect(find.text('1 person added'), findsOneWidget);
    expect(
      find.text('A trusted contact viewed what you shared'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  group('pages', () {
    testWidgets('Show more follows the server\'s cursor', (tester) async {
      final fakes = _world();
      fakes.activity.items = [
        for (var i = 25; i >= 1; i--)
          activityItem(
            'schedule.updated',
            id: i,
            at: DateTime.utc(
              2026,
              10,
              8,
              9,
            ).subtract(Duration(minutes: 25 - i)),
          ),
      ];
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsActivity);
      expect(fakes.activity.calls.single.limit, 20);
      expect(fakes.activity.calls.single.cursor, isNull);
      await tester.scrollUntilVisible(
        find.text('Show more'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Show more'));
      await tester.pumpAndSettle();
      expect(fakes.activity.calls.last.cursor, 'cursor-20');
      expect(find.text('Show more'), findsNothing);
      expect(
        find.text('Your check-in schedule was updated'),
        findsNWidgets(25),
      );
    });

    testWidgets('a page that fails keeps the list and says so', (tester) async {
      final fakes = _world();
      fakes.activity.items = [
        for (var i = 25; i >= 1; i--) activityItem('plan.updated', id: i),
      ];
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsActivity);
      fakes.activity.failures.add(const NetworkFailure());
      await tester.scrollUntilVisible(
        find.text('Show more'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Show more'));
      await tester.pumpAndSettle();
      expect(find.text(_offline), findsOneWidget);
      expect(find.text('Show more'), findsOneWidget);
      expect(find.text('Your plan was updated'), findsNWidgets(20));
    });

    testWidgets('a cursor the server no longer accepts starts the feed again '
        'from the newest entry', (tester) async {
      final fakes = _world();
      fakes.activity.items = [
        for (var i = 25; i >= 1; i--) activityItem('plan.updated', id: i),
      ];
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsActivity);
      fakes.activity.issuedCursors.clear();
      await tester.scrollUntilVisible(
        find.text('Show more'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Show more'));
      await tester.pumpAndSettle();
      expect(fakes.activity.calls.last.cursor, isNull);
      expect(find.text('Your plan was updated'), findsNWidgets(20));
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a feed that cannot be loaded offers to try again', (
      tester,
    ) async {
      final fakes = _world();
      fakes.activity.items = [activityItem('checkin.recorded')];
      fakes.activity.failures.add(const NetworkFailure());
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsActivity);
      expect(find.text(_offline), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.text('You checked in'), findsOneWidget);
    });
  });

  group('offline', () {
    Future<void> pull(WidgetTester tester) async {
      await tester.fling(
        find.byType(Scrollable).first,
        const Offset(0, 400),
        800,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a refresh that fails keeps the last list and says it is the '
        'last information we have; the next one that works removes the note', (
      tester,
    ) async {
      final fakes = _world();
      fakes.activity.items = [activityItem('checkin.recorded', id: 1)];
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsActivity);
      expect(find.textContaining('last information we have'), findsNothing);
      fakes.activity.failures.add(const NetworkFailure());
      await pull(tester);
      expect(find.text('You checked in'), findsOneWidget);
      expect(
        find.textContaining('Showing the last information we have'),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsOneWidget);
      fakes.activity.items = [
        activityItem('plan.updated', id: 2),
        activityItem('checkin.recorded', id: 1),
      ];
      await pull(tester);
      expect(find.textContaining('last information we have'), findsNothing);
      expect(find.text('Your plan was updated'), findsOneWidget);
    });
  });

  group('FLAG_SECURE', () {
    testWidgets('is held only while an entry that names an instruction is on '
        'screen', (tester) async {
      final fakes = _world();
      fakes.activity.items = [
        activityItem(
          'release.viewed',
          params: {
            'contact_display_name': 'Brother',
            'instruction_titles': ['House emergency'],
          },
        ),
      ];
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.settings,
      );
      expect(fakes.secureScreen.secure, isFalse);
      container.read(routerProvider).go(AppRoutes.settingsActivity);
      await tester.pumpAndSettle();
      expect(find.text('Brother viewed "House emergency"'), findsOneWidget);
      expect(fakes.secureScreen.secure, isTrue);
      container.read(routerProvider).go(AppRoutes.settings);
      await tester.pumpAndSettle();
      expect(fakes.secureScreen.secure, isFalse);
    });

    testWidgets('is not held for entries without a title', (tester) async {
      final fakes = _world();
      fakes.activity.items = [
        activityItem('checkin.recorded', id: 3),
        activityItem(
          'release.viewed',
          id: 2,
          params: {'contact_display_name': 'Brother', 'release_count': 2},
        ),
        activityItem(
          'instruction.recipients_changed',
          id: 1,
          params: {'instruction_title': null},
        ),
      ];
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsActivity);
      expect(find.text('Brother viewed 2 shared instructions'), findsOneWidget);
      expect(fakes.secureScreen.enabledCount, 0);
    });
  });

  group('Home', () {
    void activeHome(TestFakes fakes) {
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      fakes.plan.seedStandard(['c1']);
      fakes.server.activateNow();
    }

    testWidgets('shows the newest three as short lines and the way to all '
        'of it', (tester) async {
      final fakes = _world();
      activeHome(fakes);
      fakes.server.recentActivity = [
        RecentActivity(
          action: 'checkin.recorded',
          occurredAt: DateTime.utc(2026, 10, 8, 9),
        ),
        RecentActivity(
          action: 'release.viewed',
          occurredAt: DateTime.utc(2026, 10, 8, 8),
        ),
        RecentActivity(
          action: 'plan.updated',
          occurredAt: DateTime.utc(2026, 10, 7, 12),
        ),
        RecentActivity(
          action: 'schedule.activated',
          occurredAt: DateTime.utc(2026, 10, 7, 11),
        ),
        RecentActivity(
          action: 'contact.created',
          occurredAt: DateTime.utc(2026, 10, 7, 10),
        ),
      ];
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      await tester.scrollUntilVisible(
        find.text('See all activity'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Recent activity'), findsOneWidget);
      expect(find.text('You checked in'), findsOneWidget);
      // The aggregate carries an action and a time only: no name, no title.
      expect(
        find.text('A trusted contact viewed what you shared'),
        findsOneWidget,
      );
      expect(find.text('Your plan was updated'), findsOneWidget);
      expect(find.text('Check-ins were turned on'), findsNothing);
      expect(find.text('Today · 2:30 PM'), findsWidgets);
      fakes.activity.items = [activityItem('checkin.recorded')];
      await tester.tap(find.text('See all activity'));
      await tester.pumpAndSettle();
      expect(find.text('Activity'), findsWidgets);
      expect(find.text('Today'), findsOneWidget);
    });

    testWidgets('says nothing while there is nothing to say', (tester) async {
      final fakes = _world();
      activeHome(fakes);
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(find.text('Recent activity'), findsNothing);
      expect(find.text('See all activity'), findsNothing);
    });
  });
}
