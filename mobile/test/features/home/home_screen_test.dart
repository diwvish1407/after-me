import 'dart:async';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/design_system/check_in_button.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/features/checkin/application/checkin_controller.dart';
import 'package:afterme/features/checkin/application/pending_checkin_store.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/contacts/presentation/contact_detail_screen.dart';
import 'package:afterme/features/home/application/home_controller.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:afterme/features/onboarding/application/setup_controller.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/real_fonts.dart';
import '../../helpers/test_app.dart';

/// The test clock is 2026-10-08 12:00 UTC = 5:30 PM in Asia/Kolkata, the profile zone.
TestFakes _fakes({
  List<TrustedContact>? contacts,
  bool active = false,
  bool notificationsOn = true,
}) {
  final fakes = TestFakes();
  if (notificationsOn) {
    fakes.notifications.current = NotificationPermission.granted;
  }
  if (contacts != null) {
    fakes.contacts = InMemoryContactsRepository(initial: contacts);
  }
  if (active) {
    // An account whose check-ins are on has a plan that tells its contacts (the server
    // only turns them on when it does), so no gap is flagged unless a test makes one.
    if (contacts != null && contacts.isNotEmpty) {
      fakes.plan.seedStandard([for (final contact in contacts) contact.id]);
    }
    fakes.server.activateNow();
  }
  return fakes;
}

CheckInButtonState _buttonState(WidgetTester tester) =>
    tester.widget<CheckInButton>(find.byType(CheckInButton)).state;

/// A tap the server never confirmed, made [age] before the test clock's now, kept for
/// the signed-in account (`openApp` signs in as `user-1`).
Future<void> _keepTap(
  TestFakes fakes, {
  required Duration age,
  String userId = 'user-1',
}) => fakes.secure.write(
  PendingCheckInStore.storageKey,
  PendingCheckIn(
    userId: userId,
    idempotencyKey: 'old-key',
    reportedAt: fakes.clock.now().subtract(age),
  ).encode(),
);

const _expiredTitle = "Your earlier check-in wasn't received";

Future<void> _tapCheckIn(WidgetTester tester) async {
  await tester.ensureVisible(find.byType(CheckInButton));
  await tester.pump();
  await tester.tap(find.byType(CheckInButton));
  await tester.pump();
}

void main() {
  // Real Roboto widths, for the tests that measure where things land on a small phone.
  setUpAll(loadRoboto);

  group('Not active', () {
    testWidgets('no contact yet: the checklist, a disabled button and no '
        'check-in', (tester) async {
      final fakes = _fakes();
      await openApp(tester, fakes: fakes, route: AppRoutes.home);

      expect(find.text("Let's finish your plan"), findsOneWidget);
      expect(find.text('Hello, Diwakar'), findsOneWidget);
      expect(find.text('Add a trusted contact'), findsOneWidget);
      expect(find.text('Check in every day by 8:00 PM.'), findsOneWidget);
      expect(find.text('Review your plan'), findsOneWidget);
      expect(_buttonState(tester), CheckInButtonState.disabled);
      expect(
        tester.widget<CheckInButton>(find.byType(CheckInButton)).onPressed,
        isNull,
      );
      expect(
        find.text('Turn on check-ins to start checking in.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Turn on check-ins'),
            )
            .onPressed,
        isNull,
        reason: 'the server would say no_contacts',
      );
      expect(
        find.textContaining('Preview: your instructions are not saved yet'),
        findsOneWidget,
      );
      expect(fakes.server.calls.where((c) => c == 'checkIn'), isEmpty);
    });

    testWidgets('with a contact and a plan it is ready; turning on goes '
        'through the server', (tester) async {
      final fakes = _fakes(contacts: [testContact()]);
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
      );
      await container
          .read(setupControllerProvider.notifier)
          .savePlan(PlanPresets.standard([testContact()]));
      await tester.pumpAndSettle();

      expect(find.text('Ready to turn on check-ins'), findsOneWidget);
      await tapText(tester, 'Turn on check-ins');
      await tester.pumpAndSettle();

      expect(fakes.server.calls.where((c) => c == 'activate'), hasLength(1));
      expect(find.text("You're checked in"), findsOneWidget);
      expect(find.text('Tomorrow · 8:00 PM'), findsOneWidget);
      expect(find.text('No check-in yet'), findsOneWidget);
      expect(_buttonState(tester), CheckInButtonState.idle);
    });

    testWidgets('the plan item opens the plan step; saving the plan ticks it '
        'and Home is ready to turn on', (tester) async {
      final fakes = _fakes(contacts: [testContact()]);
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(find.text("Let's finish your plan"), findsOneWidget);
      expect(find.text('No plan stages yet'), findsNothing);

      await tapText(tester, 'Set up');
      await tester.pumpAndSettle();
      expect(find.text('Your plan'), findsOneWidget);
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();

      // A re-opened step returns Home, which read the aggregate again.
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(fakes.plan.stages, hasLength(1));
      expect(fakes.plan.stages.single.contactIds, ['c1']);
      expect(find.text('Ready to turn on check-ins'), findsOneWidget);
      await tapText(tester, 'Turn on check-ins');
      await tester.pumpAndSettle();
      expect(find.text("You're checked in"), findsOneWidget);
      expect(find.text('1 plan stage'), findsOneWidget);
    });

    testWidgets('the server says what is missing; unknown codes are said '
        'generically', (tester) async {
      final fakes = _fakes(contacts: [testContact()]);
      // No plan has been saved, so the server also says no_stages.
      fakes.server.extraRequirements = ['brand_new_code'];
      await openApp(tester, fakes: fakes, route: AppRoutes.home);

      await tapText(tester, 'Turn on check-ins');
      await tester.pumpAndSettle();
      expect(
        find.text(
          "Check-ins aren't on yet. Still needed: a plan stage, something else in your plan.",
        ),
        findsOneWidget,
      );
      expect(_buttonState(tester), CheckInButtonState.disabled);
      expect(fakes.server.status, CheckInStatus.inactive);
    });

    testWidgets('another failure is shown calmly and can be retried', (
      tester,
    ) async {
      final fakes = _fakes(contacts: [testContact()]);
      fakes.plan.seedStandard(['c1']);
      fakes.server.failures['activate'] = [const NetworkFailure()];
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      await tapText(tester, 'Turn on check-ins');
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      await tapText(tester, 'Turn on check-ins');
      await tester.pumpAndSettle();
      expect(find.text("You're checked in"), findsOneWidget);
    });

    testWidgets('a contact that is a stand-in for the plan checklist opens '
        'the same steps', (tester) async {
      await openApp(tester, fakes: _fakes(), route: AppRoutes.home);
      await tapText(tester, 'Change');
      await tester.pumpAndSettle();
      expect(find.text('When should you check in?'), findsOneWidget);
    });
  });

  group('Active', () {
    testWidgets('You\'re checked in, next and last check-in in the profile '
        'timezone, and the plan card', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server.lastCheckinAt = DateTime.utc(2026, 10, 8, 11, 30);
      await openApp(tester, fakes: fakes, route: AppRoutes.home);

      expect(find.text("You're checked in"), findsOneWidget);
      expect(find.text('Tomorrow · 8:00 PM'), findsOneWidget);
      expect(find.text('Today · 5:00 PM'), findsOneWidget);
      expect(find.text('Trusted contacts: 1 of 1 accepted'), findsOneWidget);
      expect(find.text('1 plan stage'), findsOneWidget);
      expect(find.text('No instructions shared yet'), findsOneWidget);
      expect(_buttonState(tester), CheckInButtonState.idle);
      expect(
        find.text('Turn on check-ins'),
        findsNothing,
        reason: 'already on',
      );
    });

    testWidgets('times follow the profile timezone, not the phone\'s', (
      tester,
    ) async {
      final fakes = _fakes(contacts: [testContact()]);
      fakes.auth.timezone = 'Pacific/Auckland';
      fakes.server.timezone = 'Pacific/Auckland';
      fakes.server.activateNow();
      // 12:00 UTC is 01:00 on Oct 9 in Auckland (NZDT, UTC+13); the next deadline is
      // 20:00 there on Oct 10, which is 07:00 UTC: read in UTC it would say 7:00 AM.
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(
        fakes.server.nextDueAt,
        DateTime.utc(2026, 10, 10, 7),
        reason: '20:00 NZDT is 07:00 UTC',
      );
      expect(find.text('Tomorrow · 8:00 PM'), findsOneWidget);
      expect(find.textContaining('7:00 AM'), findsNothing);
    });

    testWidgets('Due soon: within the reminder lead of the deadline', (
      tester,
    ) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server.nextDueAt = fakes.server.now.add(
        const Duration(minutes: 45),
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(
        find.text('Check-in due at 6:15 PM — in 45 minutes'),
        findsOneWidget,
      );
      expect(_buttonState(tester), CheckInButtonState.idle);
    });

    testWidgets('Due soon appears as the clock moves on, from the server '
        'time', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      // The server's clock runs 10 minutes ahead of the phone's.
      fakes.server.skew = const Duration(minutes: 10);
      fakes.server.nextDueAt = fakes.server.now.add(
        const Duration(minutes: 100),
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(find.text("You're checked in"), findsOneWidget);

      fakes.clock.advance(const Duration(minutes: 41));
      await tester.pump(const Duration(seconds: 31));
      expect(
        find.text('Check-in due at 7:20 PM — in 59 minutes'),
        findsOneWidget,
      );
    });

    testWidgets('a deadline that passed is never shown as checked in', (
      tester,
    ) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server.nextDueAt = fakes.server.now.subtract(
        const Duration(minutes: 5),
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(find.text("You're checked in"), findsNothing);
      expect(find.text('Your 5:25 PM check-in is due'), findsOneWidget);
      expect(find.text("Tap I'M OK to check in."), findsOneWidget);
    });

    testWidgets('an overdue deadline makes Home read the aggregate again', (
      tester,
    ) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server.nextDueAt = fakes.server.now.add(
        const Duration(minutes: 10),
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      final before = fakes.server.calls.where((c) => c == 'home').length;

      fakes.clock.advance(const Duration(minutes: 11));
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(fakes.server.calls.where((c) => c == 'home').length, before + 1);
    });
  });

  group('I\'M OK', () {
    testWidgets('Sending…, then Checked in only after the answer, with the '
        'next check-in announced', (tester) async {
      final handle = tester.ensureSemantics();
      final fakes = _fakes(contacts: [testContact()], active: true);
      final gate = Completer<void>();
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      fakes.server.checkInGate = gate.future;

      await _tapCheckIn(tester);
      await tester.pump();
      expect(_buttonState(tester), CheckInButtonState.sending);
      expect(find.text('Sending…'), findsOneWidget);
      expect(find.text('Checked in'), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(_buttonState(tester), CheckInButtonState.success);
      expect(
        find.text('Checked in. Next check-in tomorrow at 8:00 PM.'),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.text('Checked in. Next check-in tomorrow at 8:00 PM.'),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.liveRegion == true,
          ),
        ),
        findsOneWidget,
        reason: 'read out by TalkBack when it appears',
      );
      expect(
        find.text('Today · 5:30 PM'),
        findsOneWidget,
        reason: 'last check-in',
      );
      handle.dispose();
    });

    testWidgets('goes back to I\'M OK after a moment', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(_buttonState(tester), CheckInButtonState.success);
      fakes.timers.fireNext();
      await tester.pumpAndSettle();
      expect(_buttonState(tester), CheckInButtonState.idle);
      expect(
        find.text('Checked in. Next check-in tomorrow at 8:00 PM.'),
        findsNothing,
      );
    });

    testWidgets('not received yet: says so, keeps trying, and Try again sends '
        'the same check-in', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      await openApp(tester, fakes: fakes, route: AppRoutes.home);

      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(find.text("Not received yet — we'll keep trying"), findsOneWidget);
      expect(
        find.textContaining("You tapped I'M OK at 5:30 PM."),
        findsOneWidget,
      );
      expect(_buttonState(tester), CheckInButtonState.pending);
      expect(find.text("You're checked in"), findsNothing);

      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(_buttonState(tester), CheckInButtonState.success);
      expect(fakes.server.checkInKeys, ['key-1', 'key-1']);
      expect(fakes.server.recorded, 1);
    });

    testWidgets('while a retry is on the wire it still says not received yet', (
      tester,
    ) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(_buttonState(tester), CheckInButtonState.pending);

      final gate = Completer<void>();
      fakes.server.checkInGate = gate.future;
      await tapText(tester, 'Try again');
      await tester.pump();
      expect(_buttonState(tester), CheckInButtonState.sending);
      expect(find.text("Not received yet — we'll keep trying"), findsOneWidget);
      expect(find.text("You're checked in"), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(_buttonState(tester), CheckInButtonState.success);
      expect(find.text("Not received yet — we'll keep trying"), findsNothing);
    });

    testWidgets('tapping the pending button itself also retries', (
      tester,
    ) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server.failures['checkIn'] = [const ServerFailure(statusCode: 503)];
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(_buttonState(tester), CheckInButtonState.pending);
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(_buttonState(tester), CheckInButtonState.success);
    });

    testWidgets('the app coming back to the foreground sends it again', (
      tester,
    ) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(_buttonState(tester), CheckInButtonState.pending);

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(_buttonState(tester), CheckInButtonState.success);
      expect(fakes.server.checkInKeys, ['key-1', 'key-1']);
    });

    testWidgets('a rate limit says when it will be sent again', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server.failures['checkIn'] = [
        const RateLimitedFailure(retryAfter: Duration(minutes: 20)),
      ];
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(
        find.text(
          "Too many attempts. We'll send your check-in again in 20 minutes.",
        ),
        findsOneWidget,
      );
      expect(_buttonState(tester), CheckInButtonState.pending);
    });

    testWidgets('a session that cannot be used says to sign in and keeps '
        'the check-in', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server.failures['checkIn'] = [
        const UnauthorizedFailure(code: 'unauthenticated'),
      ];
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
      );
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Please sign in to check in.'),
        findsOneWidget,
      );
      expect(
        container.read(checkInControllerProvider).phase,
        CheckInPhase.signInRequired,
      );
    });

    testWidgets('a refused check-in says nothing was recorded and can be '
        'tapped again', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server.failures['checkIn'] = [
        const ValidationFailure(code: 'validation_failed'),
      ];
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(find.text("That check-in didn't go through"), findsOneWidget);
      expect(_buttonState(tester), CheckInButtonState.idle);
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(_buttonState(tester), CheckInButtonState.success);
    });

    testWidgets('safe_required: explains, and I\'M OK is off', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server
        ..openIncident(details: {'id': 'i-1'})
        ..contactsMessaged = true;
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      // An incident is open: the neutral placeholder first.
      expect(find.text('Your check-in is overdue'), findsOneWidget);
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(find.text("Please confirm you're safe"), findsOneWidget);
      expect(
        find.textContaining(
          'That isn\'t available in this version of AfterMe yet',
        ),
        findsOneWidget,
      );
      expect(_buttonState(tester), CheckInButtonState.disabled);
      expect(fakes.server.recorded, 0);
    });

    testWidgets('an incident that no one was told about is resolved by '
        'checking in', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server.openIncident(details: {'id': 'i-1'});
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(find.text('Your check-in is overdue'), findsOneWidget);
      expect(find.text("Tap I'M OK if you're all right."), findsOneWidget);
      expect(_buttonState(tester), CheckInButtonState.idle);

      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(find.text('Welcome back. No one was contacted.'), findsOneWidget);
      expect(find.text('Your check-in is overdue'), findsNothing);
    });
  });

  group('A tap that is too old to count', () {
    // The test clock is 12:00 UTC on Oct 8; 30 hours earlier is 06:00 UTC on Oct 7,
    // which is 11:30 AM in Asia/Kolkata.
    const age = Duration(hours: 30);

    testWidgets('says so calmly, never claims a check-in, and I\'M OK stays '
        'on', (tester) async {
      final handle = tester.ensureSemantics();
      final fakes = _fakes(contacts: [testContact()], active: true);
      await _keepTap(fakes, age: age);
      await openApp(tester, fakes: fakes, route: AppRoutes.home);

      expect(find.text(_expiredTitle), findsOneWidget);
      expect(
        find.text(
          "You tapped I'M OK yesterday at 11:30 AM, but it never reached us "
          'and is too old to count. Please tap I\'M OK again.',
        ),
        findsOneWidget,
      );
      expect(find.text("You're checked in"), findsNothing);
      expect(find.text("Not received yet — we'll keep trying"), findsNothing);
      expect(find.text('Try again'), findsNothing);
      expect(_buttonState(tester), CheckInButtonState.idle);
      expect(
        tester.widget<CheckInButton>(find.byType(CheckInButton)).onPressed,
        isNotNull,
      );
      expect(
        find.ancestor(
          of: find.text(_expiredTitle),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.liveRegion == true,
          ),
        ),
        findsOneWidget,
        reason: 'read out when it appears',
      );
      expect(
        fakes.server.calls.where((c) => c == 'checkIn'),
        isEmpty,
        reason: 'the old tap is never sent',
      );
      handle.dispose();
    });

    testWidgets('the time is in the profile timezone, with the day', (
      tester,
    ) async {
      final fakes = _fakes(contacts: [testContact()]);
      fakes.auth.timezone = 'Pacific/Auckland';
      fakes.server.timezone = 'Pacific/Auckland';
      fakes.server.activateNow();
      await _keepTap(fakes, age: age);
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      // 06:00 UTC on Oct 7 is 7:00 PM there (NZDT, UTC+13); "now" is Oct 9 there.
      expect(
        find.textContaining("You tapped I'M OK on Oct 7 at 7:00 PM, but"),
        findsOneWidget,
      );
      expect(find.textContaining('6:00 AM'), findsNothing);
    });

    testWidgets('Got it dismisses it and brings the status back', (
      tester,
    ) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      await _keepTap(fakes, age: age);
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(find.text(_expiredTitle), findsOneWidget);

      await tapText(tester, 'Got it');
      await tester.pumpAndSettle();
      expect(find.text(_expiredTitle), findsNothing);
      expect(find.text('Got it'), findsNothing);
      expect(find.text("You're checked in"), findsOneWidget);
      expect(_buttonState(tester), CheckInButtonState.idle);
      expect(fakes.server.calls.where((c) => c == 'checkIn'), isEmpty);
    });

    testWidgets('tapping I\'M OK sends a new tap with a new key and clears '
        'it', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      await _keepTap(fakes, age: age);
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(find.text(_expiredTitle), findsOneWidget);

      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(find.text(_expiredTitle), findsNothing);
      expect(_buttonState(tester), CheckInButtonState.success);
      expect(
        find.text('Checked in. Next check-in tomorrow at 8:00 PM.'),
        findsOneWidget,
      );
      expect(fakes.server.checkInKeys, ['key-1']);
      expect(fakes.server.recorded, 1);
    });

    testWidgets('a tap that ages out while Home is open offline is dropped '
        'at Try again', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(find.text("Not received yet — we'll keep trying"), findsOneWidget);

      fakes.clock.advance(const Duration(hours: 12, seconds: 1));
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.text(_expiredTitle), findsOneWidget);
      expect(
        find.textContaining("You tapped I'M OK yesterday at 5:30 PM, but"),
        findsOneWidget,
        reason: 'the time of the tap, not of the notice',
      );
      expect(find.text("Not received yet — we'll keep trying"), findsNothing);
      expect(find.text('Try again'), findsNothing);
      expect(_buttonState(tester), CheckInButtonState.idle);
      expect(fakes.server.checkInKeys, ['key-1']);
      expect(fakes.server.recorded, 0);
    });

    testWidgets('the app coming back to the foreground drops a tap that aged '
        'out', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(_buttonState(tester), CheckInButtonState.pending);

      fakes.clock.advance(const Duration(days: 1));
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(find.text(_expiredTitle), findsOneWidget);
      expect(fakes.server.checkInKeys, ['key-1']);
    });

    testWidgets('also shows when Home itself cannot be loaded', (tester) async {
      final fakes = _fakes(active: true);
      fakes.server.failures['home'] = [
        const NetworkFailure(),
        const NetworkFailure(),
      ];
      await _keepTap(fakes, age: age);
      await openApp(tester, fakes: fakes, route: AppRoutes.home);

      expect(find.text('Offline — showing last known status'), findsOneWidget);
      expect(find.text(_expiredTitle), findsOneWidget);
      expect(_buttonState(tester), CheckInButtonState.idle);

      await tapText(tester, 'Got it');
      await tester.pumpAndSettle();
      expect(find.text(_expiredTitle), findsNothing);
    });

    testWidgets('a tap of another account shows nothing', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      await _keepTap(fakes, age: age, userId: 'someone-else');
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(find.text(_expiredTitle), findsNothing);
      expect(find.text("You're checked in"), findsOneWidget);
      expect(fakes.server.calls.where((c) => c == 'checkIn'), isEmpty);
    });

    testWidgets('a tap that is not too old yet is still sent and counted', (
      tester,
    ) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      await _keepTap(fakes, age: const Duration(hours: 12));
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(find.text(_expiredTitle), findsNothing);
      expect(_buttonState(tester), CheckInButtonState.success);
      expect(fakes.server.checkInKeys, ['old-key']);
    });
  });

  group('Offline and errors', () {
    testWidgets('a failed refresh keeps the last status and says so', (
      tester,
    ) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
      );
      expect(find.text('Offline — showing last known status'), findsNothing);

      fakes.server.failures['home'] = [const NetworkFailure()];
      await container.read(homeControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(find.text('Offline — showing last known status'), findsOneWidget);
      expect(find.text("You're checked in"), findsOneWidget);
      expect(find.text('Tomorrow · 8:00 PM'), findsOneWidget);

      // I'M OK still queues as pending while offline.
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(_buttonState(tester), CheckInButtonState.pending);
      expect(find.text("Not received yet — we'll keep trying"), findsOneWidget);
    });

    testWidgets('pull to refresh reads again', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      final before = fakes.server.calls.where((c) => c == 'home').length;
      await tester.fling(
        find.byType(SingleChildScrollView).first,
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(fakes.server.calls.where((c) => c == 'home').length, before + 1);
    });

    testWidgets('cold start offline: no status, but I\'M OK still works', (
      tester,
    ) async {
      final fakes = _fakes(active: true);
      fakes.server.failures['home'] = [
        const NetworkFailure(),
        const NetworkFailure(),
      ];
      await openApp(tester, fakes: fakes, route: AppRoutes.home);

      expect(find.text('Offline — showing last known status'), findsOneWidget);
      expect(
        find.textContaining("We can't show your latest status right now."),
        findsOneWidget,
      );
      expect(_buttonState(tester), CheckInButtonState.idle);

      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(_buttonState(tester), CheckInButtonState.pending);

      // Back online: Try again reads Home and the check-in goes through.
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(fakes.server.recorded, 1);
    });

    testWidgets('an error that retrying cannot fix is shown plainly', (
      tester,
    ) async {
      final fakes = _fakes();
      fakes.server.failures['home'] = [const UpgradeRequiredFailure()];
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(
        find.text('Please update AfterMe to keep your plan running.'),
        findsOneWidget,
      );
      expect(find.byType(CheckInButton), findsNothing);
    });

    testWidgets('a status from a newer server claims nothing', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.server.status = CheckInStatus.unknown;
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(find.text("You're checked in"), findsNothing);
      expect(find.text("Your check-in status can't be shown"), findsOneWidget);
      expect(_buttonState(tester), CheckInButtonState.idle);
    });
  });

  group('Readiness banners', () {
    Future<void> openWith(WidgetTester tester, TestFakes fakes) =>
        openApp(tester, fakes: fakes, route: AppRoutes.home);

    testWidgets('a contact that declined comes first and opens that contact', (
      tester,
    ) async {
      final fakes = _fakes(
        contacts: [
          testContact(status: VerificationStatus.declined),
          testContact(
            id: 'c2',
            name: 'Dad',
            email: 'dad@example.com',
            status: VerificationStatus.pending,
          ),
        ],
        active: true,
        notificationsOn: false,
      );
      await openWith(tester, fakes);
      expect(
        find.textContaining("One trusted contact can't be reached or said no."),
        findsOneWidget,
      );
      expect(find.textContaining("hasn't accepted"), findsNothing);
      await tapText(tester, 'Open contact');
      await tester.pumpAndSettle();
      expect(find.byType(ContactDetailScreen), findsOneWidget);
      expect(find.text('Mom'), findsWidgets);
    });

    testWidgets('then a contact that has not answered', (tester) async {
      final fakes = _fakes(
        contacts: [testContact(status: VerificationStatus.pending)],
        active: true,
        notificationsOn: false,
      );
      await openWith(tester, fakes);
      expect(
        find.text("One trusted contact hasn't accepted your invitation yet."),
        findsOneWidget,
      );
      expect(
        find.textContaining('Notifications are off'),
        findsNothing,
        reason: 'one at a time',
      );
    });

    testWidgets('then notifications off, with a way to the settings', (
      tester,
    ) async {
      final fakes = _fakes(
        contacts: [testContact()],
        active: true,
        notificationsOn: false,
      );
      await openWith(tester, fakes);
      expect(
        find.text(
          "Notifications are off, so you won't get a reminder before a check-in is due.",
        ),
        findsOneWidget,
      );
      await tapText(tester, 'Notification settings');
      await tester.pumpAndSettle();
      expect(find.text('Reminders'), findsOneWidget);
    });

    testWidgets('then the timezone, with a way to the profile', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      fakes.device.deviceTimezone = 'America/New_York';
      await openWith(tester, fakes);
      expect(
        find.textContaining("Your phone's timezone is different"),
        findsOneWidget,
      );
      await tapText(tester, 'Review timezone');
      await tester.pumpAndSettle();
      expect(find.text('Profile'), findsWidgets);
    });

    testWidgets('nothing when all is well; the checklist replaces banners '
        'while check-ins are off', (tester) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      await openWith(tester, fakes);
      expect(find.textContaining('Notifications are off'), findsNothing);
      expect(find.textContaining('hasn\'t accepted'), findsNothing);

      final off = _fakes(
        contacts: [testContact(status: VerificationStatus.declined)],
        notificationsOn: false,
      );
      await openWith(tester, off);
      expect(find.textContaining('can\'t be reached'), findsNothing);
      expect(find.text("Let's finish your plan"), findsOneWidget);
    });
  });

  group('A safety net with a gap', () {
    const noContacts =
        'You have no trusted contact. If you miss a check-in, nobody is told.';
    const noStages =
        'Your plan has no stage. If you miss a check-in, nobody is told.';
    const stageEmpty =
        "A stage in your plan has nobody to tell, so it wouldn't reach anyone.";

    void expectNoGap() {
      for (final message in [noContacts, noStages, stageEmpty]) {
        expect(find.text(message), findsNothing, reason: message);
      }
    }

    /// Check-ins on, with [contacts] and no plan saved.
    TestFakes withoutPlan([List<TrustedContact>? contacts]) {
      final fakes = TestFakes();
      fakes.notifications.current = NotificationPermission.granted;
      if (contacts != null) {
        fakes.contacts = InMemoryContactsRepository(initial: contacts);
      }
      fakes.server.activateNow();
      return fakes;
    }

    Future<ProviderContainer> openHome(WidgetTester tester, TestFakes fakes) =>
        openApp(tester, fakes: fakes, route: AppRoutes.home);

    testWidgets('no trusted contact: says what is wrong and the one thing to '
        'do, and the rest of Home stays', (tester) async {
      // The last contact was removed: the plan's stage was emptied with them.
      final fakes = withoutPlan();
      fakes.plan.seed(
        const PlanDraft(
          graceMinutes: 180,
          stages: [PlanStageDraft(offsetMinutes: 180, contactIds: [])],
        ),
      );
      await openHome(tester, fakes);

      expect(find.text(noContacts), findsOneWidget);
      expect(find.text('Add a trusted contact'), findsOneWidget);
      expect(
        find.text(noStages),
        findsNothing,
        reason: 'contact first, one thing to do',
      );
      expect(find.text(stageEmpty), findsNothing);
      // Not dismissible: nothing but the action.
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.text('Got it'), findsNothing);
      // Home itself is untouched.
      expect(find.text("You're checked in"), findsOneWidget);
      expect(find.text('Tomorrow · 8:00 PM'), findsOneWidget);
      expect(_buttonState(tester), CheckInButtonState.idle);
      expect(
        tester.widget<CheckInButton>(find.byType(CheckInButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets('I\'M OK stays on the first screen of a small phone, above '
        'the navigation bar, with the gap and one readiness hint', (
      tester,
    ) async {
      Future<void> open(TestFakes fakes) => openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
        size: const Size(360, 780),
        roboto: true,
      );
      double navTop() => tester.getTopLeft(find.byType(NavigationBar)).dy;

      // The gap alone: the whole button is above the navigation bar.
      await open(withoutPlan([testContact()]));
      expect(find.text(noStages), findsOneWidget);
      expect(
        tester.getRect(find.byType(CheckInButton)).bottom,
        lessThan(navTop()),
      );

      // With a readiness hint as well (the contact has not answered yet): the button is
      // still in the first screen, and reachable by a short scroll.
      await open(
        withoutPlan([testContact(status: VerificationStatus.pending)]),
      );
      expect(find.text(noStages), findsOneWidget);
      expect(find.textContaining("hasn't accepted"), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(CheckInButton)).dy,
        lessThan(navTop()),
      );
    });

    testWidgets('a plan with no stage: review the plan', (tester) async {
      await openHome(tester, withoutPlan([testContact()]));
      expect(find.text(noStages), findsOneWidget);
      expect(find.text('Review your plan'), findsOneWidget);
      expect(find.text(noContacts), findsNothing);

      await tapText(tester, 'Review your plan');
      await tester.pumpAndSettle();
      expect(find.text('Your plan'), findsOneWidget);
      expect(find.text('Use this plan'), findsOneWidget);
    });

    testWidgets('a stage that tells nobody: review the plan', (tester) async {
      final fakes = withoutPlan([testContact()]);
      fakes.plan.seed(
        const PlanDraft(
          graceMinutes: 180,
          stages: [PlanStageDraft(offsetMinutes: 180, contactIds: [])],
        ),
      );
      await openHome(tester, fakes);
      expect(find.text(stageEmpty), findsOneWidget);
      expect(find.text('Review your plan'), findsOneWidget);
      expect(find.text(noStages), findsNothing);
      expect(_buttonState(tester), CheckInButtonState.idle);
    });

    testWidgets('a plan that tells someone has no banner', (tester) async {
      await openHome(tester, _fakes(contacts: [testContact()], active: true));
      expectNoGap();
      expect(find.text("You're checked in"), findsOneWidget);
    });

    testWidgets('per-contact problems alone are not a gap: they keep their own '
        'banner', (tester) async {
      await openHome(
        tester,
        _fakes(
          contacts: [testContact(status: VerificationStatus.declined)],
          active: true,
        ),
      );
      expectNoGap();
      expect(
        find.textContaining("One trusted contact can't be reached"),
        findsOneWidget,
      );

      await openHome(
        tester,
        _fakes(
          contacts: [testContact(status: VerificationStatus.pending)],
          active: true,
        ),
      );
      expectNoGap();
      expect(find.textContaining("hasn't accepted"), findsOneWidget);
    });

    testWidgets('not while check-ins are off: the checklist already says '
        'so', (tester) async {
      await openHome(tester, _fakes());
      expectNoGap();
      expect(find.text("Let's finish your plan"), findsOneWidget);
      expect(find.text('Add a trusted contact'), findsOneWidget);
    });

    testWidgets('a status this version does not know claims nothing, so '
        'there is no gap either', (tester) async {
      final fakes = withoutPlan();
      fakes.server.status = CheckInStatus.unknown;
      await openHome(tester, fakes);
      expectNoGap();
      expect(find.text("Your check-in status can't be shown"), findsOneWidget);
    });

    testWidgets('also when the deadline has just passed and the server has not '
        'moved on yet', (tester) async {
      final fakes = withoutPlan([testContact()]);
      fakes.server.nextDueAt = fakes.server.now.subtract(
        const Duration(minutes: 5),
      );
      await openHome(tester, fakes);
      expect(find.text('Your 5:25 PM check-in is due'), findsOneWidget);
      expect(find.text(noStages), findsOneWidget);
      expect(_buttonState(tester), CheckInButtonState.idle);
    });

    testWidgets('not during an open incident: the plan is read-only then', (
      tester,
    ) async {
      final fakes = withoutPlan();
      fakes.server.openIncident(details: {'id': 'i-1'});
      await openHome(tester, fakes);
      expectNoGap();
      expect(find.text('Your check-in is overdue'), findsOneWidget);
    });

    testWidgets('it is still there after leaving and coming back, and after '
        'Home reads again', (tester) async {
      final fakes = withoutPlan([testContact()]);
      final container = await openHome(tester, fakes);
      await tapText(tester, 'Review your plan');
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text(noStages), findsOneWidget);

      final before = fakes.server.calls.where((c) => c == 'home').length;
      await container.read(homeControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(fakes.server.calls.where((c) => c == 'home').length, before + 1);
      expect(find.text(noStages), findsOneWidget);
    });

    testWidgets('sits with the other banners without hiding any of them or '
        'I\'M OK', (tester) async {
      // A contact that has not answered and no plan stage, then a check-in that is not
      // received, then a Home refresh that fails: every banner at once.
      final fakes = withoutPlan([
        testContact(status: VerificationStatus.pending),
      ]);
      final container = await openHome(tester, fakes);
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      fakes.server.failures['home'] = [const NetworkFailure()];
      await container.read(homeControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();

      final offline = find.text('Offline — showing last known status');
      final greeting = find.text('Hello, Diwakar');
      final gap = find.text(noStages);
      final readiness = find.text(
        "One trusted contact hasn't accepted your invitation yet.",
      );
      final pending = find.text("Not received yet — we'll keep trying");
      final all = [offline, greeting, gap, readiness, pending];
      for (final finder in all) {
        expect(finder, findsOneWidget);
      }
      // Top to bottom: what is offline, who it is, the gap, the readiness hint, the
      // status of the tap, then the button.
      final tops = [for (final f in all) tester.getTopLeft(f).dy];
      expect(tops, [...tops]..sort(), reason: 'in this order');
      expect(
        tester.getTopLeft(find.byType(CheckInButton)).dy,
        greaterThan(tops.last),
      );
      expect(_buttonState(tester), CheckInButtonState.pending);

      // I'M OK still works from here.
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(_buttonState(tester), CheckInButtonState.success);
      expect(find.text(noStages), findsOneWidget);
    });

    testWidgets('also with a tap that was too old to count', (tester) async {
      final fakes = withoutPlan([testContact()]);
      await _keepTap(fakes, age: const Duration(hours: 30));
      await openHome(tester, fakes);
      expect(find.text(noStages), findsOneWidget);
      expect(find.text(_expiredTitle), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(noStages)).dy,
        lessThan(tester.getTopLeft(find.text(_expiredTitle)).dy),
      );
      expect(_buttonState(tester), CheckInButtonState.idle);
      await tapText(tester, 'Got it');
      await tester.pumpAndSettle();
      expect(
        find.text(noStages),
        findsOneWidget,
        reason: 'dismissing the notice does not touch the gap',
      );
    });

    testWidgets('goes away step by step as the gap is fixed: contact, then '
        'plan', (tester) async {
      final fakes = withoutPlan();
      await openHome(tester, fakes);
      expect(find.text(noContacts), findsOneWidget);

      // Add the contact through the step the banner opens.
      await tapText(tester, 'Add a trusted contact');
      await tester.pumpAndSettle();
      await fillContactForm(tester);
      await tapText(tester, 'Save and continue');
      await tester.pumpAndSettle();
      // Back on Home, which read the aggregate again: the contact is there, the plan
      // is the next thing.
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text(noContacts), findsNothing);
      expect(find.text(noStages), findsOneWidget);

      // Save the plan through the step the banner opens (check-ins are on: password).
      await tapText(tester, 'Review your plan');
      await tester.pumpAndSettle();
      await tapText(tester, 'Use this plan');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text("Confirm it's you"), findsOneWidget);
      await typeInto(tester, 'Password', fakes.auth.password);
      await tapText(tester, 'Confirm');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expectNoGap();
      expect(fakes.plan.stages.single.contactIds, [
        fakes.contacts.contacts.single.id,
      ]);
      expect(find.text('1 plan stage'), findsOneWidget);
      expect(find.text("You're checked in"), findsOneWidget);
    });

    testWidgets('removing the last contact who is told leaves Home saying so', (
      tester,
    ) async {
      final fakes = _fakes(contacts: [testContact()], active: true);
      await openHome(tester, fakes);
      expectNoGap();

      await tapText(tester, 'People');
      await tester.pumpAndSettle();
      await tapText(tester, 'Mom');
      await tester.pumpAndSettle();
      await tapText(tester, 'Remove');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // In the plan, with check-ins on: the password first.
      expect(find.text("Confirm it's you"), findsOneWidget);
      await typeInto(tester, 'Password', fakes.auth.password);
      await tapText(tester, 'Confirm');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(fakes.contacts.contacts, isEmpty);

      await tapText(tester, 'Home');
      await tester.pumpAndSettle();
      expect(find.text("You're checked in"), findsOneWidget);
      expect(find.text(noContacts), findsOneWidget);
      expect(find.text('Add a trusted contact'), findsOneWidget);
    });
  });

  group('Layout', () {
    testWidgets('every state fits at 2.0 text scale without overflow', (
      tester,
    ) async {
      final fakes = _fakes(
        contacts: [testContact(status: VerificationStatus.pending)],
        active: true,
        notificationsOn: false,
      );
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
        textScale: 2,
        size: const Size(320, 690),
      );
      await _tapCheckIn(tester);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
