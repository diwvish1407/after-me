import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/home/application/home_status.dart';
import 'package:afterme/features/home/presentation/home_screen.dart'
    show safetyNetGapPath;
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:afterme/features/onboarding/presentation/welcome_screen.dart';
import 'package:afterme/features/privacy/application/account_closed_notice.dart';
import 'package:afterme/features/privacy/presentation/account_closed_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fakes.dart';
import '../helpers/pump_app.dart';
import '../helpers/test_app.dart';

/// The routes of Phase 7's Settings screens and the way back to sign-in after the
/// account was closed.
void main() {
  String? redirect(
    AuthStatus status,
    String location, {
    bool accountClosed = false,
    bool sessionEnded = false,
    OnboardingState onboarding = const OnboardingState(loaded: true),
  }) => authRedirect(
    status: status,
    location: location,
    isDev: false,
    accountClosed: accountClosed,
    sessionEnded: sessionEnded,
    onboarding: onboarding,
  );

  group('redirect rules', () {
    test('the new Settings screens are signed-in routes', () {
      for (final path in [
        AppRoutes.settingsActivity,
        AppRoutes.settingsYourPlan,
        AppRoutes.settingsPrivacy,
        AppRoutes.settingsExport,
        AppRoutes.settingsDelete,
        AppRoutes.settingsLostPhone,
      ]) {
        expect(AppRoutes.settingsScreens, contains(path));
        expect(redirect(AuthStatus.signedIn, path), isNull, reason: path);
        expect(
          redirect(AuthStatus.signedOut, path),
          AppRoutes.welcome,
          reason: path,
        );
        expect(
          redirect(
            AuthStatus.signedIn,
            path,
            onboarding: const OnboardingState(
              loaded: true,
              completed: false,
              step: OnboardingStep.schedule,
            ),
          ),
          OnboardingStep.schedule.path,
          reason: 'mid-onboarding people cannot open $path',
        );
      }
      expect(AppRoutes.settingsExport, '/settings/privacy/export');
      expect(AppRoutes.settingsDelete, '/settings/privacy/delete');
    });

    test('the closed screen is where a signed-out app goes while the notice '
        'is set, whatever else is asked for', () {
      for (final path in [
        AppRoutes.welcome,
        AppRoutes.signIn,
        AppRoutes.createAccount,
        AppRoutes.forgotPassword,
        AppRoutes.settingsDelete,
        AppRoutes.home,
        '/nowhere',
      ]) {
        expect(
          redirect(AuthStatus.signedOut, path, accountClosed: true),
          AppRoutes.accountClosed,
          reason: path,
        );
      }
      expect(
        redirect(
          AuthStatus.signedOut,
          AppRoutes.accountClosed,
          accountClosed: true,
        ),
        isNull,
      );
      // Even a "please sign in again" does not take it away.
      expect(
        redirect(
          AuthStatus.signedOut,
          AppRoutes.signIn,
          accountClosed: true,
          sessionEnded: true,
        ),
        AppRoutes.accountClosed,
      );
    });

    test('without the notice it is not a place to arrive at', () {
      expect(
        redirect(AuthStatus.signedOut, AppRoutes.accountClosed),
        AppRoutes.welcome,
      );
      expect(
        redirect(AuthStatus.signedIn, AppRoutes.accountClosed),
        AppRoutes.home,
      );
      expect(
        redirect(AuthStatus.unknown, AppRoutes.accountClosed),
        AppRoutes.splash,
      );
    });

    test('it is a known route', () {
      expect(
        AppRoutes.knownRoutes(isDev: false),
        contains(AppRoutes.accountClosed),
      );
      expect(AppRoutes.accountClosed, '/account-closed');
    });
  });

  group('the screen', () {
    testWidgets('is shown once the notice is set, and Continue leads to '
        'sign-in', (tester) async {
      final container = await pumpAfterMe(tester, status: AuthStatus.signedOut);
      expect(find.byType(WelcomeScreen), findsOneWidget);
      container
          .read(accountClosedNoticeProvider.notifier)
          .close(AccountClosed(purgeAfter: DateTime.utc(2026, 11, 7, 9)));
      await tester.pumpAndSettle();
      expect(find.byType(AccountClosedScreen), findsOneWidget);
      expect(find.text('Your account has been closed'), findsOneWidget);
      expect(
        find.text(
          'The rest of your information is removed by Saturday, November 7, '
          '2026.',
        ),
        findsOneWidget,
      );
      // Back does not get out of it.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AccountClosedScreen), findsOneWidget);

      await tapText(tester, 'Continue');
      await tester.pumpAndSettle();
      expect(find.byType(AccountClosedScreen), findsNothing);
      expect(find.text('Sign in'), findsWidgets);
      expect(container.read(accountClosedNoticeProvider), isNull);
    });

    testWidgets('the date is shown in the profile\'s timezone', (tester) async {
      final container = await pumpAfterMe(tester, status: AuthStatus.signedOut);
      container
          .read(accountClosedNoticeProvider.notifier)
          .close(
            // 22:00 UTC is already the next morning in Kolkata.
            AccountClosed(
              purgeAfter: DateTime.utc(2026, 11, 7, 22),
              timezone: 'Asia/Kolkata',
            ),
          );
      await tester.pumpAndSettle();
      expect(find.textContaining('Sunday, November 8, 2026'), findsOneWidget);
    });

    testWidgets('a deletion confirmed by a repeat has no date and says so', (
      tester,
    ) async {
      final container = await pumpAfterMe(tester, status: AuthStatus.signedOut);
      container
          .read(accountClosedNoticeProvider.notifier)
          .close(const AccountClosed());
      await tester.pumpAndSettle();
      expect(
        find.text('The rest of your information is removed within 30 days.'),
        findsOneWidget,
      );
    });

    testWidgets('a new sign-in is a new account: the notice is forgotten', (
      tester,
    ) async {
      final fakes = TestFakes();
      final container = await pumpAfterMe(tester, fakes: fakes);
      await container.read(authControllerProvider.notifier).restored;
      container
          .read(accountClosedNoticeProvider.notifier)
          .close(const AccountClosed());
      await tester.pumpAndSettle();
      expect(find.byType(AccountClosedScreen), findsOneWidget);
      await container
          .read(authControllerProvider.notifier)
          .signIn(tokenResponse());
      await tester.pumpAndSettle();
      expect(container.read(accountClosedNoticeProvider), isNull);
      expect(find.byType(AccountClosedScreen), findsNothing);
    });
  });

  group('the safety-net banner of Home', () {
    test('a plan that tells nobody is fixed in the editor once check-ins are '
        'on, and in the set-up step while the account is still setting up', () {
      expect(
        safetyNetGapPath(SafetyNetGap.noStages, checkInsOn: true),
        AppRoutes.planEdit,
      );
      expect(
        safetyNetGapPath(SafetyNetGap.stageEmpty, checkInsOn: true),
        AppRoutes.planEdit,
      );
      expect(
        safetyNetGapPath(SafetyNetGap.noStages, checkInsOn: false),
        OnboardingStep.plan.path,
      );
      expect(
        safetyNetGapPath(SafetyNetGap.stageEmpty, checkInsOn: false),
        OnboardingStep.plan.path,
      );
    });

    test('a missing contact is always fixed in the contact step', () {
      for (final on in [true, false]) {
        expect(
          safetyNetGapPath(SafetyNetGap.noContacts, checkInsOn: on),
          OnboardingStep.contact.path,
        );
      }
    });
  });
}
