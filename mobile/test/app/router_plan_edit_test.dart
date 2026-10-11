import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:afterme/features/plan/presentation/plan_editor_screen.dart';
import 'package:afterme/features/plan/presentation/plan_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/contacts_harness.dart';

void main() {
  group('the plan editor route', () {
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

    test('is a fixed path under the Plan tab', () {
      expect(AppRoutes.planEdit, '/plan/edit');
      expect(AppRoutes.planEdit, startsWith(AppRoutes.plan));
      expect(AppRoutes.signedInRoutes(), contains(AppRoutes.planEdit));
      expect(AppRoutes.knownRoutes(isDev: false), contains(AppRoutes.planEdit));
    });

    test('only a signed-in person who finished onboarding can open it', () {
      expect(redirect(AuthStatus.signedIn, AppRoutes.planEdit), isNull);
      expect(
        redirect(AuthStatus.signedOut, AppRoutes.planEdit),
        AppRoutes.welcome,
      );
      expect(
        redirect(
          AuthStatus.signedIn,
          AppRoutes.planEdit,
          onboarding: const OnboardingState(
            loaded: true,
            completed: false,
            step: OnboardingStep.plan,
          ),
        ),
        OnboardingStep.plan.path,
      );
      expect(redirect(AuthStatus.signedIn, '/plan/edit/more'), AppRoutes.home);
      expect(redirect(AuthStatus.signedIn, '/plan/edit/'), AppRoutes.home);
    });
  });

  testWidgets('the editor is a page of the Plan tab: back returns to it', (
    tester,
  ) async {
    final container = await openApp(tester, route: AppRoutes.plan);
    container.read(routerProvider).go(AppRoutes.planEdit);
    await tester.pumpAndSettle();
    expect(find.byType(PlanEditorScreen), findsOneWidget);
    expect(find.text('Plan'), findsWidgets, reason: 'the tab bar stays');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(PlanScreen), findsOneWidget);
  });
}
