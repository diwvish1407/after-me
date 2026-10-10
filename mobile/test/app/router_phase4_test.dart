import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/checkin/presentation/checkin_history_screen.dart';
import 'package:afterme/features/checkin/presentation/schedule_settings_screen.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/contacts_harness.dart';

void main() {
  const paths = [AppRoutes.settingsSchedule, AppRoutes.settingsCheckInHistory];

  group('check-in routes', () {
    test('are Settings screens, fixed paths, known only when signed in', () {
      for (final path in paths) {
        expect(AppRoutes.settingsScreens, contains(path));
        expect(path, startsWith('/settings/'));
        expect(AppRoutes.signedInRoutes(), contains(path));
        expect(AppRoutes.publicRoutes(isDev: true), isNot(contains(path)));
      }
    });

    test('signed out goes to the welcome screen', () {
      for (final path in paths) {
        expect(
          authRedirect(
            status: AuthStatus.signedOut,
            location: path,
            isDev: false,
          ),
          AppRoutes.welcome,
          reason: path,
        );
      }
    });

    test('unfinished onboarding resumes at its step', () {
      for (final path in paths) {
        expect(
          authRedirect(
            status: AuthStatus.signedIn,
            location: path,
            isDev: false,
            onboarding: const OnboardingState(
              loaded: true,
              completed: false,
              step: OnboardingStep.plan,
            ),
          ),
          OnboardingStep.plan.path,
          reason: path,
        );
      }
    });

    test('signed in and done may open them', () {
      for (final path in paths) {
        expect(
          authRedirect(
            status: AuthStatus.signedIn,
            location: path,
            isDev: false,
          ),
          isNull,
          reason: path,
        );
      }
    });

    test('a query string never selects them', () {
      expect(
        authRedirect(
          status: AuthStatus.signedIn,
          location: '/settings/check-in-schedule/extra',
          isDev: false,
        ),
        AppRoutes.home,
      );
    });
  });

  testWidgets('the router builds both screens inside Settings', (tester) async {
    final container = await openApp(tester, route: AppRoutes.settingsSchedule);
    expect(find.byType(ScheduleSettingsScreen), findsOneWidget);
    container.read(routerProvider).go(AppRoutes.settingsCheckInHistory);
    await tester.pumpAndSettle();
    expect(find.byType(CheckInHistoryScreen), findsOneWidget);
  });
}
