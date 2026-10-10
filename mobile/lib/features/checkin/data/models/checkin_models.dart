import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'checkin_models.freezed.dart';
part 'checkin_models.g.dart';

/// Where check-ins stand (API_SPEC.md §5, §6.1). A value from a newer server is
/// [unknown]: the app then claims neither "checked in" nor "not active".
@JsonEnum(fieldRename: FieldRename.snake)
enum CheckInStatus {
  /// Check-ins are off.
  inactive,

  /// Check-ins are on.
  active,

  /// A check-in was missed and an incident is open (Phase 5 and later).
  incidentOpen,

  /// A status this version of the app does not know.
  unknown,
}

final RegExp _localTime = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');

/// "20:00" -> 1200 (minutes after midnight). Throws a [FormatException] for anything
/// that is not `HH:MM` on a 24-hour clock.
int parseLocalTime(String value) {
  final match = _localTime.firstMatch(value);
  if (match == null) {
    throw FormatException('Expected HH:MM', value);
  }
  return int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
}

/// 1200 -> "20:00". Minutes beyond a day wrap.
String formatLocalTime(int minutes) {
  final wrapped = ((minutes % 1440) + 1440) % 1440;
  final hours = (wrapped ~/ 60).toString().padLeft(2, '0');
  final rest = (wrapped % 60).toString().padLeft(2, '0');
  return '$hours:$rest';
}

String _checkedLocalTime(String value) {
  parseLocalTime(value);
  return value;
}

/// The check-in schedule as the person chooses it: "Check in every [intervalDays]
/// day(s) by [dueMinutes]", with a reminder [reminderLeadMinutes] before.
@immutable
class CheckInSchedule {
  const CheckInSchedule({
    this.intervalDays = 1,
    this.dueMinutes = 20 * 60,
    this.reminderLeadMinutes = 60,
    this.timezone = 'UTC',
  });

  /// Days between check-ins (1-30 on the server; 1, 2, 3 and 7 are offered in
  /// onboarding).
  final int intervalDays;

  /// Local due time as minutes after midnight (20:00 -> 1200), in the profile timezone.
  final int dueMinutes;

  /// The reminder is sent this long before the deadline; 0 means no reminder.
  final int reminderLeadMinutes;

  /// IANA timezone of the profile. Read-only here: the server uses the profile's.
  final String timezone;

  CheckInSchedule copyWith({
    int? intervalDays,
    int? dueMinutes,
    int? reminderLeadMinutes,
    String? timezone,
  }) => CheckInSchedule(
    intervalDays: intervalDays ?? this.intervalDays,
    dueMinutes: dueMinutes ?? this.dueMinutes,
    reminderLeadMinutes: reminderLeadMinutes ?? this.reminderLeadMinutes,
    timezone: timezone ?? this.timezone,
  );

  /// The `PUT /v1/checkin/schedule` body. The server decides every time from these
  /// three values; no instant is ever sent.
  Map<String, Object?> toJson() => <String, Object?>{
    'interval_days': intervalDays,
    'due_local_time': formatLocalTime(dueMinutes),
    'reminder_lead_minutes': reminderLeadMinutes,
  };

  @override
  bool operator ==(Object other) =>
      other is CheckInSchedule &&
      other.intervalDays == intervalDays &&
      other.dueMinutes == dueMinutes &&
      other.reminderLeadMinutes == reminderLeadMinutes &&
      other.timezone == timezone;

  @override
  int get hashCode =>
      Object.hash(intervalDays, dueMinutes, reminderLeadMinutes, timezone);
}

/// `GET /v1/checkin/schedule` and the body of every schedule-changing call
/// (API_SPEC.md §6.1), with the `ETag` that must be sent back as `If-Match`.
@freezed
abstract class ScheduleSnapshot with _$ScheduleSnapshot {
  const ScheduleSnapshot._();

  const factory ScheduleSnapshot({
    required int intervalDays,
    @JsonKey(fromJson: _checkedLocalTime) required String dueLocalTime,
    required int reminderLeadMinutes,
    required String timezone,
    @JsonKey(unknownEnumValue: CheckInStatus.unknown)
    required CheckInStatus status,
    required int version,
    DateTime? nextDueAt,
    DateTime? lastCheckinAt,

    /// The `ETag` response header (`"sched-4"`); not part of the JSON body.
    @JsonKey(includeFromJson: false, includeToJson: false) String? etag,
  }) = _ScheduleSnapshot;

  factory ScheduleSnapshot.fromJson(Map<String, dynamic> json) =>
      _$ScheduleSnapshotFromJson(json);

  /// Local due time as minutes after midnight.
  int get dueMinutes => parseLocalTime(dueLocalTime);

  /// What the person chose, without the server's bookkeeping.
  CheckInSchedule get settings => CheckInSchedule(
    intervalDays: intervalDays,
    dueMinutes: dueMinutes,
    reminderLeadMinutes: reminderLeadMinutes,
    timezone: timezone,
  );

  /// Check-ins are turned on (also while an incident is open).
  bool get isOn =>
      status == CheckInStatus.active || status == CheckInStatus.incidentOpen;

  /// The value for the `If-Match` header of the next change, built from the body's
  /// [version] (the contract: the strong ETag is `"sched-<version>"`). The `ETag`
  /// header is not used: an intermediary that compresses a response may weaken it to
  /// `W/"sched-4"`, which the server (strong comparison) would answer with 412 forever.
  String get ifMatch => '"sched-$version"';
}

/// What a check-in is.
@JsonEnum()
enum CheckInKind {
  ok,
  safe,

  /// A kind this version of the app does not know.
  unknown,
}

/// Where a check-in came from.
@JsonEnum()
enum CheckInSource {
  app,
  web,

  /// A source this version of the app does not know.
  unknown,
}

/// The `checkin` object of `POST /v1/checkins`.
@freezed
abstract class CheckInReceipt with _$CheckInReceipt {
  const factory CheckInReceipt({
    required String id,
    @JsonKey(unknownEnumValue: CheckInKind.unknown) required CheckInKind kind,
    required DateTime receivedAt,
  }) = _CheckInReceipt;

  factory CheckInReceipt.fromJson(Map<String, dynamic> json) =>
      _$CheckInReceiptFromJson(json);
}

/// `POST /v1/checkins` -> 200. [nextDueAt] is null while the schedule is inactive.
@freezed
abstract class CheckInResult with _$CheckInResult {
  const factory CheckInResult({
    required CheckInReceipt checkin,
    required DateTime serverTime,
    DateTime? nextDueAt,
    @Default(false) bool incidentResolved,
  }) = _CheckInResult;

  factory CheckInResult.fromJson(Map<String, dynamic> json) =>
      _$CheckInResultFromJson(json);
}

/// One row of `GET /v1/checkins`.
@freezed
abstract class CheckInHistoryItem with _$CheckInHistoryItem {
  const factory CheckInHistoryItem({
    required String id,
    @JsonKey(unknownEnumValue: CheckInKind.unknown) required CheckInKind kind,
    @JsonKey(unknownEnumValue: CheckInSource.unknown)
    required CheckInSource source,
    required DateTime receivedAt,
  }) = _CheckInHistoryItem;

  factory CheckInHistoryItem.fromJson(Map<String, dynamic> json) =>
      _$CheckInHistoryItemFromJson(json);
}

/// `GET /v1/checkins` (newest first). [nextCursor] is null on the last page.
@freezed
abstract class CheckInHistoryPage with _$CheckInHistoryPage {
  const factory CheckInHistoryPage({
    @Default(<CheckInHistoryItem>[]) List<CheckInHistoryItem> items,
    String? nextCursor,
  }) = _CheckInHistoryPage;

  factory CheckInHistoryPage.fromJson(Map<String, dynamic> json) =>
      _$CheckInHistoryPageFromJson(json);
}
