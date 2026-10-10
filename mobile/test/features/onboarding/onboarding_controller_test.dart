import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:afterme/features/checkin/data/schedule_repository.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/instructions/data/instructions_repository.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:afterme/features/onboarding/application/setup_controller.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/test_app.dart';

ProviderContainer _container(TestFakes fakes) {
  final container = ProviderContainer.test(
    retry: (retryCount, error) => null,
    overrides: testOverrides(fakes: fakes),
  );
  container.listen(onboardingControllerProvider, (_, _) {});
  return container;
}

void main() {
  group('OnboardingController', () {
    test('with nothing saved there is nothing to resume', () async {
      final container = _container(TestFakes());
      final controller = container.read(onboardingControllerProvider.notifier);
      expect(container.read(onboardingControllerProvider).loaded, isFalse);
      await controller.loaded;
      final state = container.read(onboardingControllerProvider);
      expect(state.loaded, isTrue);
      expect(state.needsOnboarding, isFalse);
    });

    test('progress is saved after every step', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      final controller = container.read(onboardingControllerProvider.notifier);
      await controller.beginForNewAccount('user-1');

      for (final step in OnboardingStep.values.take(5)) {
        await controller.completeStep(step);
        final next = step.next!;
        expect(container.read(onboardingControllerProvider).step, next);
        expect(
          await fakes.prefs.getString(PreferenceKey.onboardingStep),
          next.name,
        );
        expect(
          await fakes.prefs.getBool(PreferenceKey.onboardingCompleted),
          isFalse,
        );
      }
      await controller.completeStep(OnboardingStep.done);
      expect(container.read(onboardingControllerProvider).completed, isTrue);
      expect(
        await fakes.prefs.getBool(PreferenceKey.onboardingCompleted),
        isTrue,
      );
    });

    test(
      'completing an earlier step never lowers the saved progress',
      () async {
        final fakes = TestFakes();
        final container = _container(fakes);
        final controller = container.read(
          onboardingControllerProvider.notifier,
        );
        await controller.beginForNewAccount('user-1');
        await controller.completeStep(OnboardingStep.contact);
        await controller.completeStep(OnboardingStep.schedule);
        expect(
          container.read(onboardingControllerProvider).step,
          OnboardingStep.plan,
        );

        // A detour: the contact step again, from the plan step.
        await controller.completeStep(OnboardingStep.contact);
        expect(
          container.read(onboardingControllerProvider).step,
          OnboardingStep.plan,
        );
        expect(
          await fakes.prefs.getString(PreferenceKey.onboardingStep),
          'plan',
        );
      },
    );

    test('is restored on the next launch at the saved step', () async {
      final first = TestFakes();
      final c1 = _container(first);
      final controller = c1.read(onboardingControllerProvider.notifier);
      await controller.beginForNewAccount('user-1');
      await controller.completeStep(OnboardingStep.contact);
      await controller.completeStep(OnboardingStep.schedule);

      // "Relaunch": a new container over the same stored preferences.
      final second = TestFakes()..prefs = first.prefs;
      final c2 = _container(second);
      await c2.read(onboardingControllerProvider.notifier).loaded;
      final state = c2.read(onboardingControllerProvider);
      expect(state.needsOnboarding, isTrue);
      expect(state.step, OnboardingStep.plan);
    });

    test('a finished onboarding is not resumed', () async {
      final first = TestFakes();
      final c1 = _container(first);
      final controller = c1.read(onboardingControllerProvider.notifier);
      await controller.beginForNewAccount('user-1');
      await controller.finish();
      final second = TestFakes()..prefs = first.prefs;
      final c2 = _container(second);
      await c2.read(onboardingControllerProvider.notifier).loaded;
      expect(c2.read(onboardingControllerProvider).needsOnboarding, isFalse);
    });

    test(
      'completing a step after onboarding is over changes nothing',
      () async {
        final container = _container(TestFakes());
        final controller = container.read(
          onboardingControllerProvider.notifier,
        );
        await controller.loaded;
        await controller.completeStep(OnboardingStep.contact);
        expect(container.read(onboardingControllerProvider).completed, isTrue);
        expect(
          container.read(onboardingControllerProvider).step,
          OnboardingStep.contact,
        );
      },
    );

    test('the same account resumes after signing in again', () async {
      final first = TestFakes();
      final c1 = _container(first);
      final controller = c1.read(onboardingControllerProvider.notifier);
      await controller.beginForNewAccount('user-1');
      await controller.completeStep(OnboardingStep.contact);

      final second = TestFakes()..prefs = first.prefs;
      final c2 = _container(second);
      await c2
          .read(onboardingControllerProvider.notifier)
          .accountSignedIn('user-1');
      expect(c2.read(onboardingControllerProvider).needsOnboarding, isTrue);
      expect(
        c2.read(onboardingControllerProvider).step,
        OnboardingStep.schedule,
      );
    });

    test(
      "a different account does not inherit someone else's progress",
      () async {
        final first = TestFakes();
        final c1 = _container(first);
        await c1
            .read(onboardingControllerProvider.notifier)
            .beginForNewAccount('user-1');

        final second = TestFakes()..prefs = first.prefs;
        final c2 = _container(second);
        await c2
            .read(onboardingControllerProvider.notifier)
            .accountSignedIn('user-2');
        expect(c2.read(onboardingControllerProvider).needsOnboarding, isFalse);
        expect(
          await second.prefs.getString(PreferenceKey.onboardingUserId),
          'user-2',
        );
      },
    );

    test('step order, paths and parsing', () {
      expect(OnboardingStep.values.map((s) => s.name), [
        'contact',
        'schedule',
        'plan',
        'instruction',
        'protect',
        'done',
      ]);
      expect(OnboardingStep.done.next, isNull);
      expect(OnboardingStep.contact.next, OnboardingStep.schedule);
      expect(OnboardingStep.tryParse('plan'), OnboardingStep.plan);
      expect(OnboardingStep.tryParse('bogus'), isNull);
      expect(OnboardingStep.tryParse(null), isNull);
      for (final step in OnboardingStep.values) {
        expect(step.path, startsWith('/onboarding/'));
      }
      const a = OnboardingState(loaded: true, completed: false);
      expect(a, const OnboardingState(loaded: true, completed: false));
      expect(
        a.hashCode,
        const OnboardingState(loaded: true, completed: false).hashCode,
      );
      expect(a.copyWith(step: OnboardingStep.plan), isNot(a));
    });
  });

  group('SetupController (check-in and plan APIs, in-memory instructions)', () {
    ProviderContainer signedIn([TestFakes? fakes]) {
      final container = ProviderContainer.test(
        retry: (retryCount, error) => null,
        overrides: testOverrides(
          authStatus: AuthStatus.signedIn,
          fakes: fakes ?? TestFakes(),
        ),
      );
      container.listen(setupControllerProvider, (_, _) {});
      return container;
    }

    Future<SetupState> state(ProviderContainer c) =>
        c.read(setupControllerProvider.future);

    test(
      'starts with the server defaults: no contact, check-ins off',
      () async {
        final s = await state(signedIn());
        expect(s.hasContact, isFalse);
        expect(
          s.hasSchedule,
          isTrue,
          reason: 'the server always has a schedule',
        );
        expect(s.schedule, const CheckInSchedule(timezone: 'Asia/Kolkata'));
        expect(s.scheduleActive, isFalse);
        expect(s.hasPlan, isFalse);
        expect(s.complete, isFalse);
      },
    );

    test(
      'saving sends the schedule with the ETag it was loaded with',
      () async {
        final fakes = TestFakes();
        final container = signedIn(fakes);
        await state(container);
        final c = container.read(setupControllerProvider.notifier);

        await c.saveSchedule(
          const CheckInSchedule(
            intervalDays: 2,
            dueMinutes: 21 * 60 + 30,
            reminderLeadMinutes: 30,
            timezone: 'Asia/Kolkata',
          ),
        );
        expect(fakes.server.ifMatches, ['"sched-1"']);
        expect(fakes.server.version, 2);
        final s = await state(container);
        expect(s.schedule!.intervalDays, 2);
        expect(s.schedule!.dueMinutes, 21 * 60 + 30);
        expect(s.snapshot!.version, 2);

        // The next save uses the new ETag.
        await c.saveSchedule(s.schedule!.copyWith(intervalDays: 3));
        expect(fakes.server.ifMatches, ['"sched-1"', '"sched-2"']);
      },
    );

    test(
      'activation is the server\'s decision and says what is missing',
      () async {
        final fakes = TestFakes();
        final container = signedIn(fakes);
        await state(container);
        final c = container.read(setupControllerProvider.notifier);

        var outcome = await c.activate();
        expect(outcome.activated, isFalse);
        expect(outcome.missing, ['no_contacts', 'no_stages']);
        expect((await state(container)).scheduleActive, isFalse);

        final contact = await c.addContact(
          const ContactDraft(
            name: ' Mom ',
            relationship: ContactRelationship.parent,
            email: 'mom@example.com',
          ),
        );
        expect(contact.displayName, 'Mom');
        expect(contact.relationship, ContactRelationship.parent);
        expect(contact.verificationStatus, VerificationStatus.pending);

        // A plan with a stage that tells someone is a requirement: the server decides.
        expect((await state(container)).hasPlan, isFalse);
        outcome = await c.activate();
        expect(outcome.missing, ['no_stages']);

        await c.savePlan(PlanPresets.standard([contact]));
        var s = await state(container);
        expect(s.complete, isTrue);
        expect(s.plan!.graceMinutes, 180);
        expect(s.plan!.version, 2);

        outcome = await c.activate();
        expect(outcome.activated, isTrue);
        expect(outcome.missing, isEmpty);
        s = await state(container);
        expect(s.scheduleActive, isTrue);
        expect(s.snapshot!.nextDueAt, isNotNull);
      },
    );

    test('unknown requirement codes are kept; an empty list still says '
        'something is missing', () async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      fakes.server.extraRequirements = ['something_new'];
      final container = signedIn(fakes);
      await state(container);
      final c = container.read(setupControllerProvider.notifier);
      expect((await c.activate()).missing, ['no_stages', 'something_new']);

      fakes.server.failures['activate'] = [
        const ActivationRequirementsFailure(),
      ];
      expect((await c.activate()).missing, ['unknown']);
    });

    test('other activation failures are thrown', () async {
      final fakes = TestFakes();
      fakes.server.failures['activate'] = [const NetworkFailure()];
      final container = signedIn(fakes);
      await state(container);
      await expectLater(
        container.read(setupControllerProvider.notifier).activate(),
        throwsA(isA<NetworkFailure>()),
      );
    });

    test('a plan that notifies nobody does not count', () async {
      final container = signedIn();
      await state(container);
      final c = container.read(setupControllerProvider.notifier);
      await c.savePlan(PlanPresets.standard(const []));
      final s = await state(container);
      expect(s.plan!.stages, hasLength(1), reason: 'the server saved it');
      expect(s.hasPlan, isFalse);
    });

    test('a plan is saved with the version it was loaded with and the '
        'next save uses the new one', () async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      final container = signedIn(fakes);
      final s = await state(container);
      expect(s.plan!.stages, isEmpty, reason: 'a new account has no stages');
      expect(s.plan!.ifMatch, '"plan-1"');
      final c = container.read(setupControllerProvider.notifier);

      await c.savePlan(PlanPresets.standard(s.contacts));
      await c.savePlan(
        PlanPresets.standard(
          s.contacts,
          current: (await state(container)).plan,
        ),
      );
      expect(fakes.plan.ifMatches, ['"plan-1"', '"plan-2"']);
      expect(
        fakes.plan.version,
        2,
        reason: 'the second body changed nothing, so there is no new version',
      );
    });

    test('a stale plan (412) is read again and thrown', () async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      final container = signedIn(fakes);
      final s = await state(container);
      fakes.plan.seedStandard(['c1'], offsetMinutes: 360);

      final c = container.read(setupControllerProvider.notifier);
      await expectLater(
        c.savePlan(PlanPresets.standard(s.contacts)),
        throwsA(
          isA<ConflictFailure>().having(
            (f) => f.code,
            'code',
            'precondition_failed',
          ),
        ),
      );
      final now = (await state(container)).plan!;
      expect(now.version, 2);
      expect(now.graceMinutes, 360, reason: 'the latest, not the draft');
    });

    test('refresh reads the plan again', () async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      final container = signedIn(fakes);
      await state(container);
      fakes.plan.seedStandard(['c1']);
      await container.read(setupControllerProvider.notifier).refresh();
      expect((await state(container)).hasPlan, isTrue);
    });

    test('instructions keep a summary but not the body', () async {
      final container = signedIn();
      await state(container);
      final c = container.read(setupControllerProvider.notifier);
      await c.createInstruction(
        const InstructionDraft(
          title: ' Keys ',
          body: 'the spare key is under the third pot',
          releaseAfterHours: 48,
          recipientContactIds: ['a'],
          template: InstructionTemplate.homeAndKeys,
        ),
      );
      final s = await state(container);
      expect(s.instructions.single.title, 'Keys');
      expect(s.instructions.single.releaseAfterHours, 48);
    });

    test('refresh re-reads and signing out empties everything', () async {
      final container = signedIn();
      await state(container);
      final c = container.read(setupControllerProvider.notifier);
      await c.addContact(
        const ContactDraft(
          name: 'Mom',
          relationship: ContactRelationship.parent,
          email: 'mom@example.com',
        ),
      );
      await c.refresh();
      expect((await state(container)).hasContact, isTrue);

      // The repositories are rebuilt whenever the sign-in status changes.
      (container.read(authControllerProvider.notifier) as FixedAuthController)
          .set(AuthStatus.signedOut);
      expect((await state(container)).hasContact, isFalse);
    });

    test('repository failures surface as errors', () async {
      final container = ProviderContainer.test(
        retry: (retryCount, error) => null,
        overrides: testOverrides(
          authStatus: AuthStatus.signedIn,
          fakes: TestFakes()..contacts = _BrokenContacts(),
        ),
      );
      container.listen(setupControllerProvider, (_, _) {});
      await expectLater(
        container.read(setupControllerProvider.future),
        throwsA(isA<Object>()),
      );
    });

    test('value types behave', () async {
      final container = signedIn();
      await state(container);
      expect(
        const CheckInSchedule().copyWith(intervalDays: 2),
        const CheckInSchedule(intervalDays: 2),
      );
      expect(
        const CheckInSchedule().hashCode,
        const CheckInSchedule().hashCode,
      );
      final contact = testContact();
      expect(contact, testContact());
      expect(contact.hashCode, contact.hashCode);
    });
  });
}

class _BrokenContacts extends InMemoryContactsRepository {
  @override
  Future<List<TrustedContact>> list() async => throw StateError('x');
}
