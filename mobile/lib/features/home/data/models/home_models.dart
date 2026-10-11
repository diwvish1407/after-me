import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../checkin/data/models/checkin_models.dart';
import '../../../incidents/data/models/incident_models.dart';

part 'home_models.freezed.dart';
part 'home_models.g.dart';

/// What is still missing before the plan works (`readiness.issues[].code`,
/// API_SPEC.md §5). A code from a newer server is [unknown].
@JsonEnum(fieldRename: FieldRename.snake)
enum ReadinessCode {
  scheduleInactive,
  noContacts,
  contactPending,
  contactDeclined,
  contactBounced,
  contactOptedOut,
  noStages,
  stageEmpty,
  releaseContactUnverified,

  /// A code this version of the app does not know.
  unknown,
}

/// The `user` object of `GET /v1/home`.
@freezed
abstract class HomeUser with _$HomeUser {
  const HomeUser._();

  /// Redacted: the name must never reach a log.
  @override
  String toString() => 'HomeUser(<redacted>)';

  const factory HomeUser({
    required String displayName,
    required String timezone,
    @Default('free') String tier,
  }) = _HomeUser;

  factory HomeUser.fromJson(Map<String, dynamic> json) =>
      _$HomeUserFromJson(json);
}

/// `checkin.schedule` of `GET /v1/home`.
@freezed
abstract class HomeSchedule with _$HomeSchedule {
  const HomeSchedule._();

  const factory HomeSchedule({
    required int intervalDays,
    @JsonKey(fromJson: _checkedLocalTime) required String dueLocalTime,
    required int reminderLeadMinutes,
  }) = _HomeSchedule;

  factory HomeSchedule.fromJson(Map<String, dynamic> json) =>
      _$HomeScheduleFromJson(json);

  int get dueMinutes => parseLocalTime(dueLocalTime);
}

String _checkedLocalTime(String value) {
  parseLocalTime(value);
  return value;
}

/// The `checkin` object of `GET /v1/home`.
@freezed
abstract class HomeCheckIn with _$HomeCheckIn {
  const factory HomeCheckIn({
    @JsonKey(unknownEnumValue: CheckInStatus.unknown)
    required CheckInStatus status,
    DateTime? nextDueAt,
    DateTime? lastCheckinAt,
    HomeSchedule? schedule,
  }) = _HomeCheckIn;

  factory HomeCheckIn.fromJson(Map<String, dynamic> json) =>
      _$HomeCheckInFromJson(json);
}

/// `plan_summary` of `GET /v1/home`.
@freezed
abstract class PlanSummary with _$PlanSummary {
  const factory PlanSummary({
    @Default(0) int stages,
    @Default(0) int contactsTotal,
    @Default(0) int contactsVerified,
    @Default(0) int instructionsActive,
  }) = _PlanSummary;

  factory PlanSummary.fromJson(Map<String, dynamic> json) =>
      _$PlanSummaryFromJson(json);
}

/// One thing that is not ready yet, optionally about one contact.
@freezed
abstract class ReadinessIssue with _$ReadinessIssue {
  const factory ReadinessIssue({
    @JsonKey(unknownEnumValue: ReadinessCode.unknown)
    required ReadinessCode code,
    String? contactId,
  }) = _ReadinessIssue;

  factory ReadinessIssue.fromJson(Map<String, dynamic> json) =>
      _$ReadinessIssueFromJson(json);
}

/// `readiness` of `GET /v1/home`.
@freezed
abstract class Readiness with _$Readiness {
  const factory Readiness({
    @Default(false) bool ready,
    @Default(<ReadinessIssue>[]) List<ReadinessIssue> issues,
  }) = _Readiness;

  factory Readiness.fromJson(Map<String, dynamic> json) =>
      _$ReadinessFromJson(json);
}

/// One entry of `recent_activity` of `GET /v1/home`.
@freezed
abstract class RecentActivity with _$RecentActivity {
  const factory RecentActivity({
    required String action,
    required DateTime occurredAt,
  }) = _RecentActivity;

  factory RecentActivity.fromJson(Map<String, dynamic> json) =>
      _$RecentActivityFromJson(json);
}

/// `GET /v1/home` (API_SPEC.md §5): everything the Home screen needs in one call.
///
/// [incident] is the raw object: null while no incident is open, the incident object
/// (API_SPEC.md §9) while one is. It is kept as it came so that an object this app
/// version cannot read still counts as "an incident is open" (Home then shows the
/// neutral placeholder and keeps I'M OK within reach); [incidentDetails] is the typed
/// reading of it.
@freezed
abstract class HomeSnapshot with _$HomeSnapshot {
  const HomeSnapshot._();

  /// Redacted: the incident names contacts and instructions, the user their own name.
  @override
  String toString() => 'HomeSnapshot(<redacted>)';

  const factory HomeSnapshot({
    required DateTime serverTime,
    required HomeUser user,
    required HomeCheckIn checkin,
    Map<String, dynamic>? incident,
    @Default(PlanSummary()) PlanSummary planSummary,
    @Default(Readiness()) Readiness readiness,
    @Default(<RecentActivity>[]) List<RecentActivity> recentActivity,
  }) = _HomeSnapshot;

  factory HomeSnapshot.fromJson(Map<String, dynamic> json) =>
      _$HomeSnapshotFromJson(json);

  /// The open incident as the typed model, or null when there is none **or** this app
  /// version cannot read it (check [incident] to tell which).
  Incident? get incidentDetails => Incident.tryFromJson(incident);

  /// The server reports an incident, readable or not.
  bool get hasIncident => incident != null;
}
