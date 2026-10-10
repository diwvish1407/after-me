import 'package:afterme/app/repository_providers.dart';
import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/config/app_config.dart';
import 'package:afterme/features/checkin/data/dio_checkin_repository.dart';
import 'package:afterme/features/checkin/data/dio_schedule_repository.dart';
import 'package:afterme/features/contacts/data/dio_contacts_repository.dart';
import 'package:afterme/features/home/data/dio_home_repository.dart';
import 'package:afterme/features/instructions/data/in_memory_instructions_repository.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:afterme/features/plan/data/dio_plan_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/pump_app.dart';
import '../helpers/test_app.dart';

const _banner = 'Preview: your instructions are not saved yet';

void main() {
  group('release gate: temporary in-memory stand-ins', () {
    // Contacts are real since Phase 3, the schedule, check-ins and Home since Phase 4
    // and the plan since Phase 5. When Phase 6 replaces the instructions with the real
    // repository, remove it from this list. When the list is empty the preview notice
    // disappears by itself, and this group must be deleted. A prod build must never
    // claim a plan is complete while any stand-in remains, which is what the banner and
    // the wording below guarantee.
    test('contacts, schedule, check-ins and the plan are the real API; the '
        'instructions are still a stand-in', () {
      for (final config in [devConfig, prodConfig]) {
        final fakes = TestFakes()
          ..realContactsRepository = true
          ..realCheckInRepositories = true
          ..realPlanRepository = true;
        final container = ProviderContainer.test(
          overrides: testOverrides(config: config, fakes: fakes),
        );
        expect(
          container.read(contactsRepositoryProvider),
          isA<DioContactsRepository>(),
        );
        expect(
          container.read(scheduleRepositoryProvider),
          isA<DioScheduleRepository>(),
        );
        expect(
          container.read(checkInRepositoryProvider),
          isA<DioCheckInRepository>(),
        );
        expect(
          container.read(homeRepositoryProvider),
          isA<DioHomeRepository>(),
        );
        expect(
          container.read(planRepositoryProvider),
          isA<DioPlanRepository>(),
        );
        expect(
          container.read(instructionsRepositoryProvider),
          isA<InMemoryInstructionsRepository>(),
        );
      }
    });

    test(
      'while any stand-in is used, every environment is in preview mode',
      () {
        for (final env in AppEnv.values) {
          final config = switch (env) {
            AppEnv.dev => devConfig,
            AppEnv.staging || AppEnv.prod => prodConfig,
          };
          final container = ProviderContainer.test(
            overrides: testOverrides(config: config),
          );
          expect(container.read(previewModeProvider), isTrue, reason: '$env');
        }
      },
    );
  });

  group('the preview notice', () {
    testWidgets('a finished account sees it on Home, in a production build', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.prefs = freshPreferences({
        'afterme.onboardingUserId': 'user-1',
        'afterme.onboardingCompleted': true,
      });
      final container = await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedIn,
        config: prodConfig,
      );
      container.read(routerProvider).go(AppRoutes.home);
      await tester.pumpAndSettle();
      expect(find.textContaining(_banner), findsOneWidget);
    });

    testWidgets('the contact step does not show it: contacts are real', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.prefs = freshPreferences({
        'afterme.onboardingUserId': 'user-1',
        'afterme.onboardingCompleted': false,
        'afterme.onboardingStep': 'contact',
      });
      await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedIn,
        config: prodConfig,
      );
      expect(find.textContaining('Preview:'), findsNothing);
      expect(find.text('Save and continue'), findsOneWidget);
    });

    testWidgets('the done step shows it', (tester) async {
      final fakes = TestFakes();
      fakes.prefs = freshPreferences({
        'afterme.onboardingUserId': 'user-1',
        'afterme.onboardingCompleted': false,
        'afterme.onboardingStep': OnboardingStep.done.name,
      });
      await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedIn,
        config: prodConfig,
      );
      expect(find.textContaining(_banner), findsOneWidget);
    });

    testWidgets('the plan step does not show it: the plan is real', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.prefs = freshPreferences({
        'afterme.onboardingUserId': 'user-1',
        'afterme.onboardingCompleted': false,
        'afterme.onboardingStep': OnboardingStep.plan.name,
      });
      await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedIn,
        config: prodConfig,
      );
      expect(find.text('Your plan'), findsOneWidget);
      expect(find.textContaining('Preview:'), findsNothing);
    });

    testWidgets('the notice names only the instructions', (tester) async {
      final fakes = TestFakes();
      fakes.prefs = freshPreferences({
        'afterme.onboardingUserId': 'user-1',
        'afterme.onboardingCompleted': true,
      });
      await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedIn,
        config: prodConfig,
      );
      final text = tester.widget<Text>(find.textContaining('Preview:')).data!;
      expect(text, contains('instructions'));
      expect(text, isNot(contains('stages')));
      expect(text, contains('plan are real'));
    });
  });
}
