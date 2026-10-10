import 'package:afterme/app/repository_providers.dart';
import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/checkin/data/dio_checkin_repository.dart';
import 'package:afterme/features/checkin/data/dio_schedule_repository.dart';
import 'package:afterme/features/contacts/data/dio_contacts_repository.dart';
import 'package:afterme/features/home/data/dio_home_repository.dart';
import 'package:afterme/features/instructions/data/dio_instructions_repository.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:afterme/features/plan/data/dio_plan_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';
import '../helpers/test_app.dart';

void main() {
  group('release gate: no temporary stand-in is left', () {
    // Contacts are real since Phase 3, the schedule, check-ins and Home since Phase 4,
    // the plan since Phase 5 and the instructions since Phase 6. If a repository is ever
    // replaced by an in-memory stand-in again, this list is where it must be named, and
    // the screens' preview wording (which no longer exists) has to come back with it.
    test('every repository is the real API', () {
      for (final config in [devConfig, prodConfig]) {
        final fakes = TestFakes()
          ..realContactsRepository = true
          ..realCheckInRepositories = true
          ..realPlanRepository = true
          ..realInstructionsRepository = true;
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
          isA<DioInstructionsRepository>(),
        );
      }
    });
  });

  group('no preview notice in a production build', () {
    for (final step in [
      OnboardingStep.contact,
      OnboardingStep.plan,
      OnboardingStep.instruction,
      OnboardingStep.done,
    ]) {
      testWidgets('onboarding step ${step.name}', (tester) async {
        final fakes = TestFakes();
        fakes.prefs = freshPreferences({
          'afterme.onboardingUserId': 'user-1',
          'afterme.onboardingCompleted': false,
          'afterme.onboardingStep': step.name,
        });
        await pumpAfterMe(
          tester,
          fakes: fakes,
          status: AuthStatus.signedIn,
          config: prodConfig,
        );
        expect(find.textContaining('Preview'), findsNothing);
        expect(find.textContaining('not saved yet'), findsNothing);
        expect(find.textContaining('still a preview'), findsNothing);
      });
    }

    testWidgets('Home of a finished account', (tester) async {
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
      expect(find.textContaining('Preview'), findsNothing);
      expect(find.textContaining('not saved yet'), findsNothing);
    });
  });
}
