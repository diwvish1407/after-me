import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:afterme/features/incidents/presentation/incident_detail_screen.dart';
import 'package:afterme/features/incidents/presentation/incident_history_screen.dart';
import 'package:afterme/features/incidents/presentation/incident_timeline_screen.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/contacts_harness.dart';

void main() {
  group('incident routes', () {
    String? redirect(
      AuthStatus status,
      String location, {
      OnboardingState onboarding = const OnboardingState(loaded: true),
    }) => authRedirect(
      status: status,
      location: location,
      isDev: false,
      onboarding: onboarding,
    );

    test('path helpers build fixed, encoded paths', () {
      expect(AppRoutes.homeIncident, '/home/incident');
      expect(AppRoutes.settingsIncidents, '/settings/incidents');
      expect(AppRoutes.incidentDetail('i1'), '/settings/incidents/i1');
      expect(
        AppRoutes.incidentDetail('a b/c'),
        '/settings/incidents/a%20b%2Fc',
      );
    });

    test('only well-formed incident paths are incident routes', () {
      for (final path in [
        '/settings/incidents/i1',
        '/settings/incidents/00000000-0000-4000-8000-000000000004',
      ]) {
        expect(AppRoutes.isIncidentRoute(path), isTrue, reason: path);
      }
      for (final path in [
        '/settings/incidents',
        '/settings/incidents/',
        '/settings/incidents/i1/edit',
        '/settings/incidents/a b',
        '/settings/incidents/..%2Fhome',
        '/settings/incidents/${'x' * 65}',
        '/settings/incidents/i1?next=/home',
        '/incidents/i1',
      ]) {
        expect(AppRoutes.isIncidentRoute(path), isFalse, reason: path);
      }
    });

    test('signed in with onboarding done may open them; anything else goes '
        'Home', () {
      for (final path in [
        AppRoutes.homeIncident,
        AppRoutes.settingsIncidents,
        '/settings/incidents/i1',
      ]) {
        expect(redirect(AuthStatus.signedIn, path), isNull, reason: path);
      }
      for (final path in [
        '/home/incident/more',
        '/settings/incidents/i1/edit',
        '/settings/incidents/',
      ]) {
        expect(
          redirect(AuthStatus.signedIn, path),
          AppRoutes.home,
          reason: path,
        );
      }
    });

    test('signed out and mid-onboarding people cannot open them', () {
      for (final path in [
        AppRoutes.homeIncident,
        AppRoutes.settingsIncidents,
        '/settings/incidents/i1',
      ]) {
        expect(redirect(AuthStatus.signedOut, path), AppRoutes.welcome);
        expect(
          redirect(
            AuthStatus.signedIn,
            path,
            onboarding: const OnboardingState(
              loaded: true,
              completed: false,
              step: OnboardingStep.plan,
            ),
          ),
          OnboardingStep.plan.path,
        );
      }
    });
  });

  group('incident screens', () {
    testWidgets('the timeline is a page of the Home tab', (tester) async {
      final container = await openApp(tester, route: AppRoutes.home);
      container.read(routerProvider).go(AppRoutes.homeIncident);
      await tester.pumpAndSettle();
      expect(find.byType(IncidentTimelineScreen), findsOneWidget);
      expect(find.text('Home'), findsWidgets, reason: 'the tab bar stays');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('the list and an incident are pages of Settings', (
      tester,
    ) async {
      final container = await openApp(
        tester,
        route: AppRoutes.settingsIncidents,
      );
      expect(find.byType(IncidentHistoryScreen), findsOneWidget);
      container.read(routerProvider).go(AppRoutes.incidentDetail('some-id'));
      await tester.pumpAndSettle();
      expect(find.byType(IncidentDetailScreen), findsOneWidget);
      expect(find.byType(IncidentHistoryScreen), findsNothing);
    });
  });
}
