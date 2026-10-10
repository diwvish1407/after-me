import '../../plan/data/plan_repository.dart';

/// The plan's stages an instruction may be released at: the ones that run at least
/// `rules.releaseOffsetMin` (24 hours) after a missed check-in (FR-ESC-04). Any other
/// choice is answered with 422 `release_stage_too_early`. In plan order, so the earliest
/// comes first. Empty without a plan, or when no stage is late enough.
List<PlanStage> releaseStages(Plan? plan) {
  if (plan == null) {
    return const [];
  }
  return [
    for (final stage in plan.stages)
      if (stage.offsetMinutes >= plan.rules.releaseOffsetMin) stage,
  ];
}

/// The plan stage with [id], or null.
PlanStage? stageById(Plan? plan, String id) {
  if (plan == null) {
    return null;
  }
  for (final stage in plan.stages) {
    if (stage.id == id) {
      return stage;
    }
  }
  return null;
}
