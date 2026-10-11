import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/core/push/push_gateway.dart';
import 'package:afterme/core/security/app_lock/app_lock_controller.dart';
import 'package:afterme/core/security/app_lock/local_auth_gateway.dart';
import 'package:afterme/features/auth/presentation/sign_in_screen.dart';
import 'package:afterme/features/contacts/presentation/people_screen.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/fake_push.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

IncomingPush _tap(String type, {String v = '1'}) =>
    IncomingPush(data: {'type': type, 'v': v});

/// Push as a person meets it: the real app, the real router and the app lock, with the
/// push service, the notifications and the devices API faked.
TestFakes _push({
  bool configured = true,
  NotificationPermission permission = NotificationPermission.granted,
}) {
  final fakes = TestFakes();
  fakes.push.configured = configured;
  fakes.notifications.current = permission;
  fakes.realPushNavigation = true;
  return fakes;
}

void main() {
  group('the app starts push', () {
    testWidgets('on the first frame: channels, listening, the token', (
      tester,
    ) async {
      final fakes = _push();
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(fakes.localNotifications.initializations, 1);
      expect(fakes.localNotifications.channels, hasLength(3));
      expect(fakes.devices.puts, hasLength(1));
      expect(
        fakes.devices.puts.single['push_token'],
        FakePushGateway.defaultToken,
      );
    });

    testWidgets('and registers when the app returns with notifications allowed '
        'in the system settings', (tester) async {
      final fakes = _push(permission: NotificationPermission.denied);
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(fakes.devices.puts, isEmpty);

      fakes.notifications.current = NotificationPermission.granted;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fakes.devices.puts, hasLength(1));
    });

    testWidgets(
      'a build without a push service runs normally and sends nothing',
      (tester) async {
        final fakes = _push(configured: false);
        await openApp(tester, fakes: fakes, route: AppRoutes.home);
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(fakes.devices.puts, isEmpty);
        expect(fakes.push.tokenReads, 0);
      },
    );
  });

  group('a tap on a notification', () {
    testWidgets(
      'opens the People tab for a contact that could not be reached',
      (tester) async {
        final fakes = _push();
        await openApp(tester, fakes: fakes, route: AppRoutes.home);
        expect(find.byType(HomeScreen), findsOneWidget);

        fakes.push.opened.add(_tap('contact_unreachable'));
        await tester.pumpAndSettle();
        expect(find.byType(PeopleScreen), findsOneWidget);
      },
    );

    testWidgets('opens Home for a reminder, wherever the person was', (
      tester,
    ) async {
      final fakes = _push();
      await openApp(tester, fakes: fakes, route: AppRoutes.people);
      expect(find.byType(PeopleScreen), findsOneWidget);

      fakes.push.opened.add(_tap('incident_missed'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('a type this version does not know opens Home', (tester) async {
      final fakes = _push();
      await openApp(tester, fakes: fakes, route: AppRoutes.people);
      fakes.push.opened.add(_tap('something_new'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('a notification that started the app opens its place', (
      tester,
    ) async {
      final fakes = _push();
      fakes.push.initial = _tap('contact_unreachable');
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      await tester.pumpAndSettle();
      expect(find.byType(PeopleScreen), findsOneWidget);
    });

    testWidgets('a push shown by the app is followed by its type', (
      tester,
    ) async {
      final fakes = _push();
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      fakes.localNotifications.tap('contact_unreachable');
      await tester.pumpAndSettle();
      expect(find.byType(PeopleScreen), findsOneWidget);
    });

    testWidgets(
      'while signed out goes to sign-in and shows nothing of the push',
      (tester) async {
        final fakes = _push();
        fakes.push.initial = _tap('incident_missed');
        await pumpAfterMe(tester, fakes: fakes, status: AuthStatus.signedOut);
        await tester.pumpAndSettle();
        expect(find.byType(SignInScreen), findsOneWidget);
        expect(find.byType(HomeScreen), findsNothing);
        expect(fakes.localNotifications.shown, isEmpty);
        expect(fakes.devices.puts, isEmpty);
      },
    );

    testWidgets('waits behind the app lock, which shows nothing until it is '
        'opened', (tester) async {
      final fakes = _push();
      fakes.prefs = freshPreferences({
        'afterme.onboardingUserId': 'user-1',
        'afterme.onboardingCompleted': true,
        'afterme.appLockEnabled': true,
      });
      // The first unlock asks on its own; the person does not answer yet.
      fakes.localAuth.outcomes.add(AuthOutcome.canceled);
      final handle = tester.ensureSemantics();
      final container = await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedIn,
      );
      expect(find.text('AfterMe is locked'), findsOneWidget);
      expect(container.read(appLockControllerProvider).locked, isTrue);

      fakes.push.opened.add(_tap('contact_unreachable'));
      await tester.pumpAndSettle();
      // Still locked; neither the old page nor the new one is on screen or readable.
      expect(find.text('AfterMe is locked'), findsOneWidget);
      expect(find.byType(PeopleScreen), findsNothing);
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.bySemanticsLabel(RegExp('People')), findsNothing);

      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('AfterMe is locked'), findsNothing);
      expect(find.byType(PeopleScreen), findsOneWidget);
      handle.dispose();
    });
  });

  group('a push while the app is open', () {
    testWidgets('is shown as a notification, and Home reads again', (
      tester,
    ) async {
      final fakes = _push();
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      final reads = fakes.server.calls.where((c) => c == 'home').length;

      fakes.push.foreground.add(
        const IncomingPush(
          data: {'type': 'checkin_pre_reminder', 'v': '1'},
          title: 'Check-in due soon',
          body: "Tap to let AfterMe know you're OK.",
          channelId: 'reminders',
        ),
      );
      await tester.pumpAndSettle();

      expect(fakes.localNotifications.shown, hasLength(1));
      expect(fakes.server.calls.where((c) => c == 'home').length, reads + 1);
    });
  });

  group('Home\'s notifications banner follows the phone', () {
    testWidgets('and goes when notifications are allowed from Settings', (
      tester,
    ) async {
      final fakes = _push(permission: NotificationPermission.denied);
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      fakes.plan.seedStandard(['c1']);
      fakes.server.activateNow();
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
      );
      expect(
        find.textContaining('Notifications are off, so you won'),
        findsOneWidget,
      );

      await tapText(tester, 'Notification settings');
      await tester.pumpAndSettle();
      await tapText(tester, 'Allow notifications');
      await tester.pumpAndSettle();
      expect(fakes.devices.puts, hasLength(1), reason: 'the answer registers');

      container.read(routerProvider).go(AppRoutes.home);
      await tester.pumpAndSettle();
      expect(find.textContaining('Notifications are off'), findsNothing);
    });
  });
}
