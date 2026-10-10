import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/design_system/design_system.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/instructions/application/instruction_autosave.dart';
import 'package:afterme/features/instructions/application/instructions_controller.dart';
import 'package:afterme/features/instructions/application/release_options.dart';
import 'package:afterme/features/instructions/data/instructions_repository.dart';
import 'package:afterme/features/instructions/presentation/instruction_labels.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:afterme/features/plan/application/plan_controller.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/plan_fixtures.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

/// A time the plan has no stage for yet (1, 2 or 3 days, the tier's presets) is offered
/// next to the plan's own stages. Saving adds the stage to the plan first, in one
/// `PUT /plan`, and then creates or updates the instruction with the new stage's id. The
/// stages the plan already has are sent exactly as they are.

const _day1 = "If you haven't checked in for 1 day";
const _day2 = "If you haven't checked in for 2 days";
const _day3 = "If you haven't checked in for 3 days";

/// Mom (c1), Bro (c2) and Dad (c3), all accepted, on [tier], and a plan with the stages
/// [offsets] (all telling Mom).
TestFakes _fakes({String tier = 'premium', List<int> offsets = const [180]}) {
  final fakes = TestFakes()
    ..contacts = InMemoryContactsRepository(
      tier: tier,
      initial: [
        testContact(),
        testContact(
          id: 'c2',
          name: 'Bro',
          relationship: ContactRelationship.sibling,
          email: 'bro@example.com',
          priority: 2,
        ),
        testContact(
          id: 'c3',
          name: 'Dad',
          relationship: ContactRelationship.father,
          email: 'dad@example.com',
          priority: 3,
        ),
      ],
    );
  fakes.plan.seed(
    PlanDraft(
      graceMinutes: offsets.first,
      stages: [
        for (final offset in offsets)
          PlanStageDraft(offsetMinutes: offset, contactIds: const ['c1']),
      ],
    ),
  );
  return fakes;
}

ProviderContainer _container(TestFakes fakes) {
  final container = ProviderContainer.test(
    retry: (retryCount, error) => null,
    overrides: testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
  );
  container
    ..listen(instructionsControllerProvider, (_, _) {})
    ..listen(planControllerProvider, (_, _) {});
  return container;
}

/// The order in which the plan and the instructions "servers" were asked for a change.
List<String> _writes(TestFakes fakes) => [
  for (final e in fakes.events)
    if (e == 'plan.save' ||
        e == 'instructions.create' ||
        e == 'instructions.update')
      e,
];

Future<Instruction> _add(
  ProviderContainer container,
  List<RecipientChoice> recipients,
) async {
  await container.read(instructionsControllerProvider.future);
  await container.read(planControllerProvider.future);
  return container
      .read(instructionsControllerProvider.notifier)
      .addInstructionWithTimes(
        category: InstructionCategory.home,
        title: 'House emergency',
        body: 'The spare key is with a neighbour.',
        recipients: recipients,
      );
}

RecipientChoice _newTime(String contactId, int minutes) =>
    RecipientChoice.newTime(contactId: contactId, offsetMinutes: minutes);

void main() {
  group('the times offered', () {
    PlanRules rules({
      bool custom = false,
      int max = 2,
      List<int> presets = const [180, 360, 720, 1440, 2880, 4320],
    }) => PlanRules(
      graceMin: 60,
      graceMax: 4320,
      stageGapMin: 30,
      offsetMax: 43200,
      releaseOffsetMin: 1440,
      maxStages: max,
      customOffsets: custom,
      presets: presets,
    );

    Plan plan(List<int> offsets, {PlanRules? r}) => testPlan(
      grace: offsets.isEmpty ? 180 : offsets.first,
      rules: r ?? rules(),
      stages: [
        for (var i = 0; i < offsets.length; i++)
          PlanStage(
            id: 's${i + 1}',
            position: i + 1,
            offsetMinutes: offsets[i],
          ),
      ],
    );

    List<(String, int)> of(Plan p) => [
      for (final o in releaseOptions(p))
        (o.isNew ? 'new' : 'stage', o.offsetMinutes),
    ];

    test('a plan with only an early stage offers 1, 2 and 3 days as new', () {
      expect(of(plan([180])), [('new', 1440), ('new', 2880), ('new', 4320)]);
    });

    test('a stage the plan has is the option, and is not offered twice', () {
      expect(of(plan([180, 1440], r: rules(max: 5))), [
        ('stage', 1440),
        ('new', 2880),
        ('new', 4320),
      ]);
      expect(of(plan([180, 1440, 2880], r: rules(max: 5))), [
        ('stage', 1440),
        ('stage', 2880),
        ('new', 4320),
      ]);
    });

    test('no room for another stage: only the stages that exist', () {
      final full = plan([180, 1440], r: rules(max: 2));
      expect(full.stages.length, 2);
      expect(of(full), [('stage', 1440)]);
      expect(of(plan([180, 360])), isEmpty);
    });

    test('a plan without a stage offers nothing: a first stage must end the '
        'grace period', () {
      expect(of(plan([])), isEmpty);
      expect(releaseOptions(null), isEmpty);
    });

    test('a time must be later than the first stage and 30 minutes from any '
        'other', () {
      // The first stage is 3 days out: 1 and 2 days would come first.
      expect(of(plan([4320], r: rules(max: 5))), [('stage', 4320)]);
      // A custom stage 10 minutes from 1 day: the preset would be too close.
      expect(of(plan([180, 1450], r: rules(custom: true, max: 5))), [
        ('stage', 1450),
        ('new', 2880),
        ('new', 4320),
      ]);
    });

    test('the keys are the stage id or the minutes, and a time that became a '
        'stage is that stage', () {
      final p = plan([180]);
      expect(const ReleaseOption.newTime(1440).key, 'new:1440');
      expect(ReleaseOption.offsetOfKey('new:1440'), 1440);
      expect(ReleaseOption.offsetOfKey('s1'), isNull);
      expect(normaliseReleaseKey(p, 'new:1440'), 'new:1440');
      expect(normaliseReleaseKey(p, 's1'), 's1');
      final later = plan([180, 1440]);
      expect(normaliseReleaseKey(later, 'new:1440'), 's2');
      expect(normaliseReleaseKey(null, 'new:1440'), 'new:1440');
      expect(
        const ReleaseOption.newTime(1440),
        const ReleaseOption.newTime(1440),
      );
      expect(
        _newTime('c1', 1440),
        isNot(const RecipientChoice.stage(contactId: 'c1', stageId: 's2')),
      );
    });
  });

  group('saving (the controller)', () {
    test('a new time becomes a stage first, then the instruction uses its '
        'id; the existing stages are sent as they were', () async {
      final fakes = _fakes(offsets: [180, 1440]);
      final before = fakes.plan.stages;
      final container = _container(fakes);
      final created = await _add(container, [_newTime('c2', 2880)]);

      expect(_writes(fakes), ['plan.save', 'instructions.create']);
      final after = fakes.plan.stages;
      expect(after.map((s) => s.offsetMinutes), [180, 1440, 2880]);
      for (var i = 0; i < before.length; i++) {
        expect(after[i].id, before[i].id, reason: 'same stage');
        expect(after[i].contactIds, before[i].contactIds);
        expect(after[i].offsetMinutes, before[i].offsetMinutes);
      }
      expect(after.last.contactIds, ['c2'], reason: 'tells the recipient');
      expect(created.recipients.single.releaseStageId, after.last.id);
      expect(created.recipients.single.stagePosition, 3);
      expect(fakes.plan.saved.single['grace_minutes'], 180);
    });

    test('two people at the same new time share one stage', () async {
      final fakes = _fakes();
      final container = _container(fakes);
      final created = await _add(container, [
        _newTime('c1', 1440),
        _newTime('c2', 1440),
      ]);
      expect(fakes.plan.stages.map((s) => s.offsetMinutes), [180, 1440]);
      expect(fakes.plan.stages.last.contactIds, ['c1', 'c2']);
      expect(created.recipients.map((r) => r.releaseStageId).toSet(), {
        fakes.plan.stages.last.id,
      });
      expect(fakes.plan.calls.where((c) => c == 'save'), hasLength(1));
    });

    test(
      'two different new times are two stages in one save (premium)',
      () async {
        final fakes = _fakes();
        final container = _container(fakes);
        final created = await _add(container, [
          _newTime('c1', 2880),
          _newTime('c2', 1440),
        ]);
        expect(fakes.plan.calls.where((c) => c == 'save'), hasLength(1));
        expect(fakes.plan.stages.map((s) => s.offsetMinutes), [
          180,
          1440,
          2880,
        ]);
        expect(fakes.plan.stages[1].contactIds, ['c2']);
        expect(fakes.plan.stages[2].contactIds, ['c1']);
        final byContact = {
          for (final r in created.recipients) r.contactId: r.stagePosition,
        };
        expect(byContact, {'c2': 2, 'c1': 3});
        // Positions follow the time order the request had.
        expect(
          [
            for (final s in (fakes.plan.saved.single['stages']! as List))
              (s as Map)['offset_minutes'],
          ],
          [180, 1440, 2880],
        );
      },
    );

    test(
      'free: two different new times need three stages: the limit is '
      'said, nothing is changed and nothing is sent for the instruction',
      () async {
        final fakes = _fakes(tier: 'free');
        final container = _container(fakes);
        final before = fakes.plan.stages;
        await expectLater(
          _add(container, [_newTime('c1', 1440), _newTime('c2', 2880)]),
          throwsA(
            isA<PlanLimitFailure>()
                .having((f) => f.resource, 'resource', 'stages')
                .having((f) => f.limit, 'limit', 2),
          ),
        );
        expect(_writes(fakes), ['plan.save']);
        expect(fakes.plan.stages, before);
        expect(fakes.instructions.liveCount, 0);
        final failure = const PlanLimitFailure(resource: 'stages', limit: 2);
        expect(
          instructionFailureMessage(
            AppLocalizationsEn(),
            failure,
            freePlan: true,
          ),
          'The free plan has room for 2 stages in your plan, and this would need more. Nothing was changed. Choose a time your plan already has, or the same time for everyone.',
        );
        expect(
          instructionFailureMessage(AppLocalizationsEn(), failure),
          'Your account has room for 2 stages in your plan, and this would need more. Nothing was changed. Choose a time your plan already has, or the same time for everyone.',
        );
      },
    );

    test('free: one new time fits', () async {
      final fakes = _fakes(tier: 'free');
      final container = _container(fakes);
      await _add(container, [_newTime('c1', 1440)]);
      expect(fakes.plan.stages.map((s) => s.offsetMinutes), [180, 1440]);
      expect(fakes.instructions.liveCount, 1);
    });

    test(
      'a plan that cannot be saved sends nothing for the instruction',
      () async {
        final fakes = _fakes();
        fakes.plan.failures['save'] = [const NetworkFailure()];
        final container = _container(fakes);
        await expectLater(
          _add(container, [_newTime('c1', 1440)]),
          throwsA(isA<NetworkFailure>()),
        );
        expect(_writes(fakes), ['plan.save']);
        expect(fakes.instructions.liveCount, 0);
        expect(fakes.plan.stages, hasLength(1));
      },
    );

    test(
      'an open incident is the plan\'s own answer, and nothing is sent',
      () async {
        final fakes = _fakes();
        fakes.plan.failures['save'] = [
          const ConflictFailure(code: 'incident_open'),
        ];
        final container = _container(fakes);
        await expectLater(
          _add(container, [_newTime('c1', 1440)]),
          throwsA(
            isA<ConflictFailure>().having(
              (f) => f.code,
              'code',
              'incident_open',
            ),
          ),
        );
        expect(fakes.instructions.calls, isNot(contains('create')));
        final l10n = AppLocalizationsEn();
        expect(
          instructionFailureMessage(
            l10n,
            const ConflictFailure(code: 'incident_open'),
          ),
          l10n.errorIncidentOpen,
        );
      },
    );

    test('the plan was saved and the instruction was refused: the stage stays, '
        'it is said, and the next try reuses it', () async {
      final fakes = _fakes();
      fakes.instructions.failures['create'] = [const NetworkFailure()];
      final container = _container(fakes);
      await expectLater(
        _add(container, [_newTime('c1', 1440)]),
        throwsA(
          isA<StageAddedButNotSaved>().having(
            (e) => e.failure,
            'failure',
            isA<NetworkFailure>(),
          ),
        ),
      );
      expect(fakes.plan.stages.map((s) => s.offsetMinutes), [180, 1440]);
      expect(fakes.instructions.liveCount, 0);
      final stageId = fakes.plan.stages.last.id;

      // The same choice again: the stage exists, so no second save of the plan.
      final created = await _add(container, [_newTime('c1', 1440)]);
      expect(fakes.plan.calls.where((c) => c == 'save'), hasLength(1));
      expect(fakes.plan.stages, hasLength(2));
      expect(created.recipients.single.releaseStageId, stageId);
    });

    test('a plan changed elsewhere (412) is read again and the save is tried '
        'once more, silently', () async {
      final fakes = _fakes();
      final container = _container(fakes);
      await container.read(instructionsControllerProvider.future);
      await container.read(planControllerProvider.future);
      // Another device saved a stage at 2 days: the app's version is stale.
      fakes.plan.seed(
        PlanDraft(
          graceMinutes: 180,
          stages: [
            PlanStageDraft(
              id: fakes.plan.stages.single.id,
              offsetMinutes: 180,
              contactIds: const ['c1'],
            ),
            const PlanStageDraft(offsetMinutes: 2880, contactIds: ['c1']),
          ],
        ),
      );
      final created = await container
          .read(instructionsControllerProvider.notifier)
          .addInstructionWithTimes(
            category: InstructionCategory.home,
            title: 'Keys',
            body: 'Under the pot.',
            recipients: [_newTime('c2', 1440), _newTime('c3', 2880)],
          );
      expect(fakes.plan.calls.where((c) => c == 'save'), hasLength(2));
      expect(fakes.plan.ifMatches, ['"plan-2"', '"plan-3"']);
      expect(fakes.plan.stages.map((s) => s.offsetMinutes), [180, 1440, 2880]);
      expect(created.recipients.map((r) => r.stagePosition).toList()..sort(), [
        2,
        3,
      ], reason: 'the stage that was added elsewhere is reused');
      expect(fakes.plan.stages.last.contactIds, ['c1'], reason: 'untouched');
    });

    test('a plan that stays stale is the plan\'s notice', () async {
      final fakes = _fakes();
      fakes.plan.failures['save'] = [
        const ConflictFailure(code: 'precondition_failed'),
        const ConflictFailure(code: 'precondition_failed'),
      ];
      final container = _container(fakes);
      await expectLater(
        _add(container, [_newTime('c1', 1440)]),
        throwsA(isA<ConflictFailure>()),
      );
      expect(fakes.instructions.liveCount, 0);
      final l10n = AppLocalizationsEn();
      expect(
        instructionFailureMessage(
          l10n,
          const ConflictFailure(code: 'precondition_required'),
        ),
        l10n.planStale,
      );
    });

    test(
      'a contact that is gone (404) reads the contacts again and says so',
      () async {
        final fakes = _fakes();
        final container = _container(fakes);
        await expectLater(
          _add(container, [_newTime('ghost', 1440)]),
          throwsA(isA<NotFoundFailure>()),
        );
        expect(fakes.instructions.liveCount, 0);
      },
    );

    test('an edit adds the stage, then changes the recipients', () async {
      final fakes = _fakes(offsets: [180, 1440]);
      final id = fakes.instructions.seed(
        title: 'Keys',
        recipients: {'c1': fakes.plan.stages.last.id},
      );
      final container = _container(fakes);
      await container.read(instructionsControllerProvider.future);
      await container.read(planControllerProvider.future);
      final updated = await container
          .read(instructionsControllerProvider.notifier)
          .updateInstructionWithTimes(
            id,
            const InstructionPatch(title: 'Keys, changed'),
            recipients: [
              RecipientChoice.stage(
                contactId: 'c1',
                stageId: fakes.plan.stages.last.id,
              ),
              _newTime('c2', 2880),
            ],
          );
      expect(_writes(fakes), ['plan.save', 'instructions.update']);
      expect(updated.title, 'Keys, changed');
      expect(updated.recipients, hasLength(2));
      expect(fakes.instructions.updated.single.keys, {'title', 'recipients'});
    });

    test('nothing is added when every time is a stage already', () async {
      final fakes = _fakes(offsets: [180, 1440]);
      final container = _container(fakes);
      await _add(container, [
        RecipientChoice.stage(
          contactId: 'c1',
          stageId: fakes.plan.stages.last.id,
        ),
      ]);
      expect(fakes.plan.calls, isNot(contains('save')));
      expect(_writes(fakes), ['instructions.create']);
    });
  });

  group('the form', () {
    Future<TestFakes> open(
      WidgetTester tester, {
      TestFakes? fakes,
      bool on = false,
    }) async {
      final f = fakes ?? _fakes();
      if (on) {
        f.server.activateNow();
      }
      await openApp(tester, fakes: f, route: AppRoutes.instructionNew);
      return f;
    }

    Future<void> tap(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder.first);
      await tester.pump();
      await tester.tap(finder.first);
      await tester.pump();
    }

    Future<void> fill(WidgetTester tester) async {
      await tap(tester, find.widgetWithText(ChoiceChip, 'Home'));
      await typeInto(tester, 'Title', 'House emergency');
      await tester.enterText(
        find.widgetWithText(TextField, 'What should they know?'),
        'The spare key is with a neighbour.',
      );
      await tester.pumpAndSettle();
    }

    Future<void> tick(WidgetTester tester, String name) async {
      await tap(tester, find.widgetWithText(CheckboxListTile, name));
      await tester.pumpAndSettle();
    }

    Future<void> time(
      WidgetTester tester,
      String label, {
      int index = 0,
    }) async {
      await tap(
        tester,
        find.widgetWithText(RadioListTile<String>, label).at(index),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a plan with only an early stage offers 1, 2 and 3 days, and '
        'a hint that choosing one adds it', (tester) async {
      await open(tester);
      await tick(tester, 'Mom');
      for (final label in [_day1, _day2, _day3]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(
        find.text(
          'Your plan has no stage that far out yet. Choosing a time adds it to your plan, and the people you choose for it are told then too.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining("so this can't be shared"), findsNothing);
      await time(tester, _day2);
      expect(
        find.text(
          'Saving adds this time to your plan. Whoever you choose for it is told at that time, and receives this.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the plan\'s own stage and the new ones sit together, worded '
        'alike', (tester) async {
      await open(tester, fakes: _fakes(offsets: [180, 1440]));
      await tick(tester, 'Mom');
      expect(find.byType(RadioListTile<String>), findsNWidgets(3));
      expect(find.text(_day1), findsOneWidget);
      expect(find.text(_day2), findsOneWidget);
      expect(find.text(_day3), findsOneWidget);
    });

    testWidgets('a time is saved: the plan first, then the instruction, and '
        'the list shows it', (tester) async {
      final fakes = await open(tester);
      await fill(tester);
      await tick(tester, 'Mom');
      await time(tester, _day1);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();

      expect(_writes(fakes), ['plan.save', 'instructions.create']);
      expect(fakes.plan.stages.map((s) => s.offsetMinutes), [180, 1440]);
      expect(fakes.instructions.created.single['recipients'], [
        {'contact_id': 'c1', 'release_stage_id': fakes.plan.stages.last.id},
      ]);
      expect(snackText(tester), 'Instruction saved.');
      expect(find.text('Mom: After 1 day'), findsOneWidget);
    });

    testWidgets('two people at one new time make one stage', (tester) async {
      final fakes = await open(tester);
      await fill(tester);
      await tick(tester, 'Mom');
      await tick(tester, 'Bro');
      await time(tester, _day2);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(fakes.plan.calls.where((c) => c == 'save'), hasLength(1));
      expect(fakes.plan.stages.map((s) => s.offsetMinutes), [180, 2880]);
      expect(fakes.plan.stages.last.contactIds, ['c1', 'c2']);
    });

    testWidgets('a time each (premium): two stages in one save', (
      tester,
    ) async {
      final fakes = await open(tester);
      await fill(tester);
      await tick(tester, 'Mom');
      await tick(tester, 'Bro');
      await tap(tester, find.text('Choose a time for each person'));
      await tester.pumpAndSettle();
      await time(tester, _day1, index: 0);
      await time(tester, _day2, index: 1);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(fakes.plan.calls.where((c) => c == 'save'), hasLength(1));
      expect(fakes.plan.stages.map((s) => s.offsetMinutes), [180, 1440, 2880]);
      expect(fakes.instructions.created.single['recipients'], [
        {'contact_id': 'c1', 'release_stage_id': fakes.plan.stages[1].id},
        {'contact_id': 'c2', 'release_stage_id': fakes.plan.stages[2].id},
      ]);
    });

    testWidgets('a time each (free): the stage limit is said plainly, nothing '
        'changed, and what was typed stays', (tester) async {
      final fakes = await open(tester, fakes: _fakes(tier: 'free'));
      await fill(tester);
      await tick(tester, 'Mom');
      await tick(tester, 'Bro');
      await tap(tester, find.text('Choose a time for each person'));
      await tester.pumpAndSettle();
      await time(tester, _day1, index: 0);
      await time(tester, _day2, index: 1);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();

      expect(
        find.text(
          'The free plan has room for 2 stages in your plan, and this would need more. Nothing was changed. Choose a time your plan already has, or the same time for everyone.',
        ),
        findsOneWidget,
      );
      expect(fakes.plan.stages, hasLength(1));
      expect(fakes.instructions.liveCount, 0);
      expect(fakes.instructions.calls, isNot(contains('create')));
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Title'))
            .controller!
            .text,
        'House emergency',
      );
      // The same time for everyone fits, and saves.
      await tap(tester, find.text('Use the same time for everyone'));
      await tester.pumpAndSettle();
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(fakes.plan.stages.map((s) => s.offsetMinutes), [180, 1440]);
      expect(fakes.instructions.liveCount, 1);
    });

    testWidgets('a plan that cannot be saved sends nothing for the '
        'instruction and says why', (tester) async {
      final fakes = await open(tester);
      fakes.plan.failures['save'] = [const NetworkFailure()];
      await fill(tester);
      await tick(tester, 'Mom');
      await time(tester, _day1);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(fakes.instructions.calls, isNot(contains('create')));
      expect(fakes.plan.stages, hasLength(1));
      // Trying again works.
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(fakes.instructions.liveCount, 1);
    });

    testWidgets('an instruction that is refused after the plan was saved says '
        'so, keeps the draft, and the next try reuses the stage', (
      tester,
    ) async {
      final fakes = await open(tester);
      fakes.instructions.failures['create'] = [const NetworkFailure()];
      await fill(tester);
      await tick(tester, 'Mom');
      await time(tester, _day1);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();

      expect(
        find.text(
          "Your plan now has the new time, but this instruction wasn't saved. Nothing else changed. Try again: the time is already there.",
        ),
        findsOneWidget,
      );
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(fakes.plan.stages.map((s) => s.offsetMinutes), [180, 1440]);
      expect(fakes.instructions.liveCount, 0);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(Scaffold).first),
      );
      expect(container.read(instructionAutosaveProvider), isNotNull);
      // The time is now one of the plan's own stages, and still the one chosen.
      expect(
        tester
            .widget<RadioGroup<String>>(find.byType(RadioGroup<String>).first)
            .groupValue,
        fakes.plan.stages.last.id,
      );

      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(fakes.plan.calls.where((c) => c == 'save'), hasLength(1));
      expect(fakes.instructions.liveCount, 1);
      expect(
        find.text('Your plan now has the new time', findRichText: false),
        findsNothing,
      );
    });

    group('while check-ins are on', () {
      testWidgets('one password sheet for the whole save, with its own reason, '
          'and each request goes once after it', (tester) async {
        final fakes = await open(tester, on: true);
        await fill(tester);
        await tick(tester, 'Mom');
        await time(tester, _day1);
        await tapText(tester, 'Save instruction');
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text("Confirm it's you"), findsOneWidget);
        expect(
          find.text(
            'Adding this time to your plan and choosing who receives this needs your password because it decides who is told and who sees it.',
          ),
          findsOneWidget,
        );
        expect(fakes.plan.stages, hasLength(1), reason: 'nothing yet');
        expect(fakes.instructions.liveCount, 0);
        final asked = fakes.events.where((e) => e == 'plan.save').length;
        expect(asked, 1, reason: 'the first try was answered 403');
        expect(fakes.instructions.calls, isNot(contains('create')));

        await typeInto(tester, 'Password', fakes.auth.password);
        await tapText(tester, 'Confirm');
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();

        expect(find.text("Confirm it's you"), findsNothing);
        expect(_writes(fakes), [
          'plan.save',
          'plan.save',
          'instructions.create',
        ]);
        expect(
          fakes.auth.calls.where((c) => c == 'reauth'),
          hasLength(1),
          reason: 'one sheet',
        );
        expect(fakes.plan.stages.map((s) => s.offsetMinutes), [180, 1440]);
        expect(fakes.instructions.liveCount, 1);
        expect(
          fakes.instructions.reauthAsked,
          0,
          reason: 'the password was fresh',
        );
      });

      testWidgets('closing the sheet changes nothing and says nothing', (
        tester,
      ) async {
        final fakes = await open(tester, on: true);
        await fill(tester);
        await tick(tester, 'Mom');
        await time(tester, _day1);
        await tapText(tester, 'Save instruction');
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.tap(find.text('Cancel'));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(fakes.plan.stages, hasLength(1));
        expect(fakes.instructions.liveCount, 0);
        expect(snackText(tester), isNull);
        expect(find.byType(FailureNotice), findsNothing);
        expect(_writes(fakes), ['plan.save']);
        expect(
          tester
              .widget<TextField>(find.widgetWithText(TextField, 'Title'))
              .controller!
              .text,
          'House emergency',
        );
      });

      testWidgets('a time that is already a stage of the plan only asks the '
          'instruction\'s question, in the usual words', (tester) async {
        final fakes = await open(
          tester,
          fakes: _fakes(offsets: [180, 1440]),
          on: true,
        );
        await fill(tester);
        await tick(tester, 'Mom');
        await time(tester, _day1);
        await tapText(tester, 'Save instruction');
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          find.text(
            'Changing who receives this needs your password because it decides who sees it.',
          ),
          findsOneWidget,
        );
        expect(fakes.plan.calls, isNot(contains('save')));
      });
    });

    testWidgets('during onboarding nothing is asked', (tester) async {
      final fakes = _fakes();
      fakes.prefs = freshPreferences({
        'afterme.onboardingUserId': 'user-1',
        'afterme.onboardingCompleted': false,
        'afterme.onboardingStep': OnboardingStep.instruction.name,
      });
      await pumpAfterMe(tester, fakes: fakes, status: AuthStatus.signedIn);
      await tapText(tester, 'Pets');
      await tester.pumpAndSettle();
      await time(tester, _day1);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.auth.calls, isNot(contains('reauth')));
      expect(fakes.plan.stages.map((s) => s.offsetMinutes), [180, 1440]);
      expect(fakes.instructions.liveCount, 1);
      expect(find.text('Stay protected'), findsOneWidget);
    });

    testWidgets('an edit can add a time too', (tester) async {
      final fakes = _fakes(offsets: [180, 1440]);
      fakes.instructions.seed(
        title: 'Keys',
        recipients: {'c1': fakes.plan.stages.last.id},
      );
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructionEdit('instruction-1'),
      );
      await tick(tester, 'Bro');
      await tap(tester, find.text('Choose a time for each person'));
      await tester.pumpAndSettle();
      await time(tester, _day2, index: 1);
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(_writes(fakes), ['plan.save', 'instructions.update']);
      expect(fakes.plan.stages.map((s) => s.offsetMinutes), [180, 1440, 2880]);
      expect(fakes.instructions.updated.single.keys, {'recipients'});
    });

    testWidgets('with no room and no stage out far enough the old message and '
        'the way to the plan stay', (tester) async {
      await open(
        tester,
        fakes: _fakes(tier: 'free', offsets: [180, 360]),
      );
      expect(
        find.textContaining("so this can't be shared with anyone yet"),
        findsOneWidget,
      );
      expect(find.text('Review your plan'), findsOneWidget);
    });
  });
}
