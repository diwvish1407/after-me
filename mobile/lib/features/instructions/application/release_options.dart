import 'package:flutter/foundation.dart';

import '../../plan/data/plan_repository.dart';
import 'release_stages.dart';

/// A time an instruction can be released at: a stage the plan already has, or a time from
/// the tier's presets that the plan has no stage for yet (saving then adds the stage, see
/// `InstructionsController.addInstructionWithTimes`).
@immutable
class ReleaseOption {
  ReleaseOption.stage(PlanStage stage)
    : stageId = stage.id,
      offsetMinutes = stage.offsetMinutes;

  const ReleaseOption.newTime(this.offsetMinutes) : stageId = null;

  /// The stage's id, or null for a time the plan does not have yet.
  final String? stageId;

  /// Minutes after the missed check-in.
  final int offsetMinutes;

  /// The plan has no stage at this time yet.
  bool get isNew => stageId == null;

  /// What the form stores for a choice: the stage's id, or `new:<minutes>`.
  String get key => stageId ?? newTimeKey(offsetMinutes);

  static const String _prefix = 'new:';

  static String newTimeKey(int offsetMinutes) => '$_prefix$offsetMinutes';

  /// The minutes of a `new:<minutes>` key, or null for a stage id.
  static int? offsetOfKey(String key) => key.startsWith(_prefix)
      ? int.tryParse(key.substring(_prefix.length))
      : null;

  @override
  bool operator ==(Object other) =>
      other is ReleaseOption &&
      other.stageId == stageId &&
      other.offsetMinutes == offsetMinutes;

  @override
  int get hashCode => Object.hash(stageId, offsetMinutes);
}

/// Every time an instruction may be released at under [plan], earliest first: the stages
/// it has that run at least `rules.releaseOffsetMin` after the missed check-in, and the
/// presets of its tier at least that long (1, 2 and 3 days) that it has no stage for yet.
///
/// A new time is offered only where the server would accept the stage: the plan has a
/// stage already (a first stage must end the grace period), has room for one more
/// (`rules.maxStages`), and the time is later than the first stage and at least
/// `rules.stageGapMin` from every stage. Empty without a plan, or when nothing qualifies.
List<ReleaseOption> releaseOptions(Plan? plan) {
  if (plan == null) {
    return const [];
  }
  final rules = plan.rules;
  final options = <ReleaseOption>[
    for (final stage in releaseStages(plan)) ReleaseOption.stage(stage),
  ];
  final canAdd = plan.stages.isNotEmpty && plan.stages.length < rules.maxStages;
  if (canAdd) {
    final first = plan.stages.first.offsetMinutes;
    for (final preset in rules.presets) {
      final fits =
          preset >= rules.releaseOffsetMin &&
          preset <= rules.offsetMax &&
          preset > first &&
          !plan.stages.any(
            (s) => (s.offsetMinutes - preset).abs() < rules.stageGapMin,
          );
      if (fits) {
        options.add(ReleaseOption.newTime(preset));
      }
    }
  }
  options.sort((a, b) => a.offsetMinutes.compareTo(b.offsetMinutes));
  return options;
}

/// [key] as the plan has it now: a `new:<minutes>` key whose time has become a stage (the
/// person saved once and the instruction then failed, or another device added it) is that
/// stage's id.
String normaliseReleaseKey(Plan? plan, String key) {
  final offset = ReleaseOption.offsetOfKey(key);
  if (offset == null || plan == null) {
    return key;
  }
  for (final stage in plan.stages) {
    if (stage.offsetMinutes == offset) {
      return stage.id;
    }
  }
  return key;
}

/// A person and the time they receive an instruction at: a stage of the plan, or a time
/// the plan has no stage for yet.
@immutable
class RecipientChoice {
  const RecipientChoice.stage({
    required this.contactId,
    required String this.stageId,
  }) : newOffsetMinutes = null;

  const RecipientChoice.newTime({
    required this.contactId,
    required int offsetMinutes,
  }) : stageId = null,
       newOffsetMinutes = offsetMinutes;

  final String contactId;
  final String? stageId;
  final int? newOffsetMinutes;

  bool get isNew => stageId == null;

  @override
  bool operator ==(Object other) =>
      other is RecipientChoice &&
      other.contactId == contactId &&
      other.stageId == stageId &&
      other.newOffsetMinutes == newOffsetMinutes;

  @override
  int get hashCode => Object.hash(contactId, stageId, newOffsetMinutes);
}
