import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/instructions/data/instructions_repository.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

/// FR-INS-06: every screen that shows or edits instruction content keeps the window
/// `FLAG_SECURE` (no screenshots, nothing in the app switcher) while it is on screen, and
/// lets go of it when the person leaves that area. The fake gateway records what the
/// screens asked of the window.
TestFakes _fakes() {
  final fakes = TestFakes()
    ..contacts = InMemoryContactsRepository(
      tier: 'premium',
      initial: [testContact()],
    );
  fakes.plan.seed(
    const PlanDraft(
      graceMinutes: 180,
      stages: [
        PlanStageDraft(offsetMinutes: 180, contactIds: ['c1']),
        PlanStageDraft(offsetMinutes: 1440, contactIds: ['c1']),
      ],
    ),
  );
  fakes.instructions.seed(
    title: 'House emergency',
    category: InstructionCategory.home,
    recipients: {'c1': fakes.plan.stages.last.id},
  );
  return fakes;
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Home, People, Plan and Settings never set it', (tester) async {
    final fakes = _fakes();
    final container = await openApp(
      tester,
      fakes: fakes,
      route: AppRoutes.home,
    );
    for (final route in [
      AppRoutes.people,
      AppRoutes.plan,
      AppRoutes.settings,
      AppRoutes.home,
    ]) {
      container.read(routerProvider).go(route);
      await tester.pumpAndSettle();
    }
    expect(fakes.secureScreen.calls, isEmpty);
  });

  testWidgets('the Instructions tab sets it on enter and clears it when the '
      'person goes to another tab', (tester) async {
    final fakes = _fakes();
    await openApp(tester, fakes: fakes, route: AppRoutes.home);
    expect(fakes.secureScreen.secure, isFalse);

    await _tab(tester, 'Instructions');
    expect(find.text('House emergency'), findsOneWidget);
    expect(fakes.secureScreen.secure, isTrue);

    // The shell keeps the tab built but not shown: the flag goes with the tab.
    await _tab(tester, 'Home');
    expect(fakes.secureScreen.secure, isFalse);
    expect(fakes.secureScreen.calls, [true, false]);

    await _tab(tester, 'Instructions');
    expect(fakes.secureScreen.secure, isTrue);
  });

  testWidgets('list, detail, edit and back again: held all the way, cleared '
      'at the end', (tester) async {
    final fakes = _fakes();
    await openApp(tester, fakes: fakes, route: AppRoutes.instructions);
    expect(fakes.secureScreen.secure, isTrue);

    await tapText(tester, 'House emergency');
    await tester.pumpAndSettle();
    expect(fakes.secureScreen.secure, isTrue);

    await tapText(tester, 'Edit');
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsOneWidget);
    expect(fakes.secureScreen.secure, isTrue);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('House emergency'), findsOneWidget);
    expect(
      fakes.secureScreen.secure,
      isTrue,
      reason: 'the list is still showing titles',
    );
    expect(fakes.secureScreen.calls, [
      true,
    ], reason: 'a page on top of another never cleared it for the one below');

    await _tab(tester, 'People');
    expect(fakes.secureScreen.secure, isFalse);
  });

  testWidgets('a page replaced by another instruction page keeps it, and '
      'going Home clears it', (tester) async {
    final fakes = _fakes();
    final container = await openApp(
      tester,
      fakes: fakes,
      route: AppRoutes.instructionNew,
    );
    expect(fakes.secureScreen.secure, isTrue);
    final router = container.read(routerProvider);

    router.go(AppRoutes.instructionDetail('instruction-1'));
    await tester.pumpAndSettle();
    expect(find.text('House emergency'), findsWidgets);
    expect(fakes.secureScreen.calls, [
      true,
    ], reason: 'never cleared in between');

    router.go(AppRoutes.home);
    await tester.pumpAndSettle();
    expect(fakes.secureScreen.secure, isFalse);
    expect(fakes.secureScreen.calls, [true, false]);
  });

  testWidgets('the create screen, opened on top of the list, holds it until it '
      'is closed and the tab is left', (tester) async {
    final fakes = _fakes();
    await openApp(tester, fakes: fakes, route: AppRoutes.instructions);
    await tapText(tester, 'Add instruction');
    await tester.pumpAndSettle();
    expect(fakes.secureScreen.secure, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(fakes.secureScreen.secure, isTrue);
    await _tab(tester, 'Plan');
    expect(fakes.secureScreen.secure, isFalse);
  });

  testWidgets('signing out while an instruction is open clears it', (
    tester,
  ) async {
    final fakes = _fakes();
    final container = await openApp(
      tester,
      fakes: fakes,
      route: AppRoutes.instructionDetail('instruction-1'),
    );
    expect(fakes.secureScreen.secure, isTrue);
    (container.read(authControllerProvider.notifier) as FixedAuthController)
        .set(AuthStatus.signedOut);
    await tester.pumpAndSettle();
    expect(fakes.secureScreen.secure, isFalse);
  });

  group('onboarding step 7', () {
    Future<TestFakes> atStep(WidgetTester tester) async {
      final fakes = _fakes();
      fakes.prefs = freshPreferences({
        'afterme.onboardingUserId': 'user-1',
        'afterme.onboardingCompleted': false,
        'afterme.onboardingStep': OnboardingStep.instruction.name,
      });
      await pumpAfterMe(tester, fakes: fakes, status: AuthStatus.signedIn);
      return fakes;
    }

    testWidgets('an instruction that is already saved is shown by its title, '
        'so the page is secure too', (tester) async {
      final fakes = await atStep(tester);
      expect(find.textContaining('Saved: House emergency'), findsOneWidget);
      expect(fakes.secureScreen.secure, isTrue);
    });

    testWidgets('writing the first one holds it; skipping clears it', (
      tester,
    ) async {
      final fakes = TestFakes()
        ..contacts = InMemoryContactsRepository(initial: [testContact()]);
      fakes.prefs = freshPreferences({
        'afterme.onboardingUserId': 'user-1',
        'afterme.onboardingCompleted': false,
        'afterme.onboardingStep': OnboardingStep.instruction.name,
      });
      await pumpAfterMe(tester, fakes: fakes, status: AuthStatus.signedIn);
      expect(find.text('Write your own'), findsOneWidget);
      expect(fakes.secureScreen.calls, isEmpty);

      await tapText(tester, 'Pets');
      await tester.pumpAndSettle();
      expect(fakes.secureScreen.secure, isTrue);

      await tapText(tester, 'Skip for now');
      await tester.pumpAndSettle();
      expect(find.text('Stay protected'), findsOneWidget);
      expect(fakes.secureScreen.secure, isFalse);
    });
  });
}
