import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/core/security/app_lock/app_lock_controller.dart';
import 'package:afterme/core/security/app_lock/local_auth_gateway.dart';
import 'package:afterme/features/auth/application/me_controller.dart';
import 'package:afterme/features/auth/data/models/account_models.dart';
import 'package:afterme/features/home/application/home_controller.dart';
import 'package:afterme/features/settings/presentation/settings_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/fake_platform.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

Future<ProviderContainer> _open(
  WidgetTester tester,
  String route, {
  TestFakes? fakes,
}) async {
  final container = await pumpAfterMe(
    tester,
    fakes: fakes,
    status: AuthStatus.signedIn,
  );
  container.read(routerProvider).go(route);
  await tester.pumpAndSettle();
  return container;
}

/// Pumps a few frames. The busy button keeps an indeterminate spinner running behind
/// the re-authentication sheet, so `pumpAndSettle` would never finish there.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Finder _field(String label) => find.widgetWithText(TextField, label);

String? _error(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).decoration?.errorText;

String _text(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;

void main() {
  group('settings list', () {
    testWidgets('shows the account and opens each section', (tester) async {
      await _open(tester, AppRoutes.settings);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('Diwakar'), findsOneWidget);
      expect(find.text('diwakar@example.com'), findsOneWidget);

      for (final (label, heading) in [
        ('Profile', 'Your name'),
        ('Security', 'Change password'),
        ('Notifications', 'Reminders'),
        ('About AfterMe', 'Open-source licences'),
      ]) {
        await tapText(tester, label);
        await tester.pumpAndSettle();
        expect(find.text(heading), findsWidgets, reason: label);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('terms and privacy open in the browser', (tester) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.settings, fakes: fakes);
      await tapText(tester, 'Terms of Service');
      await tapText(tester, 'Privacy Policy');
      expect(fakes.urls.opened.map((u) => u.path), [
        '/legal/terms',
        '/legal/privacy',
      ]);
    });

    testWidgets('sign out asks first, then clears the session', (tester) async {
      final fakes = TestFakes();
      final container = await _open(tester, AppRoutes.settings, fakes: fakes);
      await tapText(tester, 'Sign out');
      await tester.pumpAndSettle();
      expect(find.text('Sign out of this phone?'), findsOneWidget);
      await tapText(tester, 'Cancel');
      await tester.pumpAndSettle();
      expect(container.read(authControllerProvider), AuthStatus.signedIn);

      await tapText(tester, 'Sign out');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();
      expect(fakes.auth.calls, contains('logout'));
      expect(container.read(authControllerProvider), AuthStatus.signedOut);
      expect(find.text('Get started'), findsOneWidget);
    });
  });

  group('profile', () {
    testWidgets('shows the saved values; Save is off until something changes', (
      tester,
    ) async {
      await _open(tester, AppRoutes.settingsProfile);
      expect(_text(tester, 'Your name'), 'Diwakar');
      expect(_text(tester, 'Phone (optional)'), '');
      expect(find.text('Asia/Kolkata'), findsWidgets);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Not set'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('saves only the changed fields', (tester) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.settingsProfile, fakes: fakes);
      await typeInto(tester, 'Your name', 'Asha');
      await tapText(tester, 'Save');
      await tester.pumpAndSettle();
      expect(fakes.auth.lastArgs['patchProfile'], {'display_name': 'Asha'});
      expect(find.text('Profile saved.'), findsOneWidget);
    });

    testWidgets('phone: validated, saved, then cleared with null', (
      tester,
    ) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.settingsProfile, fakes: fakes);
      await typeInto(tester, 'Phone (optional)', '98765');
      await tapText(tester, 'Save');
      expect(
        _error(tester, 'Phone (optional)'),
        contains('international format'),
      );
      expect(fakes.auth.calls, isNot(contains('patchProfile')));

      await typeInto(tester, 'Phone (optional)', '+919876543210');
      await tapText(tester, 'Save');
      await tester.pumpAndSettle();
      expect(fakes.auth.lastArgs['patchProfile'], {
        'phone_e164': '+919876543210',
      });

      await typeInto(tester, 'Phone (optional)', '');
      await tapText(tester, 'Save');
      await tester.pumpAndSettle();
      expect(fakes.auth.lastArgs['patchProfile'], {'phone_e164': null});
    });

    testWidgets('an invalid name is flagged', (tester) async {
      await _open(tester, AppRoutes.settingsProfile);
      await typeInto(tester, 'Your name', 'visit www.spam.com');
      await tapText(tester, 'Save');
      expect(_error(tester, 'Your name'), contains("can't contain links"));
    });

    testWidgets('country can be chosen and cleared', (tester) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.settingsProfile, fakes: fakes);
      await tapText(tester, 'Country');
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Search'), 'indi');
      await tester.pump();
      await tester.tap(find.text('India'));
      await tester.pumpAndSettle();
      expect(find.text('India'), findsOneWidget);
      await tapText(tester, 'Save');
      await tester.pumpAndSettle();
      expect(fakes.auth.lastArgs['patchProfile'], {'country_code': 'IN'});

      await tapText(tester, 'Country');
      await tester.pumpAndSettle();
      await tapText(tester, 'Not set');
      await tester.pumpAndSettle();
      await tapText(tester, 'Save');
      await tester.pumpAndSettle();
      expect(fakes.auth.lastArgs['patchProfile'], {'country_code': null});
    });

    testWidgets('timezone: a phone in another zone offers to adopt it', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.device.deviceTimezone = 'Europe/London';
      await _open(tester, AppRoutes.settingsProfile, fakes: fakes);
      expect(find.textContaining("timezone is different"), findsOneWidget);
      expect(find.text('Europe/London'), findsOneWidget);
      await tapText(tester, "Use my phone's timezone");
      await tester.pump();
      expect(find.textContaining('timezone is different'), findsNothing);
      await tapText(tester, 'Save');
      await tester.pumpAndSettle();
      expect(fakes.auth.lastArgs['patchProfile'], {
        'timezone': 'Europe/London',
      });
    });

    testWidgets('a timezone change while check-ins are on is saved and Home '
        'is read again', (tester) async {
      final fakes = TestFakes();
      fakes.device.deviceTimezone = 'Europe/London';
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      fakes.server.activateNow();
      final container = await _open(
        tester,
        AppRoutes.settingsProfile,
        fakes: fakes,
      );
      await container.read(homeControllerProvider.future);
      final reads = fakes.server.calls.where((c) => c == 'home').length;

      await tapText(tester, "Use my phone's timezone");
      await tester.pump();
      await tapText(tester, 'Save');
      await tester.pumpAndSettle();
      expect(fakes.auth.lastArgs['patchProfile'], {
        'timezone': 'Europe/London',
      });
      expect(
        fakes.server.calls.where((c) => c == 'home').length,
        reads + 1,
        reason: 'the server recomputed the deadline; Home reads it again',
      );
    });

    testWidgets('a timezone change during an incident is refused calmly', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.device.deviceTimezone = 'Europe/London';
      fakes.auth.fail(
        'patchProfile',
        const ConflictFailure(code: 'incident_open'),
      );
      await _open(tester, AppRoutes.settingsProfile, fakes: fakes);
      await tapText(tester, "Use my phone's timezone");
      await tester.pump();
      await tapText(tester, 'Save');
      await tester.pumpAndSettle();
      expect(
        find.text(
          "This can't be changed while a check-in is overdue. Check in first to make changes.",
        ),
        findsOneWidget,
      );
      expect(find.text('Profile saved.'), findsNothing);
    });

    testWidgets('timezone can be picked from the list', (tester) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.settingsProfile, fakes: fakes);
      await tapText(tester, 'Timezone');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Europe/London'));
      await tester.pumpAndSettle();
      await tapText(tester, 'Save');
      await tester.pumpAndSettle();
      expect(fakes.auth.lastArgs['patchProfile'], {
        'timezone': 'Europe/London',
      });
    });

    testWidgets('server field errors appear next to the field', (tester) async {
      final fakes = TestFakes();
      fakes.auth.fail(
        'patchProfile',
        const ValidationFailure(
          code: 'validation_failed',
          fieldErrors: [
            ApiFieldError(field: 'phone_e164', code: 'invalid_phone'),
          ],
        ),
      );
      await _open(tester, AppRoutes.settingsProfile, fakes: fakes);
      await typeInto(tester, 'Phone (optional)', '+919876543210');
      await tapText(tester, 'Save');
      await tester.pumpAndSettle();
      expect(
        _error(tester, 'Phone (optional)'),
        contains('international format'),
      );
    });

    testWidgets('other failures show a notice and keep the edits', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.auth.fail('patchProfile', const NetworkFailure());
      await _open(tester, AppRoutes.settingsProfile, fakes: fakes);
      await typeInto(tester, 'Your name', 'Asha');
      await tapText(tester, 'Save');
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(_text(tester, 'Your name'), 'Asha');
    });

    testWidgets('a profile that fails to load offers a retry', (tester) async {
      final fakes = TestFakes();
      fakes.auth.fail('me', const NetworkFailure());
      final container = await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedIn,
      );
      container.read(routerProvider).go(AppRoutes.settingsProfile);
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(_text(tester, 'Your name'), 'Diwakar');
    });
  });

  group('security', () {
    testWidgets('lists the actions and the app-lock state', (tester) async {
      await _open(tester, AppRoutes.settingsSecurity);
      expect(find.text('Change password'), findsOneWidget);
      expect(find.text('Change email'), findsOneWidget);
      expect(find.text('diwakar@example.com'), findsOneWidget);
      expect(find.text('Active sessions'), findsOneWidget);
      expect(find.text('App lock'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
    });

    testWidgets('log out everywhere needs the server and signs out', (
      tester,
    ) async {
      final fakes = TestFakes();
      final container = await _open(
        tester,
        AppRoutes.settingsSecurity,
        fakes: fakes,
      );
      fakes.auth.fail('logoutAll', const NetworkFailure());
      await tapText(tester, 'Log out everywhere');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Log out everywhere'));
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(container.read(authControllerProvider), AuthStatus.signedIn);

      await tapText(tester, 'Log out everywhere');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Log out everywhere'));
      await tester.pumpAndSettle();
      expect(container.read(authControllerProvider), AuthStatus.signedOut);
    });

    testWidgets('cancelling the confirmation does nothing', (tester) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.settingsSecurity, fakes: fakes);
      await tapText(tester, 'Log out everywhere');
      await tester.pumpAndSettle();
      await tapText(tester, 'Cancel');
      await tester.pumpAndSettle();
      expect(fakes.auth.calls, isNot(contains('logoutAll')));
    });
  });

  group('change password', () {
    testWidgets('validates every field before sending', (tester) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.settingsChangePassword, fakes: fakes);
      await tapText(tester, 'Change password');
      expect(_error(tester, 'Current password'), 'Please fill this in.');
      expect(_error(tester, 'New password'), 'Please fill this in.');

      await typeInto(tester, 'Current password', 'correct horse battery');
      await typeInto(tester, 'New password', 'correct horse battery');
      await typeInto(tester, 'Confirm new password', 'something else');
      await tapText(tester, 'Change password');
      expect(
        _error(tester, 'New password'),
        contains('different from your current'),
      );
      expect(
        _error(tester, 'Confirm new password'),
        "The two passwords don't match.",
      );
      expect(fakes.auth.calls, isNot(contains('changePassword')));
    });

    testWidgets(
      'a wrong current password is shown on that field and the session stays',
      (tester) async {
        final fakes = TestFakes();
        final container = await _open(
          tester,
          AppRoutes.settingsChangePassword,
          fakes: fakes,
        );
        await typeInto(tester, 'Current password', 'not the password');
        await typeInto(tester, 'New password', 'a brand new passphrase');
        await typeInto(
          tester,
          'Confirm new password',
          'a brand new passphrase',
        );
        await tapText(tester, 'Change password');
        await tester.pumpAndSettle();
        expect(
          _error(tester, 'Current password'),
          "That password didn't match. Try again.",
        );
        expect(container.read(authControllerProvider), AuthStatus.signedIn);
      },
    );

    testWidgets('success shows a message and goes back', (tester) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.settingsSecurity, fakes: fakes);
      await tapText(tester, 'Change password');
      await tester.pumpAndSettle();
      await typeInto(tester, 'Current password', 'correct horse battery');
      await typeInto(tester, 'New password', 'a brand new passphrase');
      await typeInto(tester, 'Confirm new password', 'a brand new passphrase');
      await tapText(tester, 'Change password');
      await tester.pumpAndSettle();
      expect(fakes.auth.password, 'a brand new passphrase');
      expect(
        find.text('Password changed. Your other devices were signed out.'),
        findsOneWidget,
      );
      expect(
        find.text('Active sessions'),
        findsOneWidget,
        reason: 'back on Security',
      );
    });

    testWidgets('server policy errors land on the new-password field', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.auth.fail(
        'changePassword',
        const ValidationFailure(
          code: 'validation_failed',
          fieldErrors: [
            ApiFieldError(field: 'new_password', code: 'password_too_common'),
          ],
        ),
      );
      await _open(tester, AppRoutes.settingsChangePassword, fakes: fakes);
      await typeInto(tester, 'Current password', 'correct horse battery');
      await typeInto(tester, 'New password', 'password123456');
      await typeInto(tester, 'Confirm new password', 'password123456');
      await tapText(tester, 'Change password');
      await tester.pumpAndSettle();
      expect(_error(tester, 'New password'), contains('too common'));
    });

    testWidgets('a rate limit shows a notice', (tester) async {
      final fakes = TestFakes();
      fakes.auth.fail(
        'changePassword',
        const RateLimitedFailure(retryAfter: Duration(minutes: 15)),
      );
      await _open(tester, AppRoutes.settingsChangePassword, fakes: fakes);
      await typeInto(tester, 'Current password', 'correct horse battery');
      await typeInto(tester, 'New password', 'a brand new passphrase');
      await typeInto(tester, 'Confirm new password', 'a brand new passphrase');
      await tapText(tester, 'Change password');
      await tester.pumpAndSettle();
      expect(
        find.text('Too many attempts. Try again in 15 minutes.'),
        findsOneWidget,
      );
    });
  });

  group('change email', () {
    Future<TestFakes> toCodeStep(WidgetTester tester) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.settingsChangeEmail, fakes: fakes);
      await typeInto(tester, 'New email address', 'new@example.com');
      await tapText(tester, 'Send the code');
      await _frames(tester);
      // Re-authentication is required first.
      expect(find.text("Confirm it's you"), findsOneWidget);
      await typeInto(tester, 'Password', 'correct horse battery');
      await tapText(tester, 'Confirm');
      await tester.pumpAndSettle();
      return fakes;
    }

    testWidgets('validates the new address', (tester) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.settingsChangeEmail, fakes: fakes);
      expect(find.text('Your current email address:'), findsOneWidget);
      expect(find.text('diwakar@example.com'), findsOneWidget);
      await tapText(tester, 'Send the code');
      expect(_error(tester, 'New email address'), 'Please fill this in.');
      await typeInto(tester, 'New email address', 'bad');
      await tapText(tester, 'Send the code');
      expect(
        _error(tester, 'New email address'),
        'Enter a valid email address.',
      );
      await typeInto(tester, 'New email address', ' Diwakar@Example.com ');
      await tapText(tester, 'Send the code');
      expect(
        _error(tester, 'New email address'),
        'That is already your email address.',
      );
      expect(fakes.auth.calls, isNot(contains('emailChangeStart')));
    });

    testWidgets(
      'asks for the password, sends the code, verifies, updates the account',
      (tester) async {
        final fakes = await toCodeStep(tester);
        expect(
          fakes.auth.calls.where((c) => c == 'emailChangeStart'),
          hasLength(2),
          reason: 'first attempt needed re-auth, the retry succeeded',
        );
        expect(find.text('Enter the code'), findsOneWidget);
        expect(find.textContaining('new@example.com'), findsOneWidget);

        await typeInto(tester, '6-digit code', '000000');
        await tapText(tester, 'Confirm new email');
        await tester.pumpAndSettle();
        expect(find.textContaining('wrong or has expired'), findsOneWidget);

        await typeInto(tester, '6-digit code', '482 913');
        await tapText(tester, 'Confirm new email');
        await tester.pumpAndSettle();
        expect(find.text('Your email address was updated.'), findsOneWidget);
      },
    );

    testWidgets('the account shows the new address afterwards', (tester) async {
      final fakes = TestFakes();
      final container = await _open(
        tester,
        AppRoutes.settingsChangeEmail,
        fakes: fakes,
      );
      fakes.auth.reauthenticated = true;
      await typeInto(tester, 'New email address', 'new@example.com');
      await tapText(tester, 'Send the code');
      await tester.pumpAndSettle();
      await typeInto(tester, '6-digit code', '482913');
      await tapText(tester, 'Confirm new email');
      await tester.pumpAndSettle();
      expect(
        container.read(meControllerProvider).value?.email,
        'new@example.com',
      );
    });

    testWidgets('dismissing the password sheet stays on the address step', (
      tester,
    ) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.settingsChangeEmail, fakes: fakes);
      await typeInto(tester, 'New email address', 'new@example.com');
      await tapText(tester, 'Send the code');
      await _frames(tester);
      await tapText(tester, 'Cancel');
      await tester.pumpAndSettle();
      expect(find.text('Send the code'), findsOneWidget);
      expect(find.text('Enter the code'), findsNothing);
    });

    testWidgets('"Use a different address" returns to the first step', (
      tester,
    ) async {
      await toCodeStep(tester);
      await tapText(tester, 'Use a different address');
      await tester.pumpAndSettle();
      expect(find.text('Send the code'), findsOneWidget);
    });

    testWidgets('a short code is flagged; failures are calm', (tester) async {
      final fakes = await toCodeStep(tester);
      await typeInto(tester, '6-digit code', '12');
      await tapText(tester, 'Confirm new email');
      expect(
        _error(tester, '6-digit code'),
        'Enter the 6-digit code from the email.',
      );
      fakes.auth.fail(
        'emailChangeVerify',
        const ServerFailure(statusCode: 500),
      );
      await typeInto(tester, '6-digit code', '482913');
      await tapText(tester, 'Confirm new email');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Something went wrong on our side'),
        findsOneWidget,
      );
    });

    testWidgets('start failures are shown', (tester) async {
      final fakes = TestFakes();
      fakes.auth.fail(
        'emailChangeStart',
        const RateLimitedFailure(retryAfter: Duration(minutes: 30)),
      );
      await _open(tester, AppRoutes.settingsChangeEmail, fakes: fakes);
      await typeInto(tester, 'New email address', 'new@example.com');
      await tapText(tester, 'Send the code');
      await tester.pumpAndSettle();
      expect(
        find.text('Too many attempts. Try again in 30 minutes.'),
        findsOneWidget,
      );
    });
  });

  group('sessions', () {
    testWidgets(
      'lists this device first-class and others with a sign-out button',
      (tester) async {
        await _open(tester, AppRoutes.settingsSessions);
        expect(find.text('This device'), findsOneWidget);
        expect(find.text('Android app, version 0.1.0+7'), findsOneWidget);
        expect(find.text('Android app, version 0.1.0+5'), findsOneWidget);
        expect(
          find.text('Sign out this device'),
          findsOneWidget,
          reason: 'only the other one',
        );
        expect(find.textContaining('Last active'), findsNWidgets(2));
      },
    );

    testWidgets('the sign-out button is spoken with the device it is for', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _open(tester, AppRoutes.settingsSessions);
      expect(
        find.bySemanticsLabel(
          RegExp(r'Sign out Android app, version 0\.1\.0\+5, last active '),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('revoking asks first and removes the row once confirmed', (
      tester,
    ) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.settingsSessions, fakes: fakes);
      await tapText(tester, 'Sign out this device');
      await tester.pumpAndSettle();
      expect(find.text('Sign out this device?'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(FilledButton, 'Sign out this device'),
      );
      await tester.pumpAndSettle();
      expect(fakes.auth.calls, contains('revokeSession'));
      expect(find.text('Device signed out.'), findsOneWidget);
      expect(find.text('Android app, version 0.1.0+5'), findsNothing);
    });

    testWidgets('a failed revoke keeps the row and says why', (tester) async {
      final fakes = TestFakes();
      fakes.auth.fail('revokeSession', const NetworkFailure());
      await _open(tester, AppRoutes.settingsSessions, fakes: fakes);
      await tapText(tester, 'Sign out this device');
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Sign out this device'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(find.text('Android app, version 0.1.0+5'), findsOneWidget);
    });

    testWidgets('cancel does nothing; log out everywhere signs out', (
      tester,
    ) async {
      final fakes = TestFakes();
      final container = await _open(
        tester,
        AppRoutes.settingsSessions,
        fakes: fakes,
      );
      await tapText(tester, 'Sign out this device');
      await tester.pumpAndSettle();
      await tapText(tester, 'Cancel');
      await tester.pumpAndSettle();
      expect(fakes.auth.calls, isNot(contains('revokeSession')));

      await tapText(tester, 'Log out everywhere');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Log out everywhere'));
      await tester.pumpAndSettle();
      expect(container.read(authControllerProvider), AuthStatus.signedOut);
    });

    testWidgets('web sessions and failed log-out-everywhere', (tester) async {
      final fakes = TestFakes();
      fakes.auth.sessions = [
        fakes.auth.sessions.first,
        fakes.auth.sessions.last.copyWith(device: null, kind: 'web'),
      ];
      fakes.auth.fail('logoutAll', const NetworkFailure());
      final container = await _open(
        tester,
        AppRoutes.settingsSessions,
        fakes: fakes,
      );
      expect(find.text('Web check-in'), findsOneWidget);
      await tapText(tester, 'Log out everywhere');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Log out everywhere'));
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(container.read(authControllerProvider), AuthStatus.signedIn);
    });

    testWidgets('a session without an app version and the load error state', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.auth.sessions = [
        fakes.auth.sessions.first.copyWith(
          device: const SessionDevice(platform: 'android'),
        ),
      ];
      await _open(tester, AppRoutes.settingsSessions, fakes: fakes);
      expect(find.text('Android app'), findsOneWidget);
    });

    testWidgets('a sessions list that fails to load offers a retry', (
      tester,
    ) async {
      final failing = TestFakes();
      failing.auth.fail('listSessions', const NetworkFailure());
      await _open(tester, AppRoutes.settingsSessions, fakes: failing);
      expect(find.textContaining("You're offline"), findsOneWidget);
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.text('This device'), findsOneWidget);
    });

    testWidgets('an empty list says so', (tester) async {
      final fakes = TestFakes();
      fakes.auth.sessions = [];
      await _open(tester, AppRoutes.settingsSessions, fakes: fakes);
      expect(find.text('No other sessions.'), findsOneWidget);
    });
  });

  group('app lock settings', () {
    testWidgets(
      'turning it on asks the person to confirm, then shows the timeouts',
      (tester) async {
        final fakes = TestFakes();
        final container = await _open(
          tester,
          AppRoutes.settingsAppLock,
          fakes: fakes,
        );
        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(container.read(appLockControllerProvider).enabled, isTrue);
        expect(fakes.localAuth.reasons, [
          "Confirm it's you to turn on app lock",
        ]);
        expect(find.text('Lock after'), findsOneWidget);
        expect(find.text('After 5 minutes away'), findsOneWidget);

        await tester.tap(find.text('Immediately when I leave the app'));
        await tester.pumpAndSettle();
        expect(
          container.read(appLockControllerProvider).timeout,
          AppLockTimeout.immediately,
        );
        await tester.tap(find.text('After 1 minute away'));
        await tester.pumpAndSettle();
        expect(
          container.read(appLockControllerProvider).timeout,
          AppLockTimeout.oneMinute,
        );
      },
    );

    testWidgets('without a screen lock it explains instead of failing', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.localAuth.lockCapability = LockCapability.noScreenLock;
      final container = await _open(
        tester,
        AppRoutes.settingsAppLock,
        fakes: fakes,
      );
      expect(find.textContaining('has no screen lock yet'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(container.read(appLockControllerProvider).enabled, isFalse);
      expect(find.textContaining('has no screen lock yet'), findsOneWidget);
    });

    testWidgets(
      'an unconfirmed attempt changes nothing; turning off needs confirmation',
      (tester) async {
        final fakes = TestFakes();
        fakes.localAuth.outcomes.add(AuthOutcome.canceled);
        final container = await _open(
          tester,
          AppRoutes.settingsAppLock,
          fakes: fakes,
        );
        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(
          find.textContaining("couldn't confirm it was you"),
          findsOneWidget,
        );
        expect(container.read(appLockControllerProvider).enabled, isFalse);

        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(container.read(appLockControllerProvider).enabled, isTrue);
        fakes.localAuth.outcomes.add(AuthOutcome.failed);
        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(container.read(appLockControllerProvider).enabled, isTrue);
        expect(
          find.textContaining("couldn't confirm it was you"),
          findsOneWidget,
        );
        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(container.read(appLockControllerProvider).enabled, isFalse);
      },
    );
  });

  group('notifications settings', () {
    testWidgets('explains first, asks only on tap, then shows the result', (
      tester,
    ) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.settingsNotifications, fakes: fakes);
      expect(find.text('Notifications are off.'), findsOneWidget);
      expect(fakes.notifications.requests, 0);
      expect(
        find.textContaining('Emails about a missed check-in are always on'),
        findsOneWidget,
      );
      await tapText(tester, 'Allow notifications');
      await tester.pumpAndSettle();
      expect(fakes.notifications.requests, 1);
      expect(find.text('Notifications are on.'), findsOneWidget);
      expect(find.text('Allow notifications'), findsNothing);
    });

    testWidgets('permanently denied leads to the system settings', (
      tester,
    ) async {
      final fakes = TestFakes(
        notifications: FakeNotificationPermissionGateway(
          current: NotificationPermission.permanentlyDenied,
        ),
      );
      await _open(tester, AppRoutes.settingsNotifications, fakes: fakes);
      expect(find.textContaining('blocked'), findsWidgets);
      expect(find.text('Allow notifications'), findsNothing);
      await tapText(tester, 'Open phone settings');
      expect(fakes.notifications.settingsOpened, 1);
    });

    testWidgets('coming back from the system settings refreshes the status', (
      tester,
    ) async {
      final fakes = TestFakes(
        notifications: FakeNotificationPermissionGateway(
          current: NotificationPermission.permanentlyDenied,
        ),
      );
      await _open(tester, AppRoutes.settingsNotifications, fakes: fakes);
      fakes.notifications.current = NotificationPermission.granted;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Notifications are on.'), findsOneWidget);
    });
  });

  group('about', () {
    testWidgets('shows version and the disclaimer; licences open', (
      tester,
    ) async {
      await _open(tester, AppRoutes.settingsAbout);
      expect(find.text('Version 0.1.0 (7)'), findsOneWidget);
      expect(find.textContaining('not an emergency service'), findsOneWidget);
      await tapText(tester, 'Open-source licences');
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
    });
  });
}
