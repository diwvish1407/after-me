import 'package:afterme/features/plan/data/plan_repository.dart';

/// The rules of `GET /v1/plan` for a free account (presets only, two stages) or one with
/// custom offsets (the contract's example in `docs/contracts/phase5`).
PlanRules planRules({
  bool custom = false,
  int graceMin = 60,
  int graceMax = 4320,
  int? maxStages,
}) => PlanRules(
  graceMin: graceMin,
  graceMax: graceMax,
  stageGapMin: 30,
  offsetMax: 43200,
  releaseOffsetMin: 1440,
  maxStages: maxStages ?? (custom ? 10 : 2),
  customOffsets: custom,
  presets: const [180, 360, 720, 1440, 2880, 4320],
);

/// A plan as the server answers it.
Plan testPlan({
  int version = 1,
  int grace = 180,
  List<PlanStage> stages = const [],
  PlanRules? rules,
}) => Plan(
  id: '00000000-0000-4000-8000-000000000001',
  version: version,
  graceMinutes: grace,
  stages: stages,
  rules: rules ?? planRules(),
  etag: '"plan-$version"',
);
