import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
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

    await tapText(tester, 'Skip');
    await tester.pumpAndSettle();
    await typeInto(tester, 'Your name', 'Diwakar');
    await typeInto(tester, 'Email', 'new@example.com');
    await typeInto(tester, 'Password', 'A long unique phrase 1!');
    await typeInto(tester, 'Confirm password', 'A long unique phrase 1!');
    await tapText(tester, 'I am 18 or older.');
    await tapText(
      tester,
      'I agree to the Terms of Service and the Privacy Policy.',
    );
    await tapText(tester, 'Continue');
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
    await tapText(tester, 'Sign in');
    await tester.pumpAndSettle();
    await typeInto(tester, 'Email', 'diwakar@example.com');
    await typeInto(tester, 'Password', 'correct horse battery');
    await tapText(tester, 'Sign in');
    await tester.pumpAndSettle();
    // A returning account has no onboarding to resume.
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(
      find.textContaining(
        RegExp(r'^Good (morning|afternoon|evening), Diwakar$'),
      ),
      findsOneWidget,
    );

    // The checklist opens the same steps.
    await tapText(tester, 'Add');
    await tester.pumpAndSettle();
    await typeInto(tester, 'Name', 'Mom');
    await pickDropdown<ContactRelationship>(tester, 'Mother');
    await typeInto(tester, 'Email', 'mom@example.com');
    await tapText(tester, 'Continue');
    await tester.pumpAndSettle();
    // Opened from Home, a finished step returns to Home.
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(container.read(authControllerProvider), AuthStatus.signedIn);
  });
}
