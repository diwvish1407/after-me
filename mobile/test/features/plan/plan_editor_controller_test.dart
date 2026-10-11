import 'dart:async';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/checkin/application/schedule_controller.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/contacts/application/contacts_controller.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/home/application/home_controller.dart';
import 'package:afterme/features/instructions/application/instructions_controller.dart';
import 'package:afterme/features/instructions/data/models/instruction_models.dart';
import 'package:afterme/features/plan/application/plan_controller.dart';
import 'package:afterme/features/plan/application/plan_editor_controller.dart';
import 'package:afterme/features/plan/application/plan_editor_draft.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/test_app.dart';

/// The plan editor's controller against the real plan controller and the plan "server":
/// what a save sends, and what is kept whenever it does not work.

TestFakes _world({String tier = 'premium', bool active = false}) {
  final fakes = TestFakes()
    ..contacts = InMemoryContactsRepository(
      tier: tier,
      initial: [
        testContact(),
        testContact(
          id: 'c2',
          name: 'Brother',
          relationship: ContactRelationship.sibling,
          email: 'bro@example.com',
          priority: 2,
        ),
      ],
    );
  fakes.plan.seed(
    const PlanDraft(
      graceMinutes: 180,
      stages: [
        PlanStageDraft(offsetMinutes: 180, contactIds: ['c1']),
        PlanStageDraft(offsetMinutes: 1440, contactIds: ['c2']),
      ],
    ),
  );
  if (active) {
    fakes.server.activateNow();
  }
  return fakes;
}

Future<ProviderContainer> _open(TestFakes fakes) async {
  final container = ProviderContainer.test(
    retry: (retryCount, error) => null,
    overrides: testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
  );
  container
    ..listen(planControllerProvider, (_, _) {})
    ..listen(contactsControllerProvider, (_, _) {})
    ..listen(instructionsControllerProvider, (_, _) {})
    ..listen(planEditorControllerProvider, (_, _) {})
    ..listen(planEditorRulesProvider, (_, _) {})
    ..listen(planEditorLockedProvider, (_, _) {});
  await container.read(planControllerProvider.future);
  await container.read(contactsControllerProvider.future);
  await container.read(instructionsControllerProvider.future);
  return container;
}

PlanEditorController _editor(ProviderContainer c) =>
    c.read(planEditorControllerProvider.notifier);

PlanEditorState _state(ProviderContainer c) =>
    c.read(planEditorControllerProvider);

String _stageId(TestFakes fakes, int index) => fakes.plan.stages[index].id;

ValidationFailure _invalid(List<ApiFieldError> errors) => ValidationFailure(
  code: 'validation_failed',
  fieldErrors: errors,
  problem: ApiProblem(status: 422, code: 'validation_failed', errors: errors),
);

ApiFieldError _field(String field, String code) =>
    ApiFieldError(field: field, code: code, message: 'server words');

void main() {
  group('the draft', () {
    test(
      'starts from the saved plan, is not dirty, and follows edits',
      () async {
        final fakes = _world();
        final c = await _open(fakes);
        expect(_state(c).isReady, isTrue);
        expect(_state(c).dirty, isFalse);
        expect(_state(c).base!.version, 2);

        _editor(c)
          ..setGrace(360)
          ..setStageContacts(_stageId(fakes, 1), ['c1', 'c2']);
        expect(_state(c).dirty, isTrue);
        expect(_state(c).draft.graceMinutes, 360);
        expect(fakes.plan.calls, ['get'], reason: 'nothing is sent by editing');

        _editor(c).discard();
        expect(_state(c).dirty, isFalse);
        expect(_state(c).draft.graceMinutes, 180);
      },
    );

    test('adds, times and removes stages', () async {
      final fakes = _world();
      final c = await _open(fakes);
      _editor(c)
        ..addStage(2880)
        ..setStageTime(_stageId(fakes, 1), 720)
        ..removeStage(_stageId(fakes, 0));
      final draft = _state(c).draft;
      // Stage 1 was removed: the next one is the first, so the grace is its time.
      expect(draft.graceMinutes, 720);
      expect([for (final s in draft.stages) s.offsetMinutes], [720, 2880]);
    });

    test('a contact that is removed leaves the draft too', () async {
      final fakes = _world();
      final c = await _open(fakes);
      _editor(c).setStageContacts(_stageId(fakes, 0), ['c1', 'c2']);
      await c.read(contactsControllerProvider.notifier).removeContact('c2');
      expect(_state(c).draft.contactIds, {'c1'});
    });

    test('a plan changed elsewhere: an untouched draft follows it; one with '
        'edits stays as it is', () async {
      final fakes = _world();
      final c = await _open(fakes);

      // Untouched: follows.
      fakes.plan.seedStandard(['c2'], offsetMinutes: 360);
      await c.read(planControllerProvider.notifier).reload();
      expect(_state(c).base!.version, 3);
      expect(_state(c).draft.graceMinutes, 360);
      expect(_state(c).dirty, isFalse);

      // With an edit: it is kept, and still based on the plan it started from.
      _editor(c).setGrace(720);
      fakes.plan.seedStandard(['c1'], offsetMinutes: 1440);
      await c.read(planControllerProvider.notifier).reload();
      expect(_state(c).base!.version, 3);
      expect(_state(c).draft.graceMinutes, 720);
      expect(_state(c).dirty, isTrue);
    });

    test('the same plan read again updates the counts and the rules', () async {
      final fakes = _world();
      final c = await _open(fakes);
      final stageId = _stageId(fakes, 1);
      _editor(c).setGrace(360);
      fakes.instructions.seed(title: 'House', recipients: {'c2': stageId});
      await c.read(planControllerProvider.notifier).reload();
      expect(_state(c).draft.stageByKey(stageId)!.releaseCount, 1);
      expect(_state(c).draft.graceMinutes, 360, reason: 'edits stay');
      expect(_state(c).base!.version, 2);
    });
  });

  group('rules', () {
    test('a free account: suggested times and two stages', () async {
      final c = await _open(_world(tier: 'free'));
      final rules = c.read(planEditorRulesProvider)!;
      expect(rules.rules.customOffsets, isFalse);
      expect(rules.rules.maxStages, 2);
      expect(rules.stageChoices(includeKept: false), isNot(contains(10080)));
    });

    test('a premium account: custom times and ten stages; the plan\'s own '
        'times are kept', () async {
      final c = await _open(_world());
      final rules = c.read(planEditorRulesProvider)!;
      expect(rules.rules.customOffsets, isTrue);
      expect(rules.rules.maxStages, 10);
      expect(rules.keptOffsets, {180, 1440});
    });

    test('a stage an instruction is set for is a stage that holds', () async {
      final fakes = _world();
      final c = await _open(fakes);
      fakes.instructions.seed(
        title: 'Off',
        status: InstructionStatus.inactive,
        recipients: {'c2': _stageId(fakes, 1)},
      );
      await c.read(instructionsControllerProvider.notifier).reload();
      final rules = c.read(planEditorRulesProvider)!;
      expect(rules.holdsInstructions, {_stageId(fakes, 1)});
    });
  });

  group('saving', () {
    test('sends the draft with the If-Match of the plan it started from and '
        'every stage id; the answer becomes the new base', () async {
      final fakes = _world();
      final c = await _open(fakes);
      _editor(c)
        ..setGrace(360)
        ..addStage(2880);
      final result = await _editor(c).save();

      expect(result, PlanEditorSaveResult.saved);
      expect(fakes.plan.ifMatches, ['"plan-2"']);
      final sent = fakes.plan.saved.single;
      expect(sent['grace_minutes'], 360);
      final stages = sent['stages']! as List;
      expect((stages[0] as Map)['id'], _stageId(fakes, 0));
      expect((stages[1] as Map)['id'], _stageId(fakes, 1));
      expect((stages[2] as Map)['id'], isNull);
      expect(_state(c).base!.version, 3);
      expect(_state(c).dirty, isFalse);
      expect(_state(c).saving, isFalse);
      expect(_state(c).notice, isNull);
      expect(fakes.plan.stages, hasLength(3));
    });

    test(
      'while it is on the wire nothing can be sent again or edited',
      () async {
        final fakes = _world();
        final c = await _open(fakes);
        _editor(c).setGrace(360);
        final gate = Completer<void>();
        fakes.plan.gate = gate.future;
        final first = _editor(c).save();
        expect(_state(c).saving, isTrue);
        expect(await _editor(c).save(), PlanEditorSaveResult.notSent);
        _editor(c)
          ..setGrace(720)
          ..discard();
        expect(_state(c).draft.graceMinutes, 360);
        gate.complete();
        expect(await first, PlanEditorSaveResult.saved);
        expect(fakes.plan.saved, hasLength(1));
      },
    );

    test('nothing is sent while the editor is not ready', () async {
      final fakes = TestFakes()
        ..contacts = InMemoryContactsRepository(tier: 'premium');
      fakes.plan.failures['get'] = [const NetworkFailure()];
      final c = ProviderContainer.test(
        retry: (retryCount, error) => null,
        overrides: testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
      );
      c.listen(planEditorControllerProvider, (_, _) {});
      expect(_state(c).isReady, isFalse);
      expect(await _editor(c).save(), PlanEditorSaveResult.notSent);
      _editor(c)
        ..setGrace(360)
        ..discard()
        ..dismissNotice();
      expect(fakes.plan.saved, isEmpty);
      // Once the plan arrives the editor takes it.
      await c.read(planControllerProvider.notifier).reload();
      expect(_state(c).isReady, isTrue);
    });

    test('a failure that is nobody\'s business but the network keeps every '
        'edit and the same save can be tried again', () async {
      final fakes = _world();
      final c = await _open(fakes);
      _editor(c)
        ..setGrace(360)
        ..addStage(2880);
      fakes.plan.failures['save'] = [const NetworkFailure()];
      final failed = await _editor(c).save();
      expect(failed, PlanEditorSaveResult.failed);
      expect(_state(c).notice!.kind, PlanEditorNoticeKind.failure);
      expect(_state(c).notice!.failure, isA<NetworkFailure>());
      expect(_state(c).draft.graceMinutes, 360);
      expect(_state(c).draft.stages, hasLength(3));
      expect(_state(c).dirty, isTrue);
      expect(_state(c).saving, isFalse);

      expect(await _editor(c).save(), PlanEditorSaveResult.saved);
      expect(fakes.plan.calls.where((call) => call == 'save'), hasLength(2));
      expect(fakes.plan.ifMatches, [
        '"plan-2"',
      ], reason: 'the one that arrived');
    });

    test('a 412: the latest plan is loaded, the edits stay and are based on '
        'it, and the next save goes through', () async {
      final fakes = _world();
      final c = await _open(fakes);
      _editor(c).setGrace(360);
      // Changed on another device meanwhile (stage 2 now tells Mom).
      fakes.plan.seed(
        PlanDraft(
          graceMinutes: 180,
          stages: [
            PlanStageDraft(
              id: _stageId(fakes, 0),
              offsetMinutes: 180,
              contactIds: const ['c1'],
            ),
            PlanStageDraft(
              id: _stageId(fakes, 1),
              offsetMinutes: 1440,
              contactIds: const ['c1'],
            ),
          ],
        ),
      );

      final result = await _editor(c).save();
      expect(result, PlanEditorSaveResult.failed);
      expect(_state(c).notice!.kind, PlanEditorNoticeKind.stale);
      expect(_state(c).base!.version, 3, reason: 'the latest');
      expect(_state(c).draft.graceMinutes, 360, reason: 'the edit is kept');
      expect(_state(c).draft.stageByKey(_stageId(fakes, 1))!.contactIds, [
        'c2',
      ], reason: 'what the person had on screen, not silently replaced');
      expect(_state(c).dirty, isTrue);

      expect(await _editor(c).save(), PlanEditorSaveResult.saved);
      expect(fakes.plan.ifMatches, ['"plan-2"', '"plan-3"']);
    });

    test(
      'a 412 after the change was already made: the plan is the draft',
      () async {
        final fakes = _world();
        final c = await _open(fakes);
        _editor(c).setGrace(360);
        // The answer was lost: the server has what this device sent.
        fakes.plan.seed(
          PlanDraft(
            graceMinutes: 360,
            stages: [
              PlanStageDraft(
                id: _stageId(fakes, 0),
                offsetMinutes: 360,
                contactIds: const ['c1'],
              ),
              PlanStageDraft(
                id: _stageId(fakes, 1),
                offsetMinutes: 1440,
                contactIds: const ['c2'],
              ),
            ],
          ),
        );
        final result = await _editor(c).save();
        expect(result, PlanEditorSaveResult.matchesServer);
        expect(_state(c).dirty, isFalse);
        expect(_state(c).notice, isNull);
        expect(_state(c).base!.version, 3);
      },
    );

    test('a 412 that could not read the latest plan says so plainly and '
        'keeps everything', () async {
      final fakes = _world();
      final c = await _open(fakes);
      _editor(c).setGrace(360);
      fakes.plan
        ..failures['save'] = [
          const ConflictFailure(code: 'precondition_failed'),
        ]
        ..failures['get'] = [const NetworkFailure()];
      expect(await _editor(c).save(), PlanEditorSaveResult.failed);
      expect(_state(c).notice!.kind, PlanEditorNoticeKind.failure);
      expect(_state(c).draft.graceMinutes, 360);
      expect(_state(c).base!.version, 2);
    });

    test('a 428 is the same as a 412', () async {
      final fakes = _world();
      final c = await _open(fakes);
      _editor(c).setGrace(360);
      fakes.plan.seedStandard(['c1'], offsetMinutes: 720);
      fakes.plan.failures['save'] = [
        const ConflictFailure(code: 'precondition_required'),
      ];
      await _editor(c).save();
      expect(_state(c).notice!.kind, PlanEditorNoticeKind.stale);
    });

    test('an open incident (409) makes the editor read-only and keeps the '
        'edits; when it is over the editor opens up again', () async {
      final fakes = _world(active: true);
      final c = await _open(fakes);
      await c.read(scheduleControllerProvider.future);
      _editor(c).setGrace(360);
      // The incident opened while the app still believed check-ins were fine.
      fakes.server.openIncident();
      expect(await _editor(c).save(), PlanEditorSaveResult.failed);
      expect(_state(c).lockedByServer, isTrue);
      expect(c.read(planEditorLockedProvider), isTrue);
      expect(_state(c).draft.graceMinutes, 360);
      expect(_state(c).saving, isFalse);

      _editor(c).setGrace(720);
      expect(_state(c).draft.graceMinutes, 360, reason: 'read-only');
      expect(await _editor(c).save(), PlanEditorSaveResult.notSent);

      // The person checked in: the schedule says so and the editor opens up again.
      fakes.server.status = CheckInStatus.active;
      fakes.server.incident = null;
      await c.read(scheduleControllerProvider.notifier).reload();
      expect(_state(c).lockedByServer, isFalse);
      expect(_editor(c).isLocked, isFalse);
      _editor(c).setGrace(720);
      expect(_state(c).draft.graceMinutes, 720);
    });

    test('an incident the schedule already shows locks the editor before '
        'anything is sent', () async {
      final fakes = _world(active: true);
      fakes.server.openIncident();
      final c = await _open(fakes);
      await c.read(scheduleControllerProvider.future);
      expect(_editor(c).isLocked, isTrue);
      expect(c.read(planEditorLockedProvider), isTrue);
      _editor(c).setGrace(360);
      expect(_state(c).draft.graceMinutes, 180);
      expect(await _editor(c).save(), PlanEditorSaveResult.notSent);
      expect(fakes.plan.saved, isEmpty);
    });

    test('Home reporting an incident locks it too', () async {
      final fakes = _world(active: true);
      final c = await _open(fakes);
      await c.read(scheduleControllerProvider.future);
      await c.read(homeControllerProvider.future);
      expect(_editor(c).isLocked, isFalse);
      fakes.server.incident = {'id': 'i-1'};
      await c.read(homeControllerProvider.notifier).refresh();
      expect(_editor(c).isLocked, isTrue);
      expect(c.read(planEditorLockedProvider), isTrue);
    });
  });

  group('robustness', () {
    test(
      'something unexpected is a calm failure, never a stuck button',
      () async {
        final fakes = _world();
        final c = await _open(fakes);
        _editor(c).setGrace(360);
        final result = await _editor(
          c,
        ).save(guard: (send) async => throw StateError('not an API failure'));
        expect(result, PlanEditorSaveResult.failed);
        expect(_state(c).saving, isFalse);
        expect(_state(c).notice!.failure, isA<UnknownFailure>());
        expect(_state(c).draft.graceMinutes, 360);
      },
    );

    test('the person left while it was on the wire: what the server answered '
        'is kept by the plan controller, nothing throws', () async {
      final fakes = _world();
      final c = await _open(fakes);
      // Only this subscription keeps the editor alive.
      final editor = c.listen(planEditorControllerProvider, (_, _) {});
      c.read(planEditorControllerProvider.notifier).setGrace(360);
      final gate = Completer<void>();
      fakes.plan.gate = gate.future;
      final pending = c.read(planEditorControllerProvider.notifier).save();
      editor.close();
      // The listeners of `_open` keep it alive too: drop the provider outright.
      c.invalidate(planEditorControllerProvider);
      gate.complete();
      expect(await pending, PlanEditorSaveResult.saved);
      expect(c.read(planControllerProvider).value!.graceMinutes, 360);
      expect(fakes.plan.graceMinutes, 360);
    });

    test('a failure after the person left is dropped quietly', () async {
      final fakes = _world();
      final c = await _open(fakes);
      c.read(planEditorControllerProvider.notifier).setGrace(360);
      final gate = Completer<void>();
      fakes.plan.gate = gate.future;
      fakes.plan.failures['save'] = [const NetworkFailure()];
      final pending = c.read(planEditorControllerProvider.notifier).save();
      c.invalidate(planEditorControllerProvider);
      gate.complete();
      expect(await pending, PlanEditorSaveResult.failed);
      expect(fakes.plan.graceMinutes, 180);
    });
  });

  group('the password', () {
    test('the same request is sent again after the password: the same '
        'If-Match and the same body', () async {
      final fakes = _world(active: true);
      final c = await _open(fakes);
      _editor(c)
        ..setGrace(360)
        ..addStage(2880);

      var asked = 0;
      final result = await _editor(c).save(
        guard: (send) async {
          try {
            return await send();
          } on ForbiddenFailure catch (failure) {
            expect(failure.code, 'reauth_required');
            asked++;
            fakes.auth.reauthenticated = true;
            return send();
          }
        },
      );
      expect(result, PlanEditorSaveResult.saved);
      expect(asked, 1);
      expect(fakes.plan.ifMatches, ['"plan-2"', '"plan-2"']);
      expect(fakes.plan.saved[0], fakes.plan.saved[1]);
      expect(fakes.plan.stages, hasLength(3));
    });

    test(
      'closing the password sheet changes nothing and loses nothing',
      () async {
        final fakes = _world(active: true);
        final c = await _open(fakes);
        _editor(c).setGrace(360);
        final result = await _editor(c).save(
          guard: (send) async {
            try {
              return await send();
            } on ForbiddenFailure {
              return null;
            }
          },
        );
        expect(result, PlanEditorSaveResult.cancelled);
        expect(_state(c).saving, isFalse);
        expect(_state(c).notice, isNull);
        expect(_state(c).dirty, isTrue);
        expect(_state(c).draft.graceMinutes, 360);
        expect(fakes.plan.graceMinutes, 180);
        expect(fakes.plan.saved, hasLength(1), reason: 'sent once, not again');
      },
    );

    test('the same If-Match even when the plan was read again meanwhile', () async {
      final fakes = _world(active: true);
      final c = await _open(fakes);
      _editor(c).setGrace(360);
      final result = await _editor(c).save(
        guard: (send) async {
          try {
            return await send();
          } on ForbiddenFailure {
            // While the sheet was open the plan was read again (same version).
            await c.read(planControllerProvider.notifier).reload();
            fakes.auth.reauthenticated = true;
            return send();
          }
        },
      );
      expect(result, PlanEditorSaveResult.saved);
      expect(fakes.plan.ifMatches, ['"plan-2"', '"plan-2"']);
    });

    test(
      'a password that is still wanted after the sheet is a calm failure',
      () async {
        final fakes = _world(active: true);
        final c = await _open(fakes);
        _editor(c).setGrace(360);
        final result = await _editor(c).save(guard: (send) => send());
        expect(result, PlanEditorSaveResult.failed);
        expect(_state(c).notice!.kind, PlanEditorNoticeKind.failure);
        expect(
          (_state(c).notice!.failure! as ForbiddenFailure).code,
          'reauth_required',
        );
        expect(_state(c).draft.graceMinutes, 360);
      },
    );
  });

  group('what the server refuses', () {
    test('a stage that still shares instructions (409) is put back, the '
        'instructions are named by id, and the other edits stay', () async {
      final fakes = _world();
      final c = await _open(fakes);
      final stageId = _stageId(fakes, 1);
      final instruction = fakes.instructions.seed(
        title: 'House emergency',
        status: InstructionStatus.inactive,
        recipients: {'c2': stageId},
      );
      // Not on the person's list yet (the app does not know): the server says no.
      _editor(c)
        ..setGrace(360)
        ..removeStage(stageId);
      expect(_state(c).draft.stages, hasLength(1));

      final result = await _editor(c).save();
      expect(result, PlanEditorSaveResult.failed);
      expect(_state(c).notice!.kind, PlanEditorNoticeKind.inUse);
      expect(_state(c).notice!.instructionIds, [instruction]);
      expect(_state(c).draft.stages, hasLength(2), reason: 'put back');
      expect(_state(c).draft.stages.last.id, stageId);
      expect(_state(c).draft.graceMinutes, 360, reason: 'the other edit stays');
      expect(fakes.plan.stages, hasLength(2));
    });

    test('a stage that was added here and taken out again does not make the '
        'editor forget the one that was taken out before: a 409 still puts it '
        'back', () async {
      final fakes = _world();
      final c = await _open(fakes);
      final stageId = _stageId(fakes, 1);
      fakes.instructions.seed(
        title: 'House emergency',
        status: InstructionStatus.inactive,
        recipients: {'c2': stageId},
      );
      _editor(c)
        ..removeStage(stageId)
        ..addStage(2880);
      final added = _state(c).draft.stages.last.key;
      _editor(c).removeStage(added);
      expect([for (final s in _state(c).draft.removed) s.id], [stageId]);

      final result = await _editor(c).save();
      expect(result, PlanEditorSaveResult.failed);
      expect(_state(c).notice!.kind, PlanEditorNoticeKind.inUse);
      expect(
        [for (final s in _state(c).draft.stages) s.id],
        [_stageId(fakes, 0), stageId],
        reason: 'the stage that holds the instruction is back',
      );
    });

    test('with the instruction list at hand only the stage that holds them '
        'goes back', () async {
      final fakes = _world();
      final c = await _open(fakes);
      fakes.plan.seed(
        PlanDraft(
          graceMinutes: 180,
          stages: [
            PlanStageDraft(
              id: _stageId(fakes, 0),
              offsetMinutes: 180,
              contactIds: const ['c1'],
            ),
            PlanStageDraft(
              id: _stageId(fakes, 1),
              offsetMinutes: 1440,
              contactIds: const ['c2'],
            ),
            const PlanStageDraft(offsetMinutes: 2880, contactIds: ['c1']),
          ],
        ),
      );
      await c.read(planControllerProvider.notifier).reload();
      final holding = _stageId(fakes, 1);
      final other = _stageId(fakes, 2);
      fakes.instructions.seed(title: 'House', recipients: {'c2': holding});
      await c.read(instructionsControllerProvider.notifier).reload();

      _editor(c)
        ..removeStage(holding)
        ..removeStage(other);
      expect(_state(c).draft.stages, hasLength(1));
      await _editor(c).save();
      final ids = [for (final s in _state(c).draft.stages) s.id];
      expect(ids, [_stageId(fakes, 0), holding], reason: 'only that one');
      expect(_state(c).draft.removed.map((s) => s.id), [other]);
    });

    test('a tier limit (403) is a notice and the plan is read again', () async {
      final fakes = _world(tier: 'free');
      final c = await _open(fakes);
      _editor(c).addStage(2880);
      final result = await _editor(c).save();
      expect(result, PlanEditorSaveResult.failed);
      expect(_state(c).notice!.kind, PlanEditorNoticeKind.limit);
      expect(_state(c).notice!.failure, isA<PlanLimitFailure>());
      expect(_state(c).draft.stages, hasLength(3), reason: 'kept');
      expect(fakes.plan.calls.last, 'get');
    });

    test('a stage or contact that is not yours (404): everything is read '
        'again, people who are gone are dropped, the edits stay', () async {
      final fakes = _world();
      final c = await _open(fakes);
      _editor(c)
        ..setGrace(360)
        ..setStageContacts(_stageId(fakes, 1), ['c2', 'gone']);
      final contactCalls = fakes.contacts.calls.length;
      final result = await _editor(c).save();
      expect(result, PlanEditorSaveResult.failed);
      expect(_state(c).notice!.kind, PlanEditorNoticeKind.notFound);
      expect(fakes.contacts.calls.length, greaterThan(contactCalls));
      expect(_state(c).draft.stageByKey(_stageId(fakes, 1))!.contactIds, [
        'c2',
      ]);
      expect(_state(c).draft.graceMinutes, 360);
      // The next save goes through.
      expect(await _editor(c).save(), PlanEditorSaveResult.saved);
    });

    test(
      'a stage that was deleted elsewhere (404) becomes a new stage',
      () async {
        final fakes = _world();
        final c = await _open(fakes);
        _editor(c).setGrace(360);
        // The other device kept only stage 1.
        fakes.plan.seed(
          PlanDraft(
            graceMinutes: 180,
            stages: [
              PlanStageDraft(
                id: _stageId(fakes, 0),
                offsetMinutes: 180,
                contactIds: const ['c1'],
              ),
            ],
          ),
        );
        // 412 first (the version moved), then the edits are based on that plan.
        await _editor(c).save();
        expect(_state(c).notice!.kind, PlanEditorNoticeKind.stale);
        expect(_state(c).draft.stages.last.id, isNull, reason: 'created again');
        expect(await _editor(c).save(), PlanEditorSaveResult.saved);
        expect(fakes.plan.stages, hasLength(2));
      },
    );

    test('field errors are mapped to the grace period and to each stage by '
        'its place in the request', () async {
      final fakes = _world();
      final c = await _open(fakes);
      final one = _stageId(fakes, 0);
      final two = _stageId(fakes, 1);
      _editor(c).addStage(2880);
      final newKey = _state(c).draft.stages.last.key;

      Future<List<PlanIssue>> refuse(List<ApiFieldError> errors) async {
        fakes.plan.failures['save'] = [_invalid(errors)];
        expect(await _editor(c).save(), PlanEditorSaveResult.failed);
        expect(_state(c).notice, isNull, reason: 'said on the fields');
        return _state(c).serverIssues;
      }

      expect(
        await refuse([
          _field('grace_minutes', 'out_of_range'),
          _field('stages[0].offset_minutes', 'release_too_early'),
          _field('stages[1].offset_minutes', 'too_close'),
          _field('stages[2].offset_minutes', 'too_large'),
        ]),
        [
          const PlanIssue(PlanIssueKind.graceOutOfRange),
          PlanIssue(PlanIssueKind.stageReleaseTooEarly, stageKey: one),
          PlanIssue(PlanIssueKind.stageTooClose, stageKey: two),
          PlanIssue(PlanIssueKind.stageTooLarge, stageKey: newKey),
        ],
      );
      expect(
        await refuse([
          _field('grace_minutes', 'not_a_preset'),
          _field('stages[1].offset_minutes', 'not_a_preset'),
          _field('stages[2].offset_minutes', 'must_equal_grace'),
          _field('stages[0].notify_contact_ids', 'duplicate'),
          _field('stages', 'too_short'),
          _field('stages[7].offset_minutes', 'too_close'),
          _field('unknown', 'x'),
        ]),
        [
          const PlanIssue(PlanIssueKind.graceNotAllowed),
          PlanIssue(PlanIssueKind.stageNotAllowed, stageKey: two),
          PlanIssue(PlanIssueKind.other, stageKey: newKey),
          PlanIssue(PlanIssueKind.other, stageKey: one),
          const PlanIssue(PlanIssueKind.noStage),
        ],
      );
      expect(await refuse([_field('grace_minutes', 'weird')]), [
        const PlanIssue(PlanIssueKind.other),
      ]);
      expect(await refuse([_field('stages', 'weird')]), [
        const PlanIssue(PlanIssueKind.other),
      ]);
      expect(_state(c).draft.stages, hasLength(3), reason: 'edits stay');

      // Editing clears what the server said about the earlier request.
      _editor(c).setGrace(360);
      expect(_state(c).serverIssues, isEmpty);
    });

    test('a 422 without a field this app knows is a calm failure', () async {
      final fakes = _world();
      final c = await _open(fakes);
      _editor(c).setGrace(360);
      fakes.plan.failures['save'] = [_invalid(const [])];
      await _editor(c).save();
      expect(_state(c).notice!.kind, PlanEditorNoticeKind.failure);
      expect(_state(c).notice!.failure, isA<ValidationFailure>());
      expect(_state(c).serverIssues, isEmpty);
    });

    test('anything else is a failure notice and keeps the edits', () async {
      final fakes = _world();
      final c = await _open(fakes);
      _editor(c).setGrace(360);
      for (final failure in <AppFailure>[
        const ServerFailure(statusCode: 500),
        const RateLimitedFailure(),
        const UnknownFailure(),
        const UpgradeRequiredFailure(),
      ]) {
        fakes.plan.failures['save'] = [failure];
        expect(await _editor(c).save(), PlanEditorSaveResult.failed);
        expect(_state(c).notice!.failure, same(failure));
        expect(_state(c).draft.graceMinutes, 360);
      }
      _editor(c).dismissNotice();
      expect(_state(c).notice, isNull);
      _editor(c).dismissNotice();
    });
  });
}
