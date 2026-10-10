import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/design_system/design_system.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

/// The plan step when it is opened again by an account whose check-ins are on (from the
/// Plan tab, or the Home banner): a plan that really changes needs the password
/// (SECURITY.md §7, 403 `reauth_required`), the sheet says why, and the very same save
/// is sent again once. During onboarding nothing is asked.

const _reason =
    'Changing your plan needs your password because it decides who is told.';

/// Check-ins are on and Mom is told after 3 hours.
TestFakes _active() {
  final fakes = TestFakes();
  fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
  fakes.plan.seedStandard(['c1']);
  fakes.server.activateNow();
  return fakes;
}

Future<void> _openPlanStep(WidgetTester tester, TestFakes fakes) async {
  await openApp(tester, fakes: fakes, route: OnboardingStep.plan.path);
  expect(find.text('Your plan'), findsOneWidget);
}

/// A few frames. `pumpAndSettle` cannot be used while the primary button shows its busy
/// spinner behind the password sheet: an indeterminate indicator never settles.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

int _puts(TestFakes fakes) => fakes.plan.calls.where((c) => c == 'save').length;

int _reauths(TestFakes fakes) =>
    fakes.auth.calls.where((c) => c == 'reauth').length;

/// Chooses 6 hours (a real change) and taps "Use this plan".
Future<void> _changeAndSave(WidgetTester tester) async {
  await tapText(tester, '6 hours');
  await tapText(tester, 'Use this plan');
  await _frames(tester);
}

void main() {
  group('Plan step while check-ins are on', () {
    testWidgets('a changed plan asks for the password, says why, then saves '
        'the same plan once', (tester) async {
      final fakes = _active();
      await _openPlanStep(tester, fakes);

      await _changeAndSave(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(find.text(_reason), findsOneWidget);
      expect(
        find.text('For your security, enter your password to continue.'),
        findsNothing,
        reason: 'the context-specific line replaces the generic one',
      );
      expect(_puts(fakes), 1);
      expect(fakes.plan.graceMinutes, 180, reason: 'nothing saved yet');

      await typeInto(tester, 'Password', fakes.auth.password);
      await tapText(tester, 'Confirm');
      await _frames(tester);
      await tester.pumpAndSettle();

      expect(find.text("Confirm it's you"), findsNothing);
      expect(_puts(fakes), 2);
      expect(fakes.plan.ifMatches, [
        '"plan-2"',
        '"plan-2"',
      ], reason: 'the same If-Match');
      expect(fakes.plan.saved[0], fakes.plan.saved[1], reason: 'the same body');
      expect(fakes.plan.graceMinutes, 360);
      expect(_reauths(fakes), 1);
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('closing the sheet changes nothing, sends nothing again and '
        'says nothing', (tester) async {
      final fakes = _active();
      await _openPlanStep(tester, fakes);
      await _changeAndSave(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await _frames(tester);

      expect(find.text("Confirm it's you"), findsNothing);
      expect(_puts(fakes), 1, reason: 'the save is not repeated');
      expect(_reauths(fakes), 0);
      expect(fakes.plan.graceMinutes, 180);
      expect(find.byType(FailureNotice), findsNothing);
      expect(find.text('Your plan'), findsOneWidget, reason: 'still here');
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '6 hours'))
            .selected,
        isTrue,
        reason: 'the choice is still there',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Use this plan'),
            )
            .onPressed,
        isNotNull,
        reason: 'not stuck busy',
      );

      // Trying again deliberately asks again, and then goes through.
      await tapText(tester, 'Use this plan');
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
      await typeInto(tester, 'Password', fakes.auth.password);
      await tapText(tester, 'Confirm');
      await _frames(tester);
      await tester.pumpAndSettle();
      expect(fakes.plan.graceMinutes, 360);
      expect(_puts(fakes), 3);
    });

    testWidgets('a wrong password stays in the sheet with the message the '
        'schedule uses, and sends nothing', (tester) async {
      final fakes = _active();
      await _openPlanStep(tester, fakes);
      await _changeAndSave(tester);

      await typeInto(tester, 'Password', 'not the password');
      await tapText(tester, 'Confirm');
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(
        find.text("That password didn't match. Try again."),
        findsOneWidget,
      );
      expect(_puts(fakes), 1, reason: 'the save is not repeated');
      expect(fakes.plan.graceMinutes, 180);
      expect(find.byType(FailureNotice), findsNothing);

      await typeInto(tester, 'Password', fakes.auth.password);
      await tapText(tester, 'Confirm');
      await _frames(tester);
      await tester.pumpAndSettle();
      expect(_puts(fakes), 2);
      expect(fakes.plan.graceMinutes, 360);
    });

    testWidgets('with a recent password no sheet is needed', (tester) async {
      final fakes = _active();
      fakes.auth.reauthenticated = true;
      await _openPlanStep(tester, fakes);
      await _changeAndSave(tester);
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(_puts(fakes), 1);
      expect(fakes.plan.graceMinutes, 360);
      expect(_reauths(fakes), 0);
    });

    testWidgets('the same plan again is not a change: no password', (
      tester,
    ) async {
      final fakes = _active();
      await _openPlanStep(tester, fakes);
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(_puts(fakes), 1);
      expect(fakes.plan.version, 2, reason: 'nothing was saved');
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('a plan changed elsewhere meanwhile (412) is said as that, not '
        'as a password problem', (tester) async {
      final fakes = _active();
      await _openPlanStep(tester, fakes);
      // The password is asked for, and while the sheet is open the server's plan moved.
      fakes.plan.failures['save'] = [
        const ForbiddenFailure(code: 'reauth_required'),
        const ConflictFailure(code: 'precondition_failed'),
      ];
      await _changeAndSave(tester);
      await typeInto(tester, 'Password', fakes.auth.password);
      await tapText(tester, 'Confirm');
      await _frames(tester);
      await tester.pumpAndSettle();

      expect(find.text("Confirm it's you"), findsNothing);
      expect(find.textContaining('was changed somewhere else'), findsOneWidget);
      expect(find.text('Your plan'), findsOneWidget);
    });

    testWidgets('the Plan tab leads an account with no stages here, and saving '
        'asks for the password', (tester) async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      fakes.server.activateNow();
      await openApp(tester, fakes: fakes, route: AppRoutes.plan);
      await tapText(tester, 'Set up your plan');
      await tester.pumpAndSettle();
      expect(find.text('Your plan'), findsOneWidget);

      await tapText(tester, 'Use this plan');
      await _frames(tester);
      expect(find.text(_reason), findsOneWidget);
      await typeInto(tester, 'Password', fakes.auth.password);
      await tapText(tester, 'Confirm');
      await _frames(tester);
      await tester.pumpAndSettle();

      expect(fakes.plan.stages.single.contactIds, ['c1']);
      expect(find.byType(HomeScreen), findsOneWidget);
    });
  });

  group('Plan step during onboarding', () {
    Future<TestFakes> atPlanStep(
      WidgetTester tester, {
      bool saved = false,
    }) async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      if (saved) {
        fakes.plan.seedStandard(['c1']);
      }
      fakes.prefs = freshPreferences({
        'afterme.onboardingUserId': 'user-1',
        'afterme.onboardingCompleted': false,
        'afterme.onboardingStep': OnboardingStep.plan.name,
      });
      await pumpAfterMe(tester, fakes: fakes, status: AuthStatus.signedIn);
      return fakes;
    }

    testWidgets('saving the plan never asks for the password', (tester) async {
      final fakes = await atPlanStep(tester);
      expect(fakes.server.status, CheckInStatus.inactive);

      await tapText(tester, '6 hours');
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();

      expect(find.text("Confirm it's you"), findsNothing);
      expect(_reauths(fakes), 0);
      expect(_puts(fakes), 1);
      expect(fakes.plan.graceMinutes, 360);
      expect(find.text('Add a first instruction'), findsOneWidget);
    });

    testWidgets('changing a plan that was saved earlier in onboarding never '
        'asks either', (tester) async {
      final fakes = await atPlanStep(tester, saved: true);
      await tapText(tester, '12 hours');
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(_reauths(fakes), 0);
      expect(fakes.plan.graceMinutes, 720);
    });
  });
}
