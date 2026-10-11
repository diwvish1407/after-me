import 'package:flutter/foundation.dart';

import '../../contacts/data/contacts_repository.dart';
import '../data/plan_repository.dart';

/// One stage of the plan while it is being edited.
///
/// An existing stage keeps the [id] the server gave it (instructions are assigned to a
/// stage by that id); a stage added in the editor has none until the server saves it.
/// [key] is what the screen uses to tell stages apart: the id, or `new-1`, `new-2`, ...
@immutable
class EditableStage {
  const EditableStage({
    required this.key,
    required this.offsetMinutes,
    required this.contactIds,
    this.id,
    this.releaseCount = 0,
  });

  final String key;
  final String? id;

  /// Minutes after the missed deadline.
  final int offsetMinutes;

  /// The contacts told at this stage, in the order they were chosen.
  final List<String> contactIds;

  /// How many active instructions the server says are shared at this stage.
  final int releaseCount;

  EditableStage copyWith({
    String? id,
    bool clearId = false,
    int? offsetMinutes,
    List<String>? contactIds,
    int? releaseCount,
  }) => EditableStage(
    key: key,
    id: clearId ? null : (id ?? this.id),
    offsetMinutes: offsetMinutes ?? this.offsetMinutes,
    contactIds: contactIds ?? this.contactIds,
    releaseCount: releaseCount ?? this.releaseCount,
  );

  @override
  bool operator ==(Object other) =>
      other is EditableStage &&
      other.key == key &&
      other.id == id &&
      other.offsetMinutes == offsetMinutes &&
      other.releaseCount == releaseCount &&
      listEquals(other.contactIds, contactIds);

  @override
  int get hashCode => Object.hash(
    key,
    id,
    offsetMinutes,
    releaseCount,
    Object.hashAll(contactIds),
  );
}

/// The plan as the person is changing it (before anything is saved).
///
/// The first stage always runs when the grace period ends (the server's rule), so its
/// time is the grace period itself: there is one number, and the screen cannot show them
/// apart. The later stages are kept in time order. Every method returns a new draft.
@immutable
class PlanEditorDraft {
  const PlanEditorDraft({
    required this.graceMinutes,
    required this.stages,
    this.newStages = 0,
    this.removed = const [],
  });

  /// The plan the server has, as a draft (every stage keeps its id).
  factory PlanEditorDraft.fromPlan(Plan plan) => PlanEditorDraft(
    graceMinutes: plan.graceMinutes,
    stages: [
      for (final stage in plan.stages)
        EditableStage(
          key: stage.id,
          id: stage.id,
          offsetMinutes: stage.offsetMinutes,
          contactIds: stage.contactIds,
          releaseCount: stage.releaseCount,
        ),
    ],
  );

  final int graceMinutes;
  final List<EditableStage> stages;

  /// How many keys `new-n` were handed out, so a key is never used twice.
  final int newStages;

  /// Existing stages the person took out, as they were then. Nothing is removed until
  /// the plan is saved, and a stage the server refuses to remove (it still shares
  /// instructions) is put back from here.
  final List<EditableStage> removed;

  bool get isEmpty => stages.isEmpty;

  /// Every contact some stage tells.
  Set<String> get contactIds => {
    for (final stage in stages) ...stage.contactIds,
  };

  EditableStage? stageByKey(String key) {
    for (final stage in stages) {
      if (stage.key == key) {
        return stage;
      }
    }
    return null;
  }

  PlanEditorDraft _with({int? graceMinutes, List<EditableStage>? stages}) {
    final grace = graceMinutes ?? this.graceMinutes;
    var next = stages ?? this.stages;
    if (next.isNotEmpty && next.first.offsetMinutes != grace) {
      next = [next.first.copyWith(offsetMinutes: grace), ...next.skip(1)];
    }
    return PlanEditorDraft(
      graceMinutes: grace,
      stages: next,
      newStages: newStages,
      removed: removed,
    );
  }

  /// The first stage in [stages] stays first (it is the end of the grace period); the
  /// others are put in time order, and a stage keeps its place among stages at the same
  /// time.
  static List<EditableStage> _ordered(List<EditableStage> stages) {
    if (stages.length < 3) {
      return stages;
    }
    final rest = stages.skip(1).toList();
    final indexed = [for (var i = 0; i < rest.length; i++) (i, rest[i])]
      ..sort((a, b) {
        final byTime = a.$2.offsetMinutes.compareTo(b.$2.offsetMinutes);
        return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
      });
    return [stages.first, for (final (_, stage) in indexed) stage];
  }

  /// A different grace period. The first stage follows it.
  PlanEditorDraft withGrace(int minutes) => _with(graceMinutes: minutes);

  /// A different time for the stage with [key]. Changing the first stage's time changes
  /// the grace period, which is the same thing.
  PlanEditorDraft withStageOffset(String key, int minutes) {
    if (stages.isNotEmpty && stages.first.key == key) {
      return withGrace(minutes);
    }
    return _with(
      stages: _ordered([
        for (final stage in stages)
          if (stage.key == key)
            stage.copyWith(offsetMinutes: minutes)
          else
            stage,
      ]),
    );
  }

  /// Different people told at the stage with [key].
  PlanEditorDraft withContacts(String key, List<String> contactIds) => _with(
    stages: [
      for (final stage in stages)
        if (stage.key == key) stage.copyWith(contactIds: contactIds) else stage,
    ],
  );

  /// A new stage at [offsetMinutes] that tells nobody yet. Without any stage it is the
  /// first one and runs when the grace period ends, whatever [offsetMinutes] says.
  PlanEditorDraft addStage(int offsetMinutes) {
    final created = newStages + 1;
    final stage = EditableStage(
      key: 'new-$created',
      offsetMinutes: stages.isEmpty ? graceMinutes : offsetMinutes,
      contactIds: const [],
    );
    return PlanEditorDraft(
      graceMinutes: graceMinutes,
      stages: _ordered([...stages, stage]),
      newStages: created,
      removed: removed,
    );
  }

  /// Takes the stage with [key] out. When it was the first one, the next stage becomes
  /// the first and the grace period becomes its time: nobody is told earlier than that.
  PlanEditorDraft removeStage(String key) {
    final taken = stageByKey(key);
    if (taken == null) {
      return this;
    }
    final remaining = [
      for (final stage in stages)
        if (stage.key != key) stage,
    ];
    final wasFirst = stages.first.key == key;
    return PlanEditorDraft(
      graceMinutes: wasFirst && remaining.isNotEmpty
          ? remaining.first.offsetMinutes
          : graceMinutes,
      stages: remaining,
      newStages: newStages,
      // Only a stage the server has can be put back after a refusal. A stage that was
      // added here and not saved is simply gone; the stages taken out earlier stay.
      removed: taken.id != null ? [...removed, taken] : removed,
    );
  }

  /// Puts back the stage with [key] that was taken out. It goes before the first stage
  /// when it runs earlier than that one: the grace period is then its time again.
  PlanEditorDraft restoreStage(String key) {
    final stage = removed.where((s) => s.key == key).firstOrNull;
    if (stage == null) {
      return this;
    }
    final others = [
      for (final s in removed)
        if (s.key != key) s,
    ];
    if (stages.isEmpty) {
      return PlanEditorDraft(
        graceMinutes: stage.offsetMinutes,
        stages: [stage],
        newStages: newStages,
        removed: others,
      );
    }
    if (stage.offsetMinutes < stages.first.offsetMinutes) {
      return PlanEditorDraft(
        graceMinutes: stage.offsetMinutes,
        stages: [stage, ...stages],
        newStages: newStages,
        removed: others,
      );
    }
    return PlanEditorDraft(
      graceMinutes: graceMinutes,
      stages: _ordered([...stages, stage]),
      newStages: newStages,
      removed: others,
    );
  }

  /// What the server counts now: each existing stage's shared instructions. A stage whose
  /// id the server no longer has becomes a new stage (it is created again on save), and
  /// one that was taken out is simply gone.
  PlanEditorDraft rebasedOn(Plan latest) {
    final known = {for (final stage in latest.stages) stage.id: stage};
    EditableStage counted(EditableStage stage, PlanStage server) =>
        stage.copyWith(releaseCount: server.releaseCount);
    return PlanEditorDraft(
      graceMinutes: graceMinutes,
      newStages: newStages,
      stages: [
        for (final stage in stages)
          if (stage.id == null)
            stage
          else if (known[stage.id] case final server?)
            counted(stage, server)
          else
            stage.copyWith(clearId: true, releaseCount: 0),
      ],
      removed: [
        for (final stage in removed)
          if (known[stage.id] case final server?) counted(stage, server),
      ],
    );
  }

  /// The same draft without the contacts that are not in [live] (they were removed).
  PlanEditorDraft keepingContacts(Set<String> live) {
    EditableStage kept(EditableStage stage) => stage.copyWith(
      contactIds: [
        for (final id in stage.contactIds)
          if (live.contains(id)) id,
      ],
    );
    return PlanEditorDraft(
      graceMinutes: graceMinutes,
      newStages: newStages,
      stages: [for (final stage in stages) kept(stage)],
      removed: [for (final stage in removed) kept(stage)],
    );
  }

  /// The `PUT /v1/plan` body.
  PlanDraft toPlanDraft() => PlanDraft(
    graceMinutes: graceMinutes,
    stages: [
      for (final stage in stages)
        PlanStageDraft(
          id: stage.id,
          offsetMinutes: stage.offsetMinutes,
          contactIds: stage.contactIds,
        ),
    ],
  );

  /// Whether saving this draft would change nothing: the same grace period and stages
  /// (by id, time and the set of people told).
  bool sameAs(Plan plan) {
    if (graceMinutes != plan.graceMinutes ||
        stages.length != plan.stages.length) {
      return false;
    }
    for (var i = 0; i < stages.length; i++) {
      final mine = stages[i];
      final theirs = plan.stages[i];
      if (mine.id != theirs.id ||
          mine.offsetMinutes != theirs.offsetMinutes ||
          !setEquals(mine.contactIds.toSet(), theirs.contactIds.toSet())) {
        return false;
      }
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is PlanEditorDraft &&
      other.graceMinutes == graceMinutes &&
      other.newStages == newStages &&
      listEquals(other.stages, stages) &&
      listEquals(other.removed, removed);

  @override
  int get hashCode => Object.hash(
    graceMinutes,
    newStages,
    Object.hashAll(stages),
    Object.hashAll(removed),
  );
}

/// What is wrong with a time (or with the plan) that the server would refuse. The same
/// kinds describe the app's own checks and the server's field errors.
enum PlanIssueKind {
  /// The grace period is shorter or longer than the account allows.
  graceOutOfRange,

  /// The grace period is a custom value on an account that has only the suggested ones.
  graceNotAllowed,

  /// A stage is not far enough after the one before it.
  stageTooClose,

  /// A stage is later than the account allows.
  stageTooLarge,

  /// A stage uses a custom time on an account that has only the suggested ones.
  stageNotAllowed,

  /// A stage that shares instructions would run less than a day after a missed
  /// check-in.
  stageReleaseTooEarly,

  /// The plan has no stage at all.
  noStage,

  /// Something else about the plan's fields; no more detail than "look it over".
  other,
}

/// One thing in the draft that would be refused: [stageKey] says which stage, null for
/// the grace period or the plan as a whole.
@immutable
class PlanIssue {
  const PlanIssue(this.kind, {this.stageKey});

  final PlanIssueKind kind;
  final String? stageKey;

  @override
  bool operator ==(Object other) =>
      other is PlanIssue && other.kind == kind && other.stageKey == stageKey;

  @override
  int get hashCode => Object.hash(kind, stageKey);

  @override
  String toString() => 'PlanIssue($kind, $stageKey)';
}

/// The app's mirror of the server's rules for a plan (API_SPEC.md §8). It only decides
/// what to offer and what to explain: the server still validates every save.
class PlanEditorRules {
  const PlanEditorRules({
    required this.rules,
    this.keptOffsets = const {},
    this.holdsInstructions = const {},
  });

  /// The `rules` of `GET /v1/plan` for this account's tier.
  final PlanRules rules;

  /// The times the saved plan already uses: an account that was downgraded keeps what it
  /// has, so these stay allowed even when they are not suggested ones.
  final Set<int> keptOffsets;

  /// Ids of the stages some instruction is assigned to (active or not, from the
  /// instruction list): they cannot run earlier than [PlanRules.releaseOffsetMin].
  final Set<String> holdsInstructions;

  /// The suggested times for a later stage beyond the grace choices: weeks, which only
  /// accounts with custom times may use.
  static const List<int> _longTimes = [7 * 1440, 14 * 1440, 30 * 1440];

  /// 1 and 2 hours: allowed as a grace period only with custom times.
  static const List<int> _shortGrace = [60, 120];

  bool _allowedValue(int minutes) =>
      rules.customOffsets ||
      rules.presets.contains(minutes) ||
      keptOffsets.contains(minutes);

  /// Whether [stage] shares instructions (so it may not run early or be removed).
  bool holds(EditableStage stage) =>
      stage.releaseCount > 0 ||
      (stage.id != null && holdsInstructions.contains(stage.id));

  /// How many stages the account may have at most: what the tier allows, or what the
  /// account already has when it was downgraded (it keeps them but cannot add).
  int stageLimit(int savedStages) =>
      rules.maxStages > savedStages ? rules.maxStages : savedStages;

  /// What is wrong with [minutes] as the grace period, or null.
  PlanIssueKind? graceProblem(int minutes, {bool shares = false}) {
    if (minutes < rules.graceMin || minutes > rules.graceMax) {
      return PlanIssueKind.graceOutOfRange;
    }
    if (!_allowedValue(minutes)) {
      return PlanIssueKind.graceNotAllowed;
    }
    if (shares && minutes < rules.releaseOffsetMin) {
      return PlanIssueKind.stageReleaseTooEarly;
    }
    return null;
  }

  /// What is wrong with [minutes] as the time of the stage with [key] (null: a stage not
  /// added yet) in [draft], or null. [shares] says the stage shares instructions.
  PlanIssueKind? stageProblem(
    PlanEditorDraft draft,
    String? key,
    int minutes, {
    bool shares = false,
  }) {
    if (minutes > rules.offsetMax) {
      return PlanIssueKind.stageTooLarge;
    }
    if (minutes < draft.graceMinutes + rules.stageGapMin) {
      return PlanIssueKind.stageTooClose;
    }
    for (final other in draft.stages.skip(1)) {
      if (other.key != key &&
          (other.offsetMinutes - minutes).abs() < rules.stageGapMin) {
        return PlanIssueKind.stageTooClose;
      }
    }
    if (!_allowedValue(minutes)) {
      return PlanIssueKind.stageNotAllowed;
    }
    if (shares && minutes < rules.releaseOffsetMin) {
      return PlanIssueKind.stageReleaseTooEarly;
    }
    return null;
  }

  /// The grace periods to offer: the suggested ones this account may use, and the one it
  /// has now (so what is on screen is always among the choices).
  List<int> graceChoices({int? current}) {
    final choices = <int>{
      for (final minutes in [..._shortGrace, ...rules.presets])
        if (_allowedValue(minutes) &&
            minutes >= rules.graceMin &&
            minutes <= rules.graceMax)
          minutes,
      ?current,
    };
    return choices.toList()..sort();
  }

  /// The times to offer for a stage: the suggested ones this account may use (days to a
  /// month), [current], and, unless [includeKept] is false, the times the plan already
  /// uses.
  List<int> stageChoices({int? current, bool includeKept = true}) {
    final choices = <int>{
      for (final minutes in [...rules.presets, ..._longTimes])
        if (_allowedValue(minutes) && minutes <= rules.offsetMax) minutes,
      if (includeKept) ...keptOffsets,
      ?current,
    };
    return choices.toList()..sort();
  }

  /// Everything in [draft] the server would refuse, in the order of the screen: the
  /// grace period, then each stage. It mirrors `validate_plan` of the backend for the
  /// parts a person's choices can get wrong.
  List<PlanIssue> issues(PlanEditorDraft draft) {
    final found = <PlanIssue>[];
    if (draft.stages.isEmpty) {
      return [
        if (graceProblem(draft.graceMinutes) case final kind?) PlanIssue(kind),
        const PlanIssue(PlanIssueKind.noStage),
      ];
    }
    final firstHolds = holds(draft.stages.first);
    final graceKind = graceProblem(draft.graceMinutes, shares: firstHolds);
    if (graceKind == PlanIssueKind.stageReleaseTooEarly) {
      found.add(PlanIssue(graceKind!, stageKey: draft.stages.first.key));
    } else if (graceKind != null) {
      found.add(PlanIssue(graceKind));
    }
    int? previous;
    for (var i = 0; i < draft.stages.length; i++) {
      final stage = draft.stages[i];
      final offset = stage.offsetMinutes;
      if (offset > rules.offsetMax) {
        found.add(PlanIssue(PlanIssueKind.stageTooLarge, stageKey: stage.key));
      } else if (i > 0 &&
          previous != null &&
          offset < previous + rules.stageGapMin) {
        found.add(PlanIssue(PlanIssueKind.stageTooClose, stageKey: stage.key));
      } else if (i > 0 && !_allowedValue(offset)) {
        found.add(
          PlanIssue(PlanIssueKind.stageNotAllowed, stageKey: stage.key),
        );
      }
      // The first stage's own release check is the grace period's, reported above.
      if (i > 0 && holds(stage) && offset < rules.releaseOffsetMin) {
        found.add(
          PlanIssue(PlanIssueKind.stageReleaseTooEarly, stageKey: stage.key),
        );
      }
      previous = offset;
    }
    return found;
  }
}

/// What the editor tells the person about who would (not) be told. Advice only: the
/// server decides what can be saved.
enum PlanAdviceKind {
  /// The plan has no stage.
  noStage,

  /// Stages exist, but none of them has anybody to tell.
  nobodyTold,

  /// Somebody is chosen, but nobody who has accepted and is switched on.
  nobodyReachable,

  /// This stage has nobody chosen.
  stageEmpty,

  /// A chosen contact has not answered the invitation yet.
  contactWaiting,

  /// A chosen contact declined, opted out or could not be reached.
  contactUnreachable,

  /// A chosen contact is switched off.
  contactOff,
}

/// One line of advice: about the plan ([stageKey] null) or one stage, and for the contact
/// lines the [contact].
@immutable
class PlanAdvice {
  const PlanAdvice(this.kind, {this.stageKey, this.contact});

  final PlanAdviceKind kind;
  final String? stageKey;
  final TrustedContact? contact;

  /// Whether this is about the plan as a whole (shown at the top).
  bool get isPlanLevel => stageKey == null;
}

/// The advice for [draft] given [contacts]: the plan-level gap first (at most one), then
/// the lines of each stage in order. A contact the list does not have is left out (the
/// server removes deleted contacts from the plan itself).
List<PlanAdvice> planAdvice(
  PlanEditorDraft draft,
  List<TrustedContact> contacts,
) {
  final byId = {for (final contact in contacts) contact.id: contact};
  final advice = <PlanAdvice>[];
  final chosen = <TrustedContact>[for (final id in draft.contactIds) ?byId[id]];
  if (draft.isEmpty) {
    advice.add(const PlanAdvice(PlanAdviceKind.noStage));
  } else if (chosen.isEmpty) {
    advice.add(const PlanAdvice(PlanAdviceKind.nobodyTold));
  } else if (!chosen.any((c) => c.isAccepted && c.isActive)) {
    advice.add(const PlanAdvice(PlanAdviceKind.nobodyReachable));
  }
  for (final stage in draft.stages) {
    final people = <TrustedContact>[
      for (final id in stage.contactIds) ?byId[id],
    ];
    if (people.isEmpty) {
      advice.add(PlanAdvice(PlanAdviceKind.stageEmpty, stageKey: stage.key));
      continue;
    }
    for (final contact in people) {
      final kind = !contact.isActive
          ? PlanAdviceKind.contactOff
          : contact.isUnreachable
          ? PlanAdviceKind.contactUnreachable
          : contact.isAccepted
          ? null
          : PlanAdviceKind.contactWaiting;
      if (kind != null) {
        advice.add(PlanAdvice(kind, stageKey: stage.key, contact: contact));
      }
    }
  }
  return advice;
}
