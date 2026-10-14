import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

/// Review D-33: a contact's name, address and phone number are a third party's. The screens
/// that show or edit them (add, detail, edit, and onboarding's first contact) keep the
/// window `FLAG_SECURE` while they are on screen (nothing in screenshots or the app
/// switcher); the People list, which shows names and statuses only, does not.
TestFakes _fakes() => TestFakes()
  ..contacts = InMemoryContactsRepository(
    tier: 'premium',
    initial: [testContact()],
  );

void main() {
  testWidgets('the People list does not hold it', (tester) async {
    final fakes = _fakes();
    await openApp(tester, fakes: fakes, route: AppRoutes.people);
    expect(find.text('Mom'), findsWidgets);
    expect(fakes.secureScreen.calls, isEmpty);
  });

  testWidgets('add, detail and edit hold it, and the list lets go', (
    tester,
  ) async {
    final fakes = _fakes();
    final container = await openApp(
      tester,
      fakes: fakes,
      route: AppRoutes.people,
    );
    final router = container.read(routerProvider);

    router.go(AppRoutes.peopleAdd);
    await tester.pumpAndSettle();
    expect(find.text('Add a trusted contact'), findsOneWidget);
    expect(fakes.secureScreen.secure, isTrue, reason: 'add contact');

    router.go(AppRoutes.people);
    await tester.pumpAndSettle();
    expect(fakes.secureScreen.secure, isFalse, reason: 'the list');

    router.go(AppRoutes.contactDetail('c1'));
    await tester.pumpAndSettle();
    expect(find.text('Mom'), findsWidgets);
    expect(fakes.secureScreen.secure, isTrue, reason: 'contact detail');

    await tapText(tester, 'Edit');
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsOneWidget);
    expect(fakes.secureScreen.secure, isTrue, reason: 'edit contact');

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(fakes.secureScreen.secure, isFalse, reason: 'back on the list');
  });

  testWidgets('the first contact of onboarding is typed in a secure window', (
    tester,
  ) async {
    final fakes = TestFakes();
    fakes.prefs = freshPreferences({
      'afterme.onboardingUserId': 'user-1',
      'afterme.onboardingCompleted': false,
      'afterme.onboardingStep': OnboardingStep.contact.name,
    });
    await pumpAfterMe(tester, fakes: fakes, status: AuthStatus.signedIn);
    expect(find.text('Save and continue'), findsOneWidget);
    expect(fakes.secureScreen.secure, isTrue);
  });
}
