import 'package:afterme/app/router.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/features/settings/presentation/notifications_settings_screen.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

TestFakes _fakes({
  required NotificationPermission permission,
  bool configured = true,
}) {
  final fakes = TestFakes();
  fakes.push.configured = configured;
  fakes.notifications.current = permission;
  return fakes;
}

void main() {
  final l10n = AppLocalizationsEn();

  group('Settings > Notifications', () {
    testWidgets('on: the status, the three channels, email and what a '
        'notification never says', (tester) async {
      final fakes = _fakes(permission: NotificationPermission.granted);
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.settingsNotifications,
      );
      expect(find.byType(NotificationsSettingsScreen), findsOneWidget);
      expect(find.text('Notifications are on.'), findsOneWidget);
      expect(find.text('Allow notifications'), findsNothing);
      expect(find.text(l10n.notificationsNotConfigured), findsNothing);

      expect(find.text('What can arrive'), findsOneWidget);
      for (final name in [
        l10n.notificationChannelRemindersName,
        l10n.notificationChannelIncidentsName,
        l10n.notificationChannelAccountName,
      ]) {
        expect(find.text(name), findsOneWidget);
      }
      for (final description in [
        l10n.notificationChannelRemindersDescription,
        l10n.notificationChannelIncidentsDescription,
        l10n.notificationChannelAccountDescription,
      ]) {
        expect(find.text(description), findsOneWidget);
      }
      expect(find.text(l10n.notificationsLostBody), findsOneWidget);
      expect(find.textContaining('also arrive by email'), findsOneWidget);
      expect(find.text(l10n.notificationsEmailAlways), findsOneWidget);
      expect(find.text(l10n.notificationsPrivateBody), findsOneWidget);
      expect(find.textContaining('never names a person'), findsOneWidget);
    });

    testWidgets(
      'off: it asks only on tap, and the plan is still reached by email',
      (tester) async {
        final fakes = _fakes(permission: NotificationPermission.denied);
        await openApp(
          tester,
          fakes: fakes,
          route: AppRoutes.settingsNotifications,
        );
        expect(find.text('Notifications are off.'), findsOneWidget);
        expect(find.text('Allow notifications'), findsOneWidget);
        expect(fakes.notifications.requests, 0);
        expect(find.text('If notifications are off'), findsOneWidget);
        expect(find.textContaining('also arrive by email'), findsOneWidget);
      },
    );

    testWidgets('blocked: the way to the system settings', (tester) async {
      final fakes = _fakes(
        permission: NotificationPermission.permanentlyDenied,
      );
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.settingsNotifications,
      );
      expect(find.textContaining('blocked in your phone'), findsOneWidget);
      expect(find.text('Allow notifications'), findsNothing);
      await tapText(tester, 'Open phone settings');
      expect(fakes.notifications.settingsOpened, 1);
    });

    testWidgets(
      'a build without push says so calmly, and email still reaches the person',
      (tester) async {
        final fakes = _fakes(
          permission: NotificationPermission.granted,
          configured: false,
        );
        await openApp(
          tester,
          fakes: fakes,
          route: AppRoutes.settingsNotifications,
        );
        expect(find.text(l10n.notificationsNotConfigured), findsOneWidget);
        expect(find.textContaining('still reach you by email'), findsOneWidget);
        expect(find.textContaining('error'), findsNothing);
      },
    );

    testWidgets('allowing from here registers and updates the status', (
      tester,
    ) async {
      final fakes = _fakes(permission: NotificationPermission.denied);
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.settingsNotifications,
      );
      expect(fakes.devices.puts, isEmpty);
      await tapText(tester, 'Allow notifications');
      await tester.pumpAndSettle();
      expect(find.text('Notifications are on.'), findsOneWidget);
      expect(fakes.devices.puts, hasLength(1));
    });
  });
}
