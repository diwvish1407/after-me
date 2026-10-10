import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/contacts/application/contacts_controller.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/home/application/home_controller.dart';
import 'package:afterme/features/home/data/models/home_models.dart';
import 'package:afterme/features/plan/application/plan_controller.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/test_app.dart';

ProviderContainer _container(
  TestFakes fakes, {
  AuthStatus status = AuthStatus.signedIn,
}) {
  final container = ProviderContainer.test(
    retry: (retryCount, error) => null,
    overrides: testOverrides(authStatus: status, fakes: fakes),
  );
  container.listen(planControllerProvider, (_, _) {});
  return container;
}

PlanController _controller(ProviderContainer c) =>
    c.read(planControllerProvider.notifier);

Plan? _plan(ProviderContainer c) => c.read(planControllerProvider).value;

TestFakes _withContacts({String tier = 'free'}) => TestFakes()
  ..contacts = InMemoryContactsRepository(
    tier: tier,
    initial: [
      testContact(),
      testContact(id: 'c2', name: 'Sam', email: 'sam@example.com', priority: 2),
    ],
  );

PlanDraft _draft({
  int grace = 180,
  List<String> contacts = const ['c1'],
  String? id,
}) => PlanDraft(
  graceMinutes: grace,
  stages: [PlanStageDraft(id: id, offsetMinutes: grace, contactIds: contacts)],
);

void main() {
  group('PlanController', () {
    test(
      'loads the plan the server has: no stages, the tier\'s rules',
      () async {
        final fakes = _withContacts();
        final container = _container(fakes);
        final plan = (await container.read(planControllerProvider.future))!;
        expect(plan.stages, isEmpty);
        expect(plan.graceMinutes, 180);
        expect(plan.version, 1);
        expect(plan.ifMatch, '"plan-1"');
        expect(plan.rules.customOffsets, isFalse);
        expect(plan.rules.maxStages, 2);
        expect(fakes.plan.calls, ['get']);
      },
    );

    test('a premium account has custom offsets and ten stages', () async {
      final container = _container(_withContacts(tier: 'premium'));
      final rules = (await container.read(planControllerProvider.future))!
          .rules;
      expect(rules.customOffsets, isTrue);
      expect(rules.maxStages, 10);
    });

    test('signing out drops the plan', () async {
      final fakes = _withContacts();
      fakes.plan.seedStandard(['c1']);
      final container = _container(fakes);
      expect(_plan(container), isNull);
      await container.read(planControllerProvider.future);
      expect(_plan(container)!.stages, hasLength(1));

      // The repository is rebuilt whenever the sign-in status changes.
      (container.read(authControllerProvider.notifier) as FixedAuthController)
          .set(AuthStatus.signedOut);
      expect(await container.read(planControllerProvider.future), isNull);
    });

    test('signed out: nothing is read', () async {
      final fakes = _withContacts();
      final container = _container(fakes, status: AuthStatus.signedOut);
      expect(await container.read(planControllerProvider.future), isNull);
      expect(fakes.plan.calls, isEmpty);
    });

    test('save sends the version on hand and keeps the answer; the next '
        'save uses the new version', () async {
      final fakes = _withContacts();
      final container = _container(fakes);
      await container.read(planControllerProvider.future);

      final saved = await _controller(container).save(_draft());
      expect(fakes.plan.ifMatches, ['"plan-1"']);
      expect(saved.version, 2);
      expect(saved.stages.single.contactIds, ['c1']);
      expect(saved.stages.single.position, 1);
      expect(_plan(container), saved);

      final again = await _controller(container).save(
        _draft(
          grace: 360,
          contacts: const ['c1', 'c2'],
          id: saved.stages.single.id,
        ),
      );
      expect(fakes.plan.ifMatches, ['"plan-1"', '"plan-2"']);
      expect(again.version, 3);
      expect(again.graceMinutes, 360);
      expect(again.stages.single.id, saved.stages.single.id, reason: 'kept');
    });

    test('saving what is already saved changes nothing', () async {
      final fakes = _withContacts();
      final container = _container(fakes);
      await container.read(planControllerProvider.future);
      final first = await _controller(container).save(_draft());
      final second = await _controller(container).save(first.toDraft());
      expect(second.version, first.version);
      expect(fakes.plan.version, 2);
    });

    test('a save without a plan on hand reads it first', () async {
      final fakes = _withContacts();
      fakes.plan.failures['get'] = [const NetworkFailure()];
      final container = _container(fakes);
      await expectLater(
        container.read(planControllerProvider.future),
        throwsA(isA<NetworkFailure>()),
      );
      expect(_plan(container), isNull);

      final saved = await _controller(container).save(_draft());
      expect(fakes.plan.calls, ['get', 'get', 'save']);
      expect(fakes.plan.ifMatches, ['"plan-1"']);
      expect(saved.version, 2);
    });

    test('a stale save (412) reads the latest plan and says so', () async {
      final fakes = _withContacts();
      final container = _container(fakes);
      await container.read(planControllerProvider.future);
      // Changed from another device meanwhile.
      fakes.plan.seedStandard(['c2'], offsetMinutes: 720);

      await expectLater(
        _controller(container).save(_draft()),
        throwsA(
          isA<ConflictFailure>().having(
            (f) => f.code,
            'code',
            'precondition_failed',
          ),
        ),
      );
      final now = _plan(container)!;
      expect(now.version, 2);
      expect(now.graceMinutes, 720, reason: 'the latest, not the draft');
      expect(now.stages.single.contactIds, ['c2']);

      // Saving again with what is now on screen works.
      final saved = await _controller(container).save(
        _draft(grace: 360, contacts: const ['c2'], id: now.stages.single.id),
      );
      expect(fakes.plan.ifMatches, ['"plan-1"', '"plan-2"']);
      expect(saved.version, 3);
    });

    test('428 is handled like 412: the plan is read again', () async {
      final fakes = _withContacts();
      fakes.plan.failures['save'] = [
        const ConflictFailure(code: 'precondition_required'),
      ];
      final container = _container(fakes);
      await container.read(planControllerProvider.future);
      await expectLater(
        _controller(container).save(_draft()),
        throwsA(isA<ConflictFailure>()),
      );
      expect(fakes.plan.calls, ['get', 'save', 'get']);
    });

    test('a contact that is gone (404) reads the contacts and the plan again '
        'and rethrows', () async {
      final fakes = _withContacts();
      final container = _container(fakes)
        ..listen(contactsControllerProvider, (_, _) {});
      await container.read(planControllerProvider.future);
      await container.read(contactsControllerProvider.future);
      final contactCalls = fakes.contacts.calls.length;

      await expectLater(
        _controller(container).save(_draft(contacts: const ['ghost'])),
        throwsA(isA<NotFoundFailure>()),
      );
      expect(fakes.contacts.calls.length, greaterThan(contactCalls));
      expect(fakes.contacts.calls.last, 'list');
      expect(fakes.plan.calls, ['get', 'save', 'get']);
      expect(_plan(container)!.version, 1);
    });

    test('what the server refuses is rethrown and the plan stays as it '
        'was', () async {
      final fakes = _withContacts();
      final container = _container(fakes);
      final before = (await container.read(planControllerProvider.future))!;

      // Stage 1 must end the grace period.
      await expectLater(
        _controller(container).save(
          const PlanDraft(
            graceMinutes: 180,
            stages: [
              PlanStageDraft(offsetMinutes: 360, contactIds: ['c1']),
            ],
          ),
        ),
        throwsA(
          isA<ValidationFailure>().having(
            (f) => [for (final e in f.fieldErrors) '${e.field} ${e.code}'],
            'errors',
            ['stages[0].offset_minutes must_equal_grace'],
          ),
        ),
      );
      // A free account chooses from the presets only.
      await expectLater(
        _controller(container).save(_draft(grace: 90)),
        throwsA(
          isA<ValidationFailure>().having(
            (f) => f.fieldErrors.first.field,
            'field',
            'grace_minutes',
          ),
        ),
      );
      // Two stages at most.
      await expectLater(
        _controller(container).save(
          const PlanDraft(
            graceMinutes: 180,
            stages: [
              PlanStageDraft(offsetMinutes: 180, contactIds: ['c1']),
              PlanStageDraft(offsetMinutes: 360, contactIds: ['c1']),
              PlanStageDraft(offsetMinutes: 720, contactIds: ['c1']),
            ],
          ),
        ),
        throwsA(
          isA<PlanLimitFailure>()
              .having((f) => f.resource, 'resource', 'stages')
              .having((f) => f.limit, 'limit', 2),
        ),
      );
      expect(_plan(container), before);
    });

    test('a premium account may choose any grace in range', () async {
      final container = _container(_withContacts(tier: 'premium'));
      await container.read(planControllerProvider.future);
      final saved = await _controller(container).save(_draft(grace: 90));
      expect(saved.graceMinutes, 90);
    });

    test('an open incident refuses the change (409)', () async {
      final fakes = _withContacts();
      fakes.server.openIncident();
      final container = _container(fakes);
      await container.read(planControllerProvider.future);
      await expectLater(
        _controller(container).save(_draft()),
        throwsA(
          isA<ConflictFailure>().having((f) => f.code, 'code', 'incident_open'),
        ),
      );
      expect(_plan(container)!.version, 1);
    });

    test('a failed refresh keeps the plan on screen; reload returns the '
        'failure', () async {
      final fakes = _withContacts();
      final container = _container(fakes);
      await container.read(planControllerProvider.future);
      fakes.plan.failures['get'] = [const NetworkFailure()];
      expect(await _controller(container).reload(), isA<NetworkFailure>());
      expect(_plan(container), isNotNull);

      fakes.plan.seedStandard(['c1']);
      expect(await _controller(container).reload(), isNull);
      expect(_plan(container)!.stages, hasLength(1));
    });

    test(
      'a first read that failed becomes an error, and reload recovers',
      () async {
        final fakes = _withContacts();
        fakes.plan.failures['get'] = [const ServerFailure()];
        final container = _container(fakes);
        await expectLater(
          container.read(planControllerProvider.future),
          throwsA(isA<ServerFailure>()),
        );
        expect(container.read(planControllerProvider).hasError, isTrue);
        expect(await _controller(container).reload(), isNull);
        expect(_plan(container)!.version, 1);
      },
    );

    test('removing a contact reads the plan again, so a later save never '
        'names someone who is gone', () async {
      final fakes = _withContacts();
      fakes.plan.seedStandard(['c1', 'c2']);
      final container = _container(fakes)
        ..listen(contactsControllerProvider, (_, _) {});
      await container.read(planControllerProvider.future);
      await container.read(contactsControllerProvider.future);
      expect(_plan(container)!.stages.single.contactIds, ['c1', 'c2']);

      fakes.plan.forgetContact('c2');
      await container
          .read(contactsControllerProvider.notifier)
          .removeContact('c2');
      await pumpEventQueue();

      expect(_plan(container)!.stages.single.contactIds, ['c1']);
      // Renaming a contact changes nothing in the plan: no needless read.
      final reads = fakes.plan.calls.where((c) => c == 'get').length;
      await container
          .read(contactsControllerProvider.notifier)
          .updateContact('c1', const ContactPatch(name: 'Mum'));
      await pumpEventQueue();
      expect(fakes.plan.calls.where((c) => c == 'get'), hasLength(reads));
    });
  });

  group(
    'Step-up: a changed plan while check-ins are on needs the password',
    () {
      /// An account whose check-ins are on, with a one-stage plan for Mom.
      Future<(TestFakes, ProviderContainer)> active({
        String tier = 'free',
      }) async {
        final fakes = _withContacts(tier: tier);
        fakes.plan.seedStandard(['c1']);
        fakes.server.activateNow();
        final container = _container(fakes);
        await container.read(planControllerProvider.future);
        return (fakes, container);
      }

      Matcher reauthRequired() => isA<ForbiddenFailure>().having(
        (f) => f.code,
        'code',
        'reauth_required',
      );

      test('a real change is refused with reauth_required; nothing changes and '
          'the same call works after re-authenticating', () async {
        final (fakes, container) = await active();
        final before = _plan(container)!;
        // Both contacts are told now: a real change.
        final change = _draft(
          contacts: const ['c1', 'c2'],
          id: before.stages.single.id,
        );

        await expectLater(
          _controller(container).save(change),
          throwsA(reauthRequired()),
        );
        expect(fakes.plan.version, before.version, reason: 'not saved');
        expect(_plan(container), before, reason: 'the snapshot is untouched');
        expect(
          fakes.plan.calls.where((c) => c == 'get'),
          hasLength(1),
          reason: 'nothing was read again: it is not a conflict',
        );

        fakes.auth.reauthenticated = true;
        final saved = await _controller(container).save(change);
        expect(saved.stages.single.contactIds, ['c1', 'c2']);
        expect(saved.version, before.version + 1);
        expect(fakes.plan.ifMatches, [
          before.ifMatch,
          before.ifMatch,
        ], reason: 'the retry is the very same request');
        expect(fakes.plan.saved[0], fakes.plan.saved[1]);
      });

      test('the same body again is not a change: no password', () async {
        final (fakes, container) = await active();
        final before = _plan(container)!;
        final saved = await _controller(container).save(before.toDraft());
        expect(saved.version, before.version);
        expect(fakes.auth.reauthenticated, isFalse);
      });

      test('emptying the only stage is a change like any other', () async {
        final (fakes, container) = await active();
        await expectLater(
          _controller(container).save(
            _draft(contacts: const [], id: _plan(container)!.stages.single.id),
          ),
          throwsA(reauthRequired()),
          reason: 'a stage that tells nobody weakens the net',
        );
        expect(fakes.plan.stages.single.contactIds, ['c1']);
      });

      test('a changed delay is a change', () async {
        final (fakes, container) = await active();
        final before = _plan(container)!;
        await expectLater(
          _controller(container)
              .save(_draft(grace: 360, id: before.stages.single.id)),
          throwsA(reauthRequired()),
        );
        expect(fakes.plan.graceMinutes, 180);
      });

      test('while check-ins are off (onboarding) nothing asks', () async {
        final fakes = _withContacts();
        fakes.plan.seedStandard(['c1']);
        final container = _container(fakes);
        final before = (await container.read(planControllerProvider.future))!;
        final saved = await _controller(container).save(
          _draft(contacts: const ['c1', 'c2'], id: before.stages.single.id),
        );
        expect(saved.stages.single.contactIds, ['c1', 'c2']);
        expect(fakes.server.status, CheckInStatus.inactive);
      });

      test(
        'a password given recently is enough for the next change too',
        () async {
          final (fakes, container) = await active(tier: 'premium');
          fakes.auth.reauthenticated = true;
          final first = await _controller(container)
              .save(_draft(grace: 360, id: _plan(container)!.stages.single.id));
          final second = await _controller(container).save(
            _draft(
              grace: 720,
              contacts: const ['c1', 'c2'],
              id: first.stages.single.id,
            ),
          );
          expect(second.version, first.version + 1);
        },
      );

      test(
        'is answered after the stale version, the incident, the stranger and '
        'the validation, like the server',
        () async {
          final (fakes, container) = await active();
          final before = _plan(container)!;
          final id = before.stages.single.id;

          // A contact that is not yours: 404, not the password.
          await expectLater(
            _controller(container)
                .save(_draft(contacts: const ['ghost'], id: id)),
            throwsA(isA<NotFoundFailure>()),
          );
          // A field that is wrong: 422.
          await expectLater(
            _controller(container).save(_draft(grace: 90, id: id)),
            throwsA(isA<ValidationFailure>()),
          );
          // Changed on another device: 412.
          fakes.plan.seedStandard(['c1'], offsetMinutes: 720);
          await expectLater(
            _controller(container).save(_draft(contacts: const ['c2'], id: id)),
            throwsA(
              isA<ConflictFailure>().having(
                (f) => f.code,
                'code',
                'precondition_failed',
              ),
            ),
          );
          // An open incident: 409.
          fakes.server.openIncident();
          await expectLater(
            _controller(container).save(_draft(contacts: const ['c2'], id: id)),
            throwsA(
              isA<ConflictFailure>().having(
                (f) => f.code,
                'code',
                'incident_open',
              ),
            ),
          );
        },
      );
    },
  );

  group('Home follows the plan', () {
    ProviderContainer homeContainer(TestFakes fakes) {
      final container = _container(fakes)
        ..listen(homeControllerProvider, (_, _) {});
      return container;
    }

    int homeReads(TestFakes fakes) =>
        fakes.server.calls.where((c) => c == 'home').length;

    test(
      'a saved plan refreshes the aggregate: stages and readiness',
      () async {
        final fakes = _withContacts();
        final container = homeContainer(fakes);
        final before = (await container.read(homeControllerProvider.future))!;
        await container.read(planControllerProvider.future);
        expect(before.snapshot.planSummary.stages, 0);
        expect(
          before.snapshot.readiness.issues.map((i) => i.code),
          contains(ReadinessCode.noStages),
        );
        final reads = homeReads(fakes);

        await _controller(container).save(_draft());
        await pumpEventQueue();

        expect(homeReads(fakes), reads + 1);
        final home = container.read(homeControllerProvider).value!;
        expect(home.snapshot.planSummary.stages, 1);
        expect(
          home.snapshot.readiness.issues.map((i) => i.code),
          isNot(contains(ReadinessCode.noStages)),
        );
      },
    );

    test('a plan that tells nobody is a readiness issue of its own', () async {
      final fakes = _withContacts();
      final container = homeContainer(fakes);
      await container.read(homeControllerProvider.future);
      await container.read(planControllerProvider.future);

      await _controller(container).save(_draft(contacts: const []));
      await pumpEventQueue();

      final issues = container
          .read(homeControllerProvider)
          .value!
          .snapshot
          .readiness
          .issues
          .map((i) => i.code);
      expect(issues, contains(ReadinessCode.stageEmpty));
      expect(issues, isNot(contains(ReadinessCode.noStages)));
    });

    test('a save that changes nothing does not read Home again', () async {
      final fakes = _withContacts();
      fakes.plan.seedStandard(['c1']);
      final container = homeContainer(fakes);
      await container.read(homeControllerProvider.future);
      final plan = (await container.read(planControllerProvider.future))!;
      final reads = homeReads(fakes);

      await _controller(container).save(plan.toDraft());
      await pumpEventQueue();
      expect(homeReads(fakes), reads);
    });

    test('a plan read again after a conflict refreshes it too', () async {
      final fakes = _withContacts();
      final container = homeContainer(fakes);
      await container.read(homeControllerProvider.future);
      await container.read(planControllerProvider.future);
      final reads = homeReads(fakes);

      fakes.plan.seedStandard(['c1']);
      await expectLater(
        _controller(container).save(_draft()),
        throwsA(isA<ConflictFailure>()),
      );
      await pumpEventQueue();
      expect(homeReads(fakes), reads + 1);
      expect(
        container
            .read(homeControllerProvider)
            .value!
            .snapshot
            .planSummary
            .stages,
        1,
      );
    });
  });
}
