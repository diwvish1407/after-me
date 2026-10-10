import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'plan_models.freezed.dart';
part 'plan_models.g.dart';

/// What the server enforces on a plan for this account's tier (`rules` of
/// `GET /v1/plan`, API_SPEC.md §8). The app reads them to offer only choices the server
/// accepts; the server still validates every save.
@freezed
abstract class PlanRules with _$PlanRules {
  const PlanRules._();

  const factory PlanRules({
    /// The shortest and longest grace period, in minutes.
    required int graceMin,
    required int graceMax,

    /// The least time between two stages, and the latest a stage may run.
    required int stageGapMin,
    required int offsetMax,

    /// A stage that shares instructions must run at least this long after the start.
    required int releaseOffsetMin,

    /// How many stages the tier allows.
    required int maxStages,

    /// Any value in range may be chosen; without it only [presets] may.
    @Default(false) bool customOffsets,
    @Default(<int>[]) List<int> presets,
  }) = _PlanRules;

  factory PlanRules.fromJson(Map<String, dynamic> json) =>
      _$PlanRulesFromJson(json);

  /// Whether [minutes] is a grace period this tier may choose: in range and, without
  /// custom offsets, one of the [presets].
  bool allowsGrace(int minutes) =>
      minutes >= graceMin &&
      minutes <= graceMax &&
      (customOffsets || presets.contains(minutes));
}

/// One stage of the plan as the server has it: who is told [offsetMinutes] after the
/// missed deadline.
@freezed
abstract class PlanStage with _$PlanStage {
  const factory PlanStage({
    required String id,

    /// 1-based, in time order.
    required int position,

    /// Minutes after the missed deadline. Stage 1 runs when the grace period ends.
    required int offsetMinutes,

    /// Contacts notified at this stage (`notify_contact_ids`).
    @JsonKey(name: 'notify_contact_ids')
    @Default(<String>[])
    List<String> contactIds,

    /// Instructions released at this stage (Phase 6).
    @Default(0) int releaseCount,
  }) = _PlanStage;

  factory PlanStage.fromJson(Map<String, dynamic> json) =>
      _$PlanStageFromJson(json);
}

/// `GET /v1/plan` and the body of a successful `PUT /v1/plan` (API_SPEC.md §8), with
/// the `ETag` that came with it.
@freezed
abstract class Plan with _$Plan {
  const Plan._();

  const factory Plan({
    required String id,
    required int version,

    /// How long the person is reminded before anyone is told. Stage 1 runs at this
    /// offset.
    required int graceMinutes,
    required PlanRules rules,

    /// Empty for an account that never made a plan.
    @Default(<PlanStage>[]) List<PlanStage> stages,

    /// The `ETag` response header (`"plan-7"`); not part of the JSON body.
    @JsonKey(includeFromJson: false, includeToJson: false) String? etag,
  }) = _Plan;

  factory Plan.fromJson(Map<String, dynamic> json) => _$PlanFromJson(json);

  /// The value for the `If-Match` header of the next change, built from the body's
  /// [version] (the contract: the strong ETag is `"plan-<version>"`). The `ETag` header
  /// is not used: an intermediary that compresses a response may weaken it to
  /// `W/"plan-7"`, which the server (strong comparison) would answer with 412 forever.
  String get ifMatch => '"plan-$version"';

  /// Every contact some stage notifies.
  Set<String> get contactIds => {
    for (final stage in stages) ...stage.contactIds,
  };

  /// This plan as a draft that keeps every stage's id (what a `PUT` that changes
  /// nothing would send).
  PlanDraft toDraft() => PlanDraft(
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
}

/// One stage of a plan being saved. A null [id] is a new stage; the id of an existing
/// stage keeps it (and what is assigned to it) instead of replacing it.
@immutable
class PlanStageDraft {
  const PlanStageDraft({
    required this.offsetMinutes,
    required this.contactIds,
    this.id,
  });

  final String? id;
  final int offsetMinutes;
  final List<String> contactIds;

  /// An explicit `"id": null` for a new stage, as the contract's example shows.
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'offset_minutes': offsetMinutes,
    'notify_contact_ids': contactIds,
  };

  @override
  bool operator ==(Object other) =>
      other is PlanStageDraft &&
      other.id == id &&
      other.offsetMinutes == offsetMinutes &&
      listEquals(other.contactIds, contactIds);

  @override
  int get hashCode =>
      Object.hash(id, offsetMinutes, Object.hashAll(contactIds));
}

/// The plan as the person chose it: what `PUT /v1/plan` replaces the plan with. It
/// carries only what the server accepts: no ids of the plan itself and no version.
@immutable
class PlanDraft {
  const PlanDraft({required this.graceMinutes, required this.stages});

  final int graceMinutes;
  final List<PlanStageDraft> stages;

  /// The `PUT /v1/plan` body.
  Map<String, Object?> toJson() => <String, Object?>{
    'grace_minutes': graceMinutes,
    'stages': [for (final stage in stages) stage.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is PlanDraft &&
      other.graceMinutes == graceMinutes &&
      listEquals(other.stages, stages);

  @override
  int get hashCode => Object.hash(graceMinutes, Object.hashAll(stages));
}
