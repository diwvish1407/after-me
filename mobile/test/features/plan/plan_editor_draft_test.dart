import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/plan/application/plan_editor_draft.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/plan_fixtures.dart';

/// Mom after 3 hours, Brother after 1 day: the plan most tests start from.
Plan _plan({int version = 3, PlanRules? rules, int releaseAtTwo = 0}) =>
    testPlan(
      version: version,
      rules: rules,
      stages: [
        const PlanStage(
          id: 's1',
          position: 1,
          offsetMinutes: 180,
          contactIds: ['c1'],
        ),
        PlanStage(
          id: 's2',
          position: 2,
          offsetMinutes: 1440,
          contactIds: const ['c2'],
          releaseCount: releaseAtTwo,
        ),
      ],
    );

PlanEditorDraft _draft({PlanRules? rules}) =>
    PlanEditorDraft.fromPlan(_plan(rules: rules));

PlanEditorRules _rules({
  bool custom = true,
  Set<String> holds = const {},
  Set<int> kept = const {180, 1440},
}) => PlanEditorRules(
  rules: planRules(custom: custom),
  keptOffsets: kept,
  holdsInstructions: holds,
);

void main() {
  group('PlanEditorDraft', () {
    test(
      'starts from the plan with every id kept, and sends it back as is',
      () {
        final draft = _draft();
        expect(draft.graceMinutes, 180);
        expect([for (final s in draft.stages) s.id], ['s1', 's2']);
        expect(draft.sameAs(_plan()), isTrue);
        expect(draft.toPlanDraft(), _plan().toDraft());
      },
    );

    test('the grace period is the first stage: changing one changes both', () {
      final draft = _draft().withGrace(360);
      expect(draft.graceMinutes, 360);
      expect(draft.stages.first.offsetMinutes, 360);
      expect(draft.stages.first.id, 's1');
      expect(draft.sameAs(_plan()), isFalse);
      // Choosing the first stage's time is choosing the grace period.
      final viaStage = _draft().withStageOffset('s1', 720);
      expect(viaStage.graceMinutes, 720);
    });

    test('later stages stay in time order; the first stays first', () {
      var draft = _draft().addStage(4320).addStage(720);
      expect(
        [for (final s in draft.stages) s.offsetMinutes],
        [180, 720, 1440, 4320],
      );
      draft = draft.withStageOffset('s2', 10080);
      expect(
        [for (final s in draft.stages) s.offsetMinutes],
        [180, 720, 4320, 10080],
      );
      expect(
        draft.stages.last.id,
        's2',
        reason: 'the id travels with the stage',
      );
      // Two at the same time keep the order they had.
      draft = _draft().addStage(2880).withStageOffset('s2', 2880);
      expect([for (final s in draft.stages) s.key], ['s1', 's2', 'new-1']);
    });

    test(
      'a new stage has no id, tells nobody and gets its own key each time',
      () {
        final one = _draft().addStage(2880);
        final two = one.addStage(4320);
        final added = two.stages.where((s) => s.id == null).toList();
        expect([for (final s in added) s.key], ['new-1', 'new-2']);
        expect(added.every((s) => s.contactIds.isEmpty), isTrue);
        expect(two.toPlanDraft().stages.last.id, isNull);
      },
    );

    test(
      'the first stage of an empty plan runs when the grace period ends',
      () {
        const empty = PlanEditorDraft(graceMinutes: 360, stages: []);
        final one = empty.addStage(9999);
        expect(one.stages.single.offsetMinutes, 360);
        expect(one.graceMinutes, 360);
        expect(empty.isEmpty, isTrue);
      },
    );

    test('contacts of a stage can be replaced', () {
      final draft = _draft().withContacts('s2', ['c1', 'c2']);
      expect(draft.stageByKey('s2')!.contactIds, ['c1', 'c2']);
      expect(draft.contactIds, {'c1', 'c2'});
      expect(draft.stageByKey('nope'), isNull);
    });

    test('sameAs compares the set of people, not their order', () {
      final plan = testPlan(
        stages: const [
          PlanStage(
            id: 's1',
            position: 1,
            offsetMinutes: 180,
            contactIds: ['c1', 'c2'],
          ),
        ],
      );
      final draft = PlanEditorDraft.fromPlan(plan)
          .withContacts('s1', ['c2', 'c1']);
      expect(draft.sameAs(plan), isTrue);
      expect(
        PlanEditorDraft.fromPlan(plan).withContacts('s1', ['c2']).sameAs(plan),
        isFalse,
      );
    });

    test('removing a stage keeps it aside; putting it back restores it', () {
      final removed = _draft().removeStage('s2');
      expect(removed.stages, hasLength(1));
      expect(removed.removed.single.id, 's2');
      expect(removed.toPlanDraft().stages, hasLength(1));
      expect(removed.sameAs(_plan()), isFalse);

      final back = removed.restoreStage('s2');
      expect(back.sameAs(_plan()), isTrue);
      expect(back.removed, isEmpty);
      expect(removed.restoreStage('nope'), removed);
      expect(removed.removeStage('nope'), removed);
    });

    test('a stage added in the editor is simply gone when removed', () {
      final draft = _draft().addStage(2880);
      final key = draft.stages.last.key;
      final removed = draft.removeStage(key);
      expect(removed.removed, isEmpty);
      expect(removed.stages, hasLength(2));
    });

    test('taking out a stage that was added here keeps the ones taken out '
        'earlier', () {
      // A saved stage is taken out, then a stage is added and taken out again: the
      // first must still be there to be put back (it used to be forgotten).
      final draft = _draft().removeStage('s2').addStage(2880);
      final added = draft.stages.last.key;
      final removed = draft.removeStage(added);

      expect([for (final s in removed.removed) s.id], ['s2']);
      expect([for (final s in removed.stages) s.id], ['s1']);
      expect(removed.restoreStage('s2').sameAs(_plan()), isTrue);
    });

    test('removing the first stage makes the next one the first: its time is '
        'the grace period', () {
      final draft = _draft().removeStage('s1');
      expect(draft.graceMinutes, 1440);
      expect(draft.stages.single.id, 's2');
      expect(draft.stages.single.offsetMinutes, 1440);

      // Putting the first one back restores the earlier grace period.
      final back = draft.restoreStage('s1');
      expect(back.graceMinutes, 180);
      expect([for (final s in back.stages) s.id], ['s1', 's2']);
      expect(back.sameAs(_plan()), isTrue);
    });

    test('restoring into an empty draft makes the stage the only one', () {
      const empty = PlanEditorDraft(
        graceMinutes: 180,
        stages: [],
        removed: [
          EditableStage(
            key: 's9',
            id: 's9',
            offsetMinutes: 720,
            contactIds: ['c1'],
          ),
        ],
      );
      final back = empty.restoreStage('s9');
      expect(back.graceMinutes, 720);
      expect(back.stages.single.id, 's9');
    });

    test('restoring a later stage puts it among the others by time', () {
      final removed = _draft().addStage(4320).removeStage('s2');
      final back = removed.restoreStage('s2');
      expect([for (final s in back.stages) s.offsetMinutes], [180, 1440, 4320]);
    });

    test('rebasing keeps edits, updates what the server counts and turns a '
        'stage the server no longer has into a new one', () {
      final edited = _draft()
          .withContacts('s2', ['c1', 'c2'])
          .removeStage('s1')
          .addStage(2880);
      final latest = testPlan(
        version: 9,
        stages: const [
          PlanStage(
            id: 's2',
            position: 1,
            offsetMinutes: 1440,
            contactIds: ['c2'],
            releaseCount: 2,
          ),
        ],
      );
      final rebased = edited.rebasedOn(latest);
      expect(rebased.stageByKey('s2')!.releaseCount, 2);
      expect(rebased.stageByKey('s2')!.contactIds, ['c1', 'c2']);
      expect(rebased.removed, isEmpty, reason: 's1 is already gone there');

      final gone = _draft().rebasedOn(latest);
      final s1 = gone.stageByKey('s1')!;
      expect(s1.id, isNull, reason: 'it will be created again');
      expect(gone.toPlanDraft().stages.first.id, isNull);
    });

    test('contacts that are gone are dropped from the stages', () {
      final draft = _draft()
          .withContacts('s1', ['c1', 'c9'])
          .removeStage('s2')
          .keepingContacts({'c1'});
      expect(draft.stageByKey('s1')!.contactIds, ['c1']);
      expect(draft.removed.single.contactIds, isEmpty);
    });

    test('equal drafts are equal', () {
      expect(_draft(), _draft());
      expect(_draft().hashCode, _draft().hashCode);
      expect(_draft(), isNot(_draft().withGrace(360)));
      expect(_draft().removeStage('s2'), isNot(_draft()));
      expect(
        const PlanIssue(PlanIssueKind.stageTooClose, stageKey: 'a'),
        const PlanIssue(PlanIssueKind.stageTooClose, stageKey: 'a'),
      );
      expect(
        const PlanIssue(PlanIssueKind.stageTooClose).hashCode,
        const PlanIssue(PlanIssueKind.stageTooClose).hashCode,
      );
      expect(
        const PlanIssue(PlanIssueKind.noStage).toString(),
        contains('noStage'),
      );
    });
  });

  group('PlanEditorRules: what the editor offers', () {
    test('a free account: the suggested times only, up to the grace limit', () {
      final rules = _rules(custom: false);
      expect(rules.graceChoices(), [180, 360, 720, 1440, 2880, 4320]);
      expect(rules.stageChoices(includeKept: false), [
        180,
        360,
        720,
        1440,
        2880,
        4320,
      ]);
      expect(rules.rules.maxStages, 2);
    });

    test(
      'custom times add 1 and 2 hours and weeks, never beyond the limit',
      () {
        final rules = _rules();
        expect(rules.graceChoices(), [
          60,
          120,
          180,
          360,
          720,
          1440,
          2880,
          4320,
        ]);
        expect(rules.stageChoices(includeKept: false), [
          180,
          360,
          720,
          1440,
          2880,
          4320,
          10080,
          20160,
          43200,
        ]);
      },
    );

    test('what the plan already has is always among the choices', () {
      final rules = _rules(custom: false, kept: {400});
      expect(rules.graceChoices(current: 250), contains(250));
      expect(rules.stageChoices(), contains(400));
      expect(rules.stageChoices(includeKept: false), isNot(contains(400)));
      expect(rules.stageChoices(current: 500), contains(500));
    });

    test('a downgraded account keeps its stages but cannot add more', () {
      final rules = _rules(custom: false);
      expect(rules.stageLimit(0), 2);
      expect(rules.stageLimit(2), 2);
      expect(rules.stageLimit(5), 5);
    });

    test('grace problems mirror the server', () {
      final free = _rules(custom: false);
      expect(free.graceProblem(180), isNull);
      expect(free.graceProblem(30), PlanIssueKind.graceOutOfRange);
      expect(free.graceProblem(5000), PlanIssueKind.graceOutOfRange);
      expect(free.graceProblem(200), PlanIssueKind.graceNotAllowed);
      expect(free.graceProblem(1440), isNull);
      expect(
        free.graceProblem(180, shares: true),
        PlanIssueKind.stageReleaseTooEarly,
      );
      // A time the plan already uses stays allowed (a downgraded account).
      expect(_rules(custom: false, kept: {200}).graceProblem(200), isNull);
      expect(_rules().graceProblem(200), isNull);
    });

    test('stage problems mirror the server', () {
      final rules = _rules();
      final draft = _draft();
      PlanIssueKind? problem(
        int m, {
        String? key = 's2',
        bool shares = false,
      }) => rules.stageProblem(draft, key, m, shares: shares);
      expect(problem(2880), isNull);
      expect(
        problem(100),
        PlanIssueKind.stageTooClose,
        reason: 'before stage 1',
      );
      expect(
        problem(190),
        PlanIssueKind.stageTooClose,
        reason: 'within 30 min',
      );
      expect(problem(210), isNull);
      expect(problem(43201), PlanIssueKind.stageTooLarge);
      expect(problem(500, shares: true), PlanIssueKind.stageReleaseTooEarly);
      expect(problem(1440, shares: true), isNull);
      // A new stage must keep its distance from every stage, the one it is not.
      expect(problem(1450, key: null), PlanIssueKind.stageTooClose);
      expect(problem(1450, key: 's2'), isNull);

      final free = _rules(custom: false);
      expect(
        free.stageProblem(draft, 's2', 2000),
        PlanIssueKind.stageNotAllowed,
      );
      expect(free.stageProblem(draft, 's2', 2880), isNull);
    });

    test('issues of a valid plan: none', () {
      expect(_rules().issues(_draft()), isEmpty);
    });

    test(
      'issues: grace, order, gap, preset, limit and releases, per stage',
      () {
        final rules = _rules(custom: false, holds: {'s2'});
        // Grace 1 day, so stage 2 (at 1 day) is not after stage 1.
        var issues = rules.issues(_draft().withGrace(1440));
        expect(issues, [
          const PlanIssue(PlanIssueKind.stageTooClose, stageKey: 's2'),
        ]);

        // A custom time on a free account, and a stage that shares instructions moved up.
        issues = rules.issues(_draft().withStageOffset('s2', 700));
        expect(issues, [
          const PlanIssue(PlanIssueKind.stageNotAllowed, stageKey: 's2'),
          const PlanIssue(PlanIssueKind.stageReleaseTooEarly, stageKey: 's2'),
        ]);

        // Out of range grace period.
        issues = _rules().issues(_draft().withGrace(30));
        expect(issues.first, const PlanIssue(PlanIssueKind.graceOutOfRange));

        // The server's limit on a stage's time.
        issues = _rules().issues(_draft().withStageOffset('s2', 50000));
        expect(issues, [
          const PlanIssue(PlanIssueKind.stageTooLarge, stageKey: 's2'),
        ]);
      },
    );

    test('issues: the first stage sharing instructions is the grace period\'s '
        'problem, said on that stage', () {
      final rules = _rules(holds: {'s1'});
      final issues = rules.issues(_draft());
      expect(issues, [
        const PlanIssue(PlanIssueKind.stageReleaseTooEarly, stageKey: 's1'),
      ]);
    });

    test('issues: a plan with no stage cannot be saved', () {
      final issues = _rules().issues(
        const PlanEditorDraft(graceMinutes: 180, stages: []),
      );
      expect(issues, [const PlanIssue(PlanIssueKind.noStage)]);
      expect(
        _rules().issues(const PlanEditorDraft(graceMinutes: 10, stages: [])),
        [
          const PlanIssue(PlanIssueKind.graceOutOfRange),
          const PlanIssue(PlanIssueKind.noStage),
        ],
      );
    });

    test('holds: a stage with active releases, or one an instruction is set '
        'for', () {
      final rules = _rules(holds: {'s2'});
      expect(
        rules.holds(
          const EditableStage(
            key: 'a',
            id: 'a',
            offsetMinutes: 1440,
            contactIds: [],
            releaseCount: 1,
          ),
        ),
        isTrue,
      );
      expect(rules.holds(_draft().stageByKey('s2')!), isTrue);
      expect(rules.holds(_draft().stageByKey('s1')!), isFalse);
      expect(
        rules.holds(
          const EditableStage(key: 'new-1', offsetMinutes: 5, contactIds: []),
        ),
        isFalse,
      );
    });
  });

  group('planAdvice', () {
    final mom = testContact();
    final brother = testContact(
      id: 'c2',
      name: 'Brother',
      relationship: ContactRelationship.sibling,
      email: 'b@example.com',
      status: VerificationStatus.pending,
    );
    final dad = testContact(
      id: 'c3',
      name: 'Dad',
      relationship: ContactRelationship.father,
      email: 'd@example.com',
      status: VerificationStatus.declined,
    );
    final off = mom.copyWith(id: 'c4', displayName: 'Aunt', isActive: false);

    test('a plan whose people have all accepted has nothing to say', () {
      final draft = PlanEditorDraft.fromPlan(
        testPlan(
          stages: const [
            PlanStage(
              id: 's1',
              position: 1,
              offsetMinutes: 180,
              contactIds: ['c1'],
            ),
          ],
        ),
      );
      expect(planAdvice(draft, [mom]), isEmpty);
    });

    test(
      'a person who has not accepted yet is said plainly, on their stage',
      () {
        final draft = _draft();
        final advice = planAdvice(draft, [mom, brother]);
        expect(advice, hasLength(1));
        expect(advice.single.kind, PlanAdviceKind.contactWaiting);
        expect(advice.single.stageKey, 's2');
        expect(advice.single.contact!.displayName, 'Brother');
        expect(advice.single.isPlanLevel, isFalse);
      },
    );

    test('declined, opted out and bounced people are unreachable; a switched '
        'off one is off', () {
      final draft = _draft().withContacts('s2', ['c3', 'c4']);
      final advice = planAdvice(draft, [mom, dad, off]);
      expect(
        [for (final a in advice) a.kind],
        [PlanAdviceKind.contactUnreachable, PlanAdviceKind.contactOff],
      );
    });

    test('a stage with nobody is flagged; so is a plan where nobody is '
        'chosen', () {
      final draft = _draft().withContacts('s1', []).withContacts('s2', []);
      final advice = planAdvice(draft, [mom, brother]);
      expect(advice.first.kind, PlanAdviceKind.nobodyTold);
      expect(advice.first.isPlanLevel, isTrue);
      expect(
        advice.where((a) => a.kind == PlanAdviceKind.stageEmpty),
        hasLength(2),
      );
    });

    test('nobody who has accepted: the plan-level gap says so', () {
      final draft = _draft().withContacts('s1', ['c2']).withContacts('s2', [
        'c3',
      ]);
      final advice = planAdvice(draft, [brother, dad]);
      expect(advice.first.kind, PlanAdviceKind.nobodyReachable);
    });

    test('no stage at all', () {
      final advice = planAdvice(
        const PlanEditorDraft(graceMinutes: 180, stages: []),
        [mom],
      );
      expect([for (final a in advice) a.kind], [PlanAdviceKind.noStage]);
    });

    test('a contact the list does not have is left out', () {
      final advice = planAdvice(_draft(), [mom]);
      // c2 is unknown: stage 2 has nobody the list knows.
      expect([for (final a in advice) a.kind], [PlanAdviceKind.stageEmpty]);
    });
  });
}
