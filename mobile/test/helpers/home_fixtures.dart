import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/home/data/models/home_models.dart';

/// A Home aggregate for tests, in the shape of `GET /v1/home`.
HomeSnapshot homeSnapshot({
  DateTime? serverTime,
  CheckInStatus status = CheckInStatus.active,
  DateTime? nextDueAt,
  DateTime? lastCheckinAt,
  int reminderLeadMinutes = 60,
  Map<String, dynamic>? incident,
  List<ReadinessIssue> issues = const [],
  PlanSummary planSummary = const PlanSummary(contactsTotal: 1),
  String timezone = 'Asia/Kolkata',
  String name = 'Diwakar',
}) => HomeSnapshot(
  serverTime: serverTime ?? DateTime.utc(2026, 10, 8, 12),
  user: HomeUser(displayName: name, timezone: timezone),
  checkin: HomeCheckIn(
    status: status,
    nextDueAt: nextDueAt,
    lastCheckinAt: lastCheckinAt,
    schedule: HomeSchedule(
      intervalDays: 1,
      dueLocalTime: '20:00',
      reminderLeadMinutes: reminderLeadMinutes,
    ),
  ),
  incident: incident,
  planSummary: planSummary,
  readiness: Readiness(ready: issues.isEmpty, issues: issues),
);

ReadinessIssue issue(ReadinessCode code, [String? contactId]) =>
    ReadinessIssue(code: code, contactId: contactId);
