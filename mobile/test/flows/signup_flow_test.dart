import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';
import '../helpers/test_app.dart';

void main() {
  testWidgets('welcome -> create account -> code -> onboarding', (
    tester,
  ) async {
    final fakes = TestFakes();
    final store = InMemorySecureStore();
    final container = await pumpAfterMe(
      tester,
      fakes: fakes,
      secureStore: store,
    );

    await tapText(tester, 'Get started');
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

    expect(fakes.auth.calls, contains('registerStart'));
    expect(find.text('Enter your code'), findsOneWidget);

    await typeInto(tester, '6-digit code', '482 913');
    await tapText(tester, 'Confirm');
    await tester.pumpAndSettle();

    expect(container.read(authControllerProvider), AuthStatus.signedIn);
    expect(await store.read(SessionKeys.refreshToken), 'refresh-token');
    expect(
      find.text('Who should we tell if you don\'t check in?'),
      findsOneWidget,
    );
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('the whole onboarding, step by step, ends on Home', (
    tester,
  ) async {
    final fakes = TestFakes();
    final container = await pumpAfterMe(tester, fakes: fakes);
    // Sign in through the real controller, as sign-up does.
    await tapText(tester, 'I already have an account');
    await tester.pumpAndSettle();
    await typeInto(tester, 'Email', 'diwakar@example.com');
    await typeInto(tester, 'Password', 'correct horse battery');
    await tapText(tester, 'Sign in');
    await tester.pumpAndSettle();
    // A returning account has no onboarding to resume.
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Hello, Diwakar'), findsOneWidget);
    expect(find.text("Let's finish your plan"), findsOneWidget);

    // The checklist opens the same steps.
    await tapText(tester, 'Add');
    await tester.pumpAndSettle();
    await typeInto(tester, 'Their name', 'Mom');
    await tapText(tester, 'Parent');
    await typeInto(tester, 'Their email', 'mom@example.com');
    await tapText(tester, 'Save and continue');
    await tester.pumpAndSettle();
    // Opened from Home, a finished step returns to Home.
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(container.read(authControllerProvider), AuthStatus.signedIn);
  });
}
