import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/core/time/foreground_ticker.dart';
import 'package:afterme/features/checkin/application/checkin_controller.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/contacts_harness.dart';
import '../helpers/in_memory_contacts_repository.dart';
import '../helpers/incident_fixtures.dart';
import '../helpers/pump_app.dart';
import '../helpers/test_app.dart';
import '../helpers/timer_tracker.dart';

/// Battery (TEST_PLAN PERF-05): the app does no background work. Every periodic timer in
/// `lib/` is listed here, with a test that it is alive only while the app is in the
/// foreground (and, for Home, while its tab is on view):
///
/// | timer                              | where                                  | period |
/// |------------------------------------|----------------------------------------|--------|
/// | Home ticker (redraw + polls)       | home_screen.dart                       | 30 s   |
/// | incident timeline redraw           | incident_timeline_screen.dart          | 30 s   |
/// | resend-code countdown              | resend_countdown.dart                  | 1 s    |
/// | (both of the last two)             | core/time/foreground_ticker.dart       |        |
///
/// One-shot timers: the check-in retry/reset (bounded; see the test at the end for why
/// the retry deliberately survives `paused`), the push registration retry (cancelled on
/// pause: `push_coordinator_test.dart`), and the lock's inactivity check (clock based, no
/// timer). `test/perf/no_background_work_test.dart` scans the source for anything else.

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

const _order = [
  AppLifecycleState.resumed,
  AppLifecycleState.inactive,
  AppLifecycleState.hidden,
  AppLifecycleState.paused,
];

/// Moves the app to [target] one legal step at a time, as Android delivers it
/// (resumed, inactive, hidden, paused; and back the same way).
void _goTo(TestWidgetsFlutterBinding binding, AppLifecycleState target) {
  var at = _order.indexOf(binding.lifecycleState ?? AppLifecycleState.resumed);
  final to = _order.indexOf(target);
  while (at != to) {
    at += to > at ? 1 : -1;
    binding.handleAppLifecycleStateChanged(_order[at]);
  }
}

void _lifecycle(WidgetTester tester, AppLifecycleState state) =>
    _goTo(tester.binding, state);

void _lifecycleOf(AppLifecycleState state) =>
    _goTo(TestWidgetsFlutterBinding.instance, state);

int _homeReads(TestFakes fakes) =>
    fakes.server.calls.where((c) => c == 'home').length;

void main() {
  group('ForegroundTicker', () {
    testWidgets('ticks while the app is in the foreground, and stops and '
        'starts with the lifecycle', (tester) async {
      final tracker = TimerTracker();
      await tracker.run(() async {
        var ticks = 0;
        var foreground = 0;
        final ticker = ForegroundTicker(
          period: const Duration(seconds: 30),
          onTick: () => ticks++,
          onForeground: () => foreground++,
        );
        addTearDown(ticker.stop);

        ticker.start();
        expect(ticker.isRunning, isTrue);
        expect(tracker.activePeriods, [const Duration(seconds: 30)]);
        await tester.pump(const Duration(seconds: 30));
        await tester.pump(const Duration(seconds: 30));
        expect(ticks, 2);

        // A system dialog or the notification shade changes nothing.
        _lifecycle(tester, AppLifecycleState.inactive);
        expect(ticker.isRunning, isTrue);

        _lifecycle(tester, AppLifecycleState.hidden);
        expect(ticker.isRunning, isFalse);
        expect(tracker.activePeriodic, 0);
        _lifecycle(tester, AppLifecycleState.paused);
        await tester.pump(const Duration(hours: 1));
        expect(ticks, 2, reason: 'nothing ticks in the background');
        expect(tracker.activePeriodic, 0);

        _lifecycle(tester, AppLifecycleState.inactive);
        expect(
          ticker.isRunning,
          isFalse,
          reason: 'still not in the foreground',
        );
        _lifecycle(tester, AppLifecycleState.resumed);
        expect(ticker.isRunning, isTrue);
        expect(foreground, 1, reason: 'one redraw when the app returns');
        expect(tracker.activePeriodic, 1);
        await tester.pump(const Duration(seconds: 30));
        expect(ticks, 3);

        // A second resume without a pause is not a return.
        _lifecycle(tester, AppLifecycleState.resumed);
        expect(foreground, 1);
        expect(tracker.activePeriodic, 1);

        ticker.stop();
        expect(tracker.activePeriodic, 0);
        _lifecycle(tester, AppLifecycleState.paused);
        _lifecycle(tester, AppLifecycleState.resumed);
        expect(ticker.isRunning, isFalse, reason: 'stopped means stopped');
        expect(foreground, 1);
      });
    });

    testWidgets('start twice is one timer; started while paused is none until '
        'the app returns', (tester) async {
      final tracker = TimerTracker();
      await tracker.run(() async {
        final ticker = ForegroundTicker(
          period: const Duration(seconds: 1),
          onTick: () {},
        );
        addTearDown(ticker.stop);
        _lifecycle(tester, AppLifecycleState.paused);
        ticker
          ..start()
          ..start();
        expect(tracker.activePeriodic, 0);
        _lifecycle(tester, AppLifecycleState.resumed);
        expect(tracker.activePeriodic, 1);
        expect(tracker.periodicCreated, 1);
        ticker.stop();
        expect(tracker.activePeriodic, 0);
      });
    });
  });

  group('Home', () {
    testWidgets('its ticker lives only in the foreground and only while the '
        'Home tab is on view', (tester) async {
      final tracker = TimerTracker();
      await tracker.run(() async {
        await openApp(tester, fakes: _world(), route: AppRoutes.home);
        expect(tracker.activePeriods, [const Duration(seconds: 30)]);

        _lifecycle(tester, AppLifecycleState.paused);
        expect(tracker.activePeriodic, 0, reason: 'paused');
        _lifecycle(tester, AppLifecycleState.resumed);
        await tester.pump();
        expect(tracker.activePeriods, [const Duration(seconds: 30)]);

        _lifecycle(tester, AppLifecycleState.hidden);
        expect(tracker.activePeriodic, 0, reason: 'hidden');
        _lifecycle(tester, AppLifecycleState.resumed);
        await tester.pump();
        expect(tracker.activePeriodic, 1);

        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('People'),
          ),
        );
        await tester.pumpAndSettle();
        expect(tracker.activePeriodic, 0, reason: 'another tab is on view');
      });
    });

    testWidgets('the poll of an open incident stops in the background and '
        'resumes with one read on return', (tester) async {
      final tracker = TimerTracker();
      await tracker.run(() async {
        final fakes = _world()..incidents.open(incidentJson());
        await openApp(tester, fakes: fakes, route: AppRoutes.home);
        final before = _homeReads(fakes);

        _lifecycle(tester, AppLifecycleState.paused);
        await tester.pump(const Duration(hours: 1));
        expect(_homeReads(fakes), before, reason: 'no reads in the background');
        expect(tracker.activePeriodic, 0);

        _lifecycle(tester, AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(_homeReads(fakes), before + 1);
      });
    });

    testWidgets('the interruption poll (a Hold is on) stops in the background '
        'and resumes with one read on return', (tester) async {
      final tracker = TimerTracker();
      await tracker.run(() async {
        final fakes = _world(now: DateTime.utc(2026, 10, 9, 6))
          ..server.serviceInterruption = true;
        await openApp(tester, fakes: fakes, route: AppRoutes.home);
        // Foreground: the minute poll runs.
        final start = _homeReads(fakes);
        await tester.pump(const Duration(seconds: 30));
        await tester.pump(const Duration(seconds: 30));
        await tester.pumpAndSettle();
        expect(_homeReads(fakes), start + 1);

        _lifecycle(tester, AppLifecycleState.paused);
        final paused = _homeReads(fakes);
        await tester.pump(const Duration(hours: 1));
        expect(_homeReads(fakes), paused);
        expect(tracker.activePeriodic, 0);

        _lifecycle(tester, AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(_homeReads(fakes), paused + 1);
      });
    });

    testWidgets('the poll of a passed deadline with no incident yet stops in '
        'the background', (tester) async {
      final tracker = TimerTracker();
      await tracker.run(() async {
        final fakes = _world(now: DateTime.utc(2026, 10, 9, 6));
        await openApp(tester, fakes: fakes, route: AppRoutes.home);
        fakes.clock.advance(const Duration(days: 2));
        await tester.pump(const Duration(seconds: 30));
        await tester.pumpAndSettle();
        final before = _homeReads(fakes);

        _lifecycle(tester, AppLifecycleState.paused);
        await tester.pump(const Duration(hours: 2));
        expect(_homeReads(fakes), before);
        expect(tracker.activePeriodic, 0);
      });
    });
  });

  group('the incident timeline', () {
    testWidgets('redraws every 30 s in the foreground, never in the '
        'background, and once when the app returns', (tester) async {
      final tracker = TimerTracker();
      await tracker.run(() async {
        final fakes = _world(now: DateTime.utc(2026, 10, 9, 17, 36, 20))
          ..incidents.open(escalatedJson());
        await openApp(tester, fakes: fakes, route: AppRoutes.homeIncident);
        // Home sits below the timeline (not on view): only the timeline ticks.
        expect(tracker.activePeriods, [const Duration(seconds: 30)]);

        _lifecycle(tester, AppLifecycleState.paused);
        expect(tracker.activePeriodic, 0);
        final reads = _homeReads(fakes);
        await tester.pump(const Duration(hours: 1));
        expect(tracker.activePeriodic, 0);
        expect(_homeReads(fakes), reads);

        _lifecycle(tester, AppLifecycleState.resumed);
        await tester.pump();
        expect(tracker.activePeriods, [const Duration(seconds: 30)]);

        // Leaving the screen ends its timer for good.
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(tracker.activePeriods, [const Duration(seconds: 30)]);
        // (that one is Home's, back on view)
      });
    });
  });

  group('the resend-code countdown', () {
    testWidgets('ticks each second while counting, not in the background, and '
        'not at all once the button is back', (tester) async {
      final tracker = TimerTracker();
      await tracker.run(() async {
        final fakes = TestFakes();
        final container = await pumpAfterMe(
          tester,
          fakes: fakes,
          status: AuthStatus.signedOut,
        );
        container.read(routerProvider).go(AppRoutes.createAccount);
        await tester.pumpAndSettle();
        await typeInto(tester, 'Your name', 'Diwakar');
        await typeInto(tester, 'Email', 'new@example.com');
        await typeInto(tester, 'Password', 'a long unique phrase');
        await tapText(tester, 'I am 18 or older.');
        await tapText(
          tester,
          'I agree to the Terms of Service and the Privacy Policy.',
        );
        await tapText(tester, 'Send my code');
        await tester.pumpAndSettle();
        expect(
          find.textContaining('You can ask for a new code in'),
          findsOneWidget,
        );
        // (The text fields' cursor blink is the framework's own 500 ms timer.)
        const second = Duration(seconds: 1);
        expect(tracker.activePeriods.where((p) => p == second), hasLength(1));

        _lifecycle(tester, AppLifecycleState.paused);
        expect(tracker.activePeriods.where((p) => p == second), isEmpty);
        fakes.clock.advance(const Duration(minutes: 5));
        await tester.pump(const Duration(minutes: 5));
        _lifecycle(tester, AppLifecycleState.resumed);
        await tester.pump();
        // The wait ended while the app was away: the button is back and nothing ticks.
        expect(find.text('Send a new code'), findsOneWidget);
        expect(tracker.activePeriods.where((p) => p == second), isEmpty);
      });
    });
  });

  group(
    'the check-in retry (a one-shot, deliberately kept in the background)',
    () {
      // The retry of an unconfirmed I'M OK is the one timer that is NOT cancelled when the
      // app is paused: a person who taps while offline and then puts the phone away must
      // still be counted when the network returns, not at the next time they open the app
      // (which can be more than 12 hours later, after contacts were alerted). It is not a
      // poll: one timer at a time, each waits longer (5 s ... 5 min), it is never periodic,
      // it ends with the answer, with the 12-hour age limit, and with the session. The
      // behaviours are pinned in checkin_controller_test.dart; this pins the part that
      // matters for the battery.
      test(
        'is one timer at a time, never periodic, never longer than 5 minutes, '
        'and gone with the session',
        () async {
          final fakes = TestFakes();
          fakes.server.failures['checkIn'] = [
            for (var i = 0; i < 9; i++) const NetworkFailure(),
          ];
          final container = ProviderContainer.test(
            retry: (retryCount, error) => null,
            overrides: testOverrides(
              authStatus: AuthStatus.signedIn,
              fakes: fakes,
            ),
          );
          container.listen(checkInControllerProvider, (_, _) {});
          final tracker = TimerTracker();
          await tracker.run(() async {
            await container.read(checkInControllerProvider.notifier).checkIn();
            for (var i = 0; i < 8; i++) {
              expect(fakes.timers.active, hasLength(1), reason: 'attempt $i');
              expect(
                fakes.timers.active.single.delay,
                lessThanOrEqualTo(const Duration(minutes: 5)),
              );
              fakes.timers.fireNext();
              await pumpEventQueue();
            }
          });
          expect(
            tracker.periodicCreated,
            0,
            reason: 'a retry is never periodic',
          );
          expect(fakes.timers.active, hasLength(1));

          // The app being paused does not take the retry away (see above) ...
          _lifecycleOf(AppLifecycleState.paused);
          expect(fakes.timers.active, hasLength(1));
          _lifecycleOf(AppLifecycleState.resumed);

          // ... the end of the session does.
          final fixed = container.read(
            authControllerProvider.notifier,
          ) as FixedAuthController;
          fixed.set(AuthStatus.signedOut);
          await pumpEventQueue();
          expect(fakes.timers.active, isEmpty);
        },
      );
    },
  );
}
