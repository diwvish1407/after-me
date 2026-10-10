import 'dart:async';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/instructions/presentation/add_instruction_screen.dart';
import 'package:afterme/features/instructions/presentation/edit_instruction_screen.dart';
import 'package:afterme/features/instructions/presentation/instruction_detail_screen.dart';
import 'package:afterme/features/instructions/presentation/instructions_screen.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/contacts_harness.dart';

void main() {
  group('instruction routes', () {
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
      expect(AppRoutes.instructions, '/instructions');
      expect(AppRoutes.instructionNew, '/instructions/new');
      expect(AppRoutes.instructionDetail('i1'), '/instructions/i1');
      expect(AppRoutes.instructionEdit('i1'), '/instructions/i1/edit');
      expect(AppRoutes.instructionDetail('a b/c'), '/instructions/a%20b%2Fc');
    });

    test('only well-formed instruction paths are instruction routes', () {
      for (final path in [
        '/instructions/new',
        '/instructions/i1',
        '/instructions/6f1c2a52-8d3b-4a6e-9a43-0c1d5e7b9a10',
        '/instructions/i1/edit',
      ]) {
        expect(AppRoutes.isInstructionRoute(path), isTrue, reason: path);
      }
      for (final path in [
        '/instructions',
        '/instructions/',
        '/instructions/i1/edit/extra',
        '/instructions/i1/delete',
        '/instructions/a b',
        '/instructions/..%2Fhome',
        '/instructions/${'x' * 65}',
        '/instructions//edit',
        '/instructions/i1?next=/home',
      ]) {
        expect(AppRoutes.isInstructionRoute(path), isFalse, reason: path);
      }
    });

    test('signed in with onboarding done may open them; anything else goes '
        'Home', () {
      for (final path in [
        '/instructions',
        '/instructions/new',
        '/instructions/i1',
        '/instructions/i1/edit',
      ]) {
        expect(redirect(AuthStatus.signedIn, path), isNull, reason: path);
      }
      for (final path in [
        '/instructions/i1/edit/more',
        '/instructions/',
        '/instructions/a b',
      ]) {
        expect(
          redirect(AuthStatus.signedIn, path),
          AppRoutes.home,
          reason: path,
        );
      }
    });

    test('signed out and mid-onboarding people cannot open them', () {
      for (final path in ['/instructions/new', '/instructions/i1']) {
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

  group('instruction screens', () {
    testWidgets('new is not read as an id, and the stack unwinds', (
      tester,
    ) async {
      final container = await openApp(tester, route: AppRoutes.instructions);
      unawaited(container.read(routerProvider).push(AppRoutes.instructionNew));
      await tester.pumpAndSettle();
      expect(find.byType(AddInstructionScreen), findsOneWidget);
      expect(find.byType(InstructionDetailScreen), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(InstructionsScreen), findsOneWidget);
    });

    testWidgets('an example name is the only `extra` that is read', (
      tester,
    ) async {
      final container = await openApp(tester, route: AppRoutes.instructions);
      final router = container.read(routerProvider);
      // Anything else (a name that is not an example, or a value that is not a
      // string) opens a blank form.
      for (final extra in <Object>['nothing', 42]) {
        unawaited(router.push(AppRoutes.instructionNew, extra: extra));
        await tester.pumpAndSettle();
        expect(find.byType(AddInstructionScreen), findsOneWidget);
        expect(find.text('Start from an example'), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
      unawaited(router.push(AppRoutes.instructionNew, extra: 'petsCare'));
      await tester.pumpAndSettle();
      final title = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Title'),
      );
      expect(title.controller!.text, 'Pets');
    });

    testWidgets('detail then edit, then back twice to the list', (
      tester,
    ) async {
      final container = await openApp(tester, route: AppRoutes.instructions);
      unawaited(
        container.read(routerProvider).push(AppRoutes.instructionDetail('i1')),
      );
      await tester.pumpAndSettle();
      unawaited(
        container.read(routerProvider).push(AppRoutes.instructionEdit('i1')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(EditInstructionScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(InstructionDetailScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(InstructionsScreen), findsOneWidget);
    });
  });
}
