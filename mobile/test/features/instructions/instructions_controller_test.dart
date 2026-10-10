import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/contacts/application/contacts_controller.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/instructions/application/instruction_autosave.dart';
import 'package:afterme/features/instructions/application/instructions_controller.dart';
import 'package:afterme/features/instructions/application/release_stages.dart';
import 'package:afterme/features/instructions/data/instructions_repository.dart';
import 'package:afterme/features/plan/application/plan_controller.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/plan_fixtures.dart';
import '../../helpers/test_app.dart';

TestFakes _fakes({String tier = 'premium'}) {
  final fakes = TestFakes()
    ..contacts = InMemoryContactsRepository(
      tier: tier,
      initial: [
        testContact(),
        testContact(id: 'c2', name: 'Dad', email: 'dad@example.com'),
      ],
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
  return fakes;
}

ProviderContainer _container(
  TestFakes fakes, {
  AuthStatus status = AuthStatus.signedIn,
}) {
  final container = ProviderContainer.test(
    retry: (retryCount, error) => null,
    overrides: testOverrides(authStatus: status, fakes: fakes),
  );
  container.listen(instructionsControllerProvider, (_, _) {});
  return container;
}

Future<List<InstructionSummary>> _items(ProviderContainer c) =>
    c.read(instructionsControllerProvider.future);

InstructionDraft _draft(
  TestFakes fakes, {
  String title = 'House emergency',
  String body = 'The spare key is with a neighbour.',
  List<String> contacts = const ['c1'],
}) => InstructionDraft(
  category: InstructionCategory.home,
  title: title,
  body: body,
  recipients: [
    for (final id in contacts)
      RecipientDraft(contactId: id, releaseStageId: fakes.plan.stages.last.id),
  ],
);

void main() {
  group('reading', () {
    test('the list is the summaries, newest change first', () async {
      final fakes = _fakes();
      fakes.instructions
        ..seed(title: 'Oldest')
        ..seed(title: 'Middle')
        ..seed(title: 'Newest');
      final container = _container(fakes);
      final items = await _items(container);
      expect([for (final i in items) i.title], ['Newest', 'Middle', 'Oldest']);
      expect(fakes.instructions.calls, ['list']);
    });

    test('signed out there is nothing, and nothing is asked', () async {
      final fakes = _fakes()..instructions.seed(title: 'Hidden');
      final container = _container(fakes, status: AuthStatus.signedOut);
      expect(await _items(container), isEmpty);
      expect(fakes.instructions.calls, isEmpty);
    });

    test('a failure is the state; reload recovers and keeps what is shown '
        'when it fails', () async {
      final fakes = _fakes()..instructions.seed(title: 'Keys');
      fakes.instructions.failures['list'] = [const NetworkFailure()];
      final container = _container(fakes);
      await expectLater(_items(container), throwsA(isA<NetworkFailure>()));
      expect(
        container.read(instructionsControllerProvider).error,
        isA<NetworkFailure>(),
      );
      final controller = container.read(
        instructionsControllerProvider.notifier,
      );
      expect(await controller.reload(), isNull);
      expect((await _items(container)).single.title, 'Keys');

      fakes.instructions.failures['list'] = [const NetworkFailure()];
      final failure = await controller.reload();
      expect(failure, isA<NetworkFailure>());
      expect(
        container.read(instructionsControllerProvider).value!.single.title,
        'Keys',
        reason: 'what was on screen stays',
      );
    });

    test('a failed first read can be retried through reload', () async {
      final fakes = _fakes();
      fakes.instructions.failures['list'] = [
        const NetworkFailure(),
        const NetworkFailure(),
      ];
      final container = _container(fakes);
      await expectLater(_items(container), throwsA(isA<NetworkFailure>()));
      final failure = await container
          .read(instructionsControllerProvider.notifier)
          .reload();
      expect(failure, isA<NetworkFailure>());
      expect(
        container.read(instructionsControllerProvider).error,
        isA<NetworkFailure>(),
        reason: 'with nothing to show the failure stays the state',
      );
    });

    test('sorting is stable and puts what has no time last', () {
      InstructionSummary item(String id, DateTime? at) => InstructionSummary(
        id: id,
        title: id,
        category: InstructionCategory.home,
        status: InstructionStatus.active,
        updatedAt: at,
      );
      final sorted = sortInstructions([
        item('a', null),
        item('b', DateTime.utc(2026, 10, 8)),
        item('c', DateTime.utc(2026, 10, 9)),
        item('d', DateTime.utc(2026, 10, 9)),
      ]);
      expect([for (final i in sorted) i.id], ['c', 'd', 'b', 'a']);
    });
  });

  group('changing', () {
    test(
      'adding returns the whole instruction and keeps only the summary',
      () async {
        final fakes = _fakes()..instructions.seed(title: 'Older');
        final container = _container(fakes);
        await _items(container);
        final created = await container
            .read(instructionsControllerProvider.notifier)
            .addInstruction(_draft(fakes));
        expect(created.body, 'The spare key is with a neighbour.');
        final items = container.read(instructionsControllerProvider).value!;
        expect([for (final i in items) i.title], ['House emergency', 'Older']);
        expect(items.first.recipients.single.displayName, 'Mom');
        expect(items.first.recipients.single.stagePosition, 2);
        expect(items.first.toString(), isNot(contains('House emergency')));
      },
    );

    test('usage and the plan are read again after a change', () async {
      final fakes = _fakes();
      final container = _container(fakes);
      await _items(container);
      final plan = await container.read(planControllerProvider.future);
      expect(plan!.stages.last.releaseCount, 0);
      final entitlements = await container.read(entitlementsProvider.future);
      expect(entitlements.usage.instructions, 0);

      await container
          .read(instructionsControllerProvider.notifier)
          .addInstruction(_draft(fakes));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final after = container.read(planControllerProvider).value!;
      expect(after.stages.last.releaseCount, 1);
      expect(
        (await container.read(entitlementsProvider.future)).usage.instructions,
        1,
      );
    });

    test(
      'a refused instruction changes nothing and is thrown as it came',
      () async {
        final fakes = _fakes();
        final container = _container(fakes);
        await _items(container);
        final controller = container.read(
          instructionsControllerProvider.notifier,
        );
        await expectLater(
          controller.addInstruction(_draft(fakes, title: '')),
          throwsA(
            isA<ValidationFailure>().having(
              (f) => f.fieldErrors.single.field,
              'field',
              'title',
            ),
          ),
        );
        expect(container.read(instructionsControllerProvider).value, isEmpty);
      },
    );

    test('at the free limit the server says so', () async {
      final fakes = _fakes(tier: 'free');
      for (var i = 0; i < 3; i++) {
        fakes.instructions.seed(title: 'N$i');
      }
      final container = _container(fakes);
      await _items(container);
      await expectLater(
        container
            .read(instructionsControllerProvider.notifier)
            .addInstruction(_draft(fakes)),
        throwsA(
          isA<PlanLimitFailure>()
              .having((f) => f.resource, 'resource', 'instructions')
              .having((f) => f.limit, 'limit', 3),
        ),
      );
      expect(
        container.read(instructionsControllerProvider).value,
        hasLength(3),
      );
    });

    test('somebody who is gone (404) reads the contacts, the plan and the '
        'list again, and is thrown', () async {
      final fakes = _fakes();
      final container = _container(fakes);
      await _items(container);
      await container.read(contactsControllerProvider.future);
      final listsBefore = fakes.contacts.calls.where((c) => c == 'list').length;
      await expectLater(
        container
            .read(instructionsControllerProvider.notifier)
            .addInstruction(
              InstructionDraft(
                category: InstructionCategory.home,
                title: 't',
                body: 'b',
                recipients: [
                  RecipientDraft(
                    contactId: 'ghost',
                    releaseStageId: fakes.plan.stages.last.id,
                  ),
                ],
              ),
            ),
        throwsA(isA<NotFoundFailure>()),
      );
      expect(
        fakes.contacts.calls.where((c) => c == 'list').length,
        greaterThan(listsBefore),
      );
      expect(fakes.instructions.calls.where((c) => c == 'list').length, 2);
    });

    test('an update replaces the summary and moves it to the top', () async {
      final fakes = _fakes();
      final firstId = fakes.instructions.seed(title: 'First');
      fakes.instructions.seed(title: 'Second');
      final container = _container(fakes);
      await _items(container);
      final updated = await container
          .read(instructionsControllerProvider.notifier)
          .updateInstruction(
            firstId,
            const InstructionPatch(
              title: 'First, changed',
              status: InstructionStatus.inactive,
            ),
          );
      expect(updated.title, 'First, changed');
      final items = container.read(instructionsControllerProvider).value!;
      expect([for (final i in items) i.title], ['First, changed', 'Second']);
      expect(items.first.isActive, isFalse);
    });

    test('an update of one that is gone reloads and is thrown', () async {
      final fakes = _fakes()..instructions.seed(title: 'Only');
      final container = _container(fakes);
      await _items(container);
      await expectLater(
        container
            .read(instructionsControllerProvider.notifier)
            .updateInstruction(
              'instruction-x',
              const InstructionPatch(title: 't'),
            ),
        throwsA(isA<NotFoundFailure>()),
      );
      expect(fakes.instructions.calls.where((c) => c == 'list').length, 2);
    });

    test('removing takes it out of the list and the server', () async {
      final fakes = _fakes();
      final id = fakes.instructions.seed(title: 'Gone');
      fakes.instructions.seed(title: 'Stays');
      final container = _container(fakes);
      await _items(container);
      await container
          .read(instructionsControllerProvider.notifier)
          .removeInstruction(id);
      expect(
        [
          for (final i in container.read(instructionsControllerProvider).value!)
            i.title,
        ],
        ['Stays'],
      );
      expect(fakes.instructions.liveCount, 1);
    });

    test('removing one that is already gone reloads and is thrown', () async {
      final fakes = _fakes()..instructions.seed(title: 'Stays');
      final container = _container(fakes);
      await _items(container);
      await expectLater(
        container
            .read(instructionsControllerProvider.notifier)
            .removeInstruction('instruction-x'),
        throwsA(isA<NotFoundFailure>()),
      );
      expect(
        container.read(instructionsControllerProvider).value,
        hasLength(1),
      );
    });

    test('a failed removal leaves the list as it was', () async {
      final fakes = _fakes();
      final id = fakes.instructions.seed(title: 'Stays');
      fakes.instructions.failures['delete'] = [const NetworkFailure()];
      final container = _container(fakes);
      await _items(container);
      await expectLater(
        container
            .read(instructionsControllerProvider.notifier)
            .removeInstruction(id),
        throwsA(isA<NetworkFailure>()),
      );
      expect(
        container.read(instructionsControllerProvider).value,
        hasLength(1),
      );
    });
  });

  group('following the contacts and the plan', () {
    test('a removed or renamed contact reads the list again; a new one '
        'does not', () async {
      final fakes = _fakes();
      fakes.instructions.seed(
        title: 'For both',
        recipients: {
          'c1': fakes.plan.stages.last.id,
          'c2': fakes.plan.stages.last.id,
        },
      );
      final container = _container(fakes);
      expect(
        (await _items(container)).single.recipients.map((r) => r.displayName),
        ['Dad', 'Mom'],
      );
      final contacts = container.read(contactsControllerProvider.notifier);
      await container.read(contactsControllerProvider.future);

      // A new contact: nothing about the instruction changed.
      await container
          .read(contactsControllerProvider.notifier)
          .addContact(
            const ContactDraft(
              name: 'Ann',
              relationship: ContactRelationship.friend,
              email: 'ann@example.com',
            ),
          );
      await Future<void>.delayed(Duration.zero);
      expect(fakes.instructions.calls.where((c) => c == 'list'), hasLength(1));

      // A rename: the recipient's name is read again.
      await contacts.updateContact('c2', const ContactPatch(name: 'Father'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(fakes.instructions.calls.where((c) => c == 'list'), hasLength(2));
      expect(
        container
            .read(instructionsControllerProvider)
            .value!
            .single
            .recipients
            .map((r) => r.displayName),
        containsAll(['Father', 'Mom']),
      );

      // A removal: the server drops them from the instruction.
      await contacts.removeContact('c2');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        container
            .read(instructionsControllerProvider)
            .value!
            .single
            .recipients
            .map((r) => r.displayName),
        ['Mom'],
      );
    });

    test('a new version of the plan reads the list again', () async {
      final fakes = _fakes();
      fakes.instructions.seed(
        title: 'Keys',
        recipients: {'c1': fakes.plan.stages.last.id},
      );
      final container = _container(fakes);
      final before = await _items(container);
      expect(before.single.recipients.single.stagePosition, 2);
      await container.read(planControllerProvider.future);

      // Another device moved the stage to the front of the plan and saved.
      fakes.plan.seed(
        PlanDraft(
          graceMinutes: 180,
          stages: [
            PlanStageDraft(
              id: fakes.plan.stages.last.id,
              offsetMinutes: 180,
              contactIds: const ['c1'],
            ),
          ],
        ),
      );
      await container.read(planControllerProvider.notifier).reload();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(fakes.instructions.calls.where((c) => c == 'list'), hasLength(2));
      expect(
        container
            .read(instructionsControllerProvider)
            .value!
            .single
            .recipients
            .single
            .stagePosition,
        1,
      );
    });
  });

  group('categories', () {
    test('in the server\'s order, leaving out what the app has no words '
        'for', () async {
      final fakes = _fakes();
      fakes.instructions.categoryIds = ['pets', 'brand_new', 'home'];
      final container = _container(fakes);
      expect(await container.read(instructionCategoriesProvider.future), [
        InstructionCategory.pets,
        InstructionCategory.home,
      ]);
    });

    test('when it cannot be read the app\'s own order is used', () async {
      final fakes = _fakes();
      fakes.instructions.failures['categories'] = [const NetworkFailure()];
      final container = _container(fakes);
      expect(
        await container.read(instructionCategoriesProvider.future),
        InstructionCategory.values,
      );
    });

    test(
      'an empty answer falls back too, and signed out needs no call',
      () async {
        final fakes = _fakes();
        fakes.instructions.categoryIds = const [];
        final container = _container(fakes);
        expect(
          await container.read(instructionCategoriesProvider.future),
          InstructionCategory.values,
        );
        final signedOut = _container(_fakes(), status: AuthStatus.signedOut);
        expect(
          await signedOut.read(instructionCategoriesProvider.future),
          InstructionCategory.values,
        );
      },
    );
  });

  group('release stages', () {
    test('only stages at least the minimum after the missed check-in', () {
      final plan = testPlan(
        stages: const [
          PlanStage(id: 'a', position: 1, offsetMinutes: 180),
          PlanStage(id: 'b', position: 2, offsetMinutes: 1439),
          PlanStage(id: 'c', position: 3, offsetMinutes: 1440),
          PlanStage(id: 'd', position: 4, offsetMinutes: 4320),
        ],
      );
      expect([for (final s in releaseStages(plan)) s.id], ['c', 'd']);
      expect(releaseStages(null), isEmpty);
      expect(stageById(plan, 'c')!.position, 3);
      expect(stageById(plan, 'zzz'), isNull);
      expect(stageById(null, 'c'), isNull);
    });
  });

  group('the draft in memory', () {
    test('is kept, replaced and cleared, and never printed', () {
      final container = ProviderContainer.test(
        overrides: testOverrides(authStatus: AuthStatus.signedIn),
      );
      final notifier = container.read(instructionAutosaveProvider.notifier);
      expect(container.read(instructionAutosaveProvider), isNull);
      notifier.save(
        const InstructionAutosave(title: 'Secret title', body: 'Secret text'),
      );
      expect(
        container.read(instructionAutosaveProvider)!.title,
        'Secret title',
      );
      expect(
        '${container.read(instructionAutosaveProvider)}',
        isNot(contains('Secret')),
      );
      notifier.clear();
      expect(container.read(instructionAutosaveProvider), isNull);
    });
  });
}
