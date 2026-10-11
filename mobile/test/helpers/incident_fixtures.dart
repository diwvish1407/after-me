/// Incident objects as they are on the wire (API_SPEC.md §9), for tests.
///
/// The times follow `docs/contracts/phase5/incident_current.response.json`: a check-in
/// due at 2026-10-09T14:30:00Z (8:00 PM in Asia/Kolkata), a grace period of 3 hours, a
/// midpoint reminder at 9:30 PM, a last reminder at 10:45 PM and a stage at 11:00 PM that
/// tells Mom.
library;

import 'package:afterme/features/incidents/data/incidents_repository.dart';

String iso(DateTime instant) {
  final text = instant.toUtc().toIso8601String();
  return '${text.substring(0, text.indexOf('.'))}Z';
}

const incidentId = '00000000-0000-4000-8000-000000000004';
const momId = '00000000-0000-4000-8000-000000000002';
const brotherId = '00000000-0000-4000-8000-000000000003';

final DateTime missedDue = DateTime.utc(2026, 10, 9, 14, 30);
final DateTime anchor = DateTime.utc(2026, 10, 9, 14, 30, 1);
final DateTime graceEnds = DateTime.utc(2026, 10, 9, 17, 30, 1);

Map<String, dynamic> contactJson(String id, String name, {String? result}) => {
  'id': id,
  'display_name': name,
  'result': result,
};

Map<String, dynamic> reminderJson(
  String variant,
  DateTime at, {
  String status = 'executed',
}) => {
  'kind': 'user_reminder',
  'variant': variant,
  'stage_position': null,
  'scheduled_for': iso(at),
  'status': status,
  'contacts': null,
  'release_count': null,
};

Map<String, dynamic> warningJson(
  int position,
  DateTime at, {
  String status = 'pending',
  int releaseCount = 1,
}) => {
  'kind': 'user_final_warning',
  'variant': null,
  'stage_position': position,
  'scheduled_for': iso(at),
  'status': status,
  'contacts': null,
  'release_count': releaseCount,
};

Map<String, dynamic> stageJson(
  int position,
  DateTime at, {
  String status = 'pending',
  List<Map<String, dynamic>> contacts = const [],
  int releaseCount = 0,
}) => {
  'kind': 'execute_stage',
  'variant': null,
  'stage_position': position,
  'scheduled_for': iso(at),
  'status': status,
  'contacts': contacts,
  'release_count': releaseCount,
};

Map<String, dynamic> releaseJson({
  String contactId = brotherId,
  String contactName = 'Brother',
  String instructionId = '00000000-0000-4000-8000-000000000020',
  String? title = 'House emergency',
  int? position = 2,
  DateTime? releasedAt,
  DateTime? firstViewedAt,
  DateTime? lastViewedAt,
  int viewCount = 0,
  DateTime? revokedAt,
  String? revokeReason,
}) {
  final released = releasedAt ?? DateTime.utc(2026, 10, 10, 14, 30, 1);
  return {
    'contact_id': contactId,
    'contact_display_name': contactName,
    'instruction_id': instructionId,
    'instruction_title': title,
    'stage_position': position,
    'released_at': iso(released),
    'visible_after': iso(released.add(const Duration(minutes: 5))),
    'first_viewed_at': firstViewedAt == null ? null : iso(firstViewedAt),
    'last_viewed_at': lastViewedAt == null ? null : iso(lastViewedAt),
    'view_count': viewCount,
    'revoked_at': revokedAt == null ? null : iso(revokedAt),
    'revoke_reason': revokeReason,
  };
}

/// An incident object. Defaults: in the grace period, nobody told, the golden's timeline.
Map<String, dynamic> incidentJson({
  String id = incidentId,
  String status = 'grace',
  String? requires = 'checkin',
  bool contactsMessaged = false,
  DateTime? closedAt,
  String? closedBy,
  List<Map<String, dynamic>>? timeline,
  List<Map<String, dynamic>> releases = const [],
  DateTime? serverTime,
}) => {
  'id': id,
  'status': status,
  'requires': requires,
  'missed_due_at': iso(missedDue),
  'anchor_at': iso(anchor),
  'grace_ends_at': iso(graceEnds),
  'contacts_messaged': contactsMessaged,
  'closed_at': closedAt == null ? null : iso(closedAt),
  'closed_by': closedBy,
  'timeline':
      timeline ??
      [
        reminderJson('missed', anchor),
        reminderJson(
          'midpoint',
          DateTime.utc(2026, 10, 9, 16, 0, 1),
          status: 'pending',
        ),
        reminderJson(
          'last_chance',
          DateTime.utc(2026, 10, 9, 17, 15, 1),
          status: 'pending',
        ),
        stageJson(1, graceEnds, contacts: [contactJson(momId, 'Mom')]),
      ],
  'releases': releases,
  'server_time': iso(serverTime ?? DateTime.utc(2026, 10, 9, 14, 30, 21)),
};

/// After stage 1 ran: Mom was messaged, and a second stage tells Brother tomorrow at
/// 8:00 PM and shares one instruction (a warning at 7:00 PM comes first).
Map<String, dynamic> escalatedJson({
  List<Map<String, dynamic>> releases = const [],
  bool stage2Ran = false,
  String status = 'escalating',
}) => incidentJson(
  status: stage2Ran ? 'escalated' : status,
  requires: 'safe',
  contactsMessaged: true,
  timeline: [
    reminderJson('missed', anchor),
    reminderJson('midpoint', DateTime.utc(2026, 10, 9, 16, 0, 1)),
    reminderJson('last_chance', DateTime.utc(2026, 10, 9, 17, 15, 1)),
    stageJson(
      1,
      graceEnds,
      status: 'executed',
      contacts: [contactJson(momId, 'Mom', result: 'messaged')],
    ),
    warningJson(
      2,
      DateTime.utc(2026, 10, 10, 13, 30, 1),
      status: stage2Ran ? 'executed' : 'pending',
    ),
    stageJson(
      2,
      DateTime.utc(2026, 10, 10, 14, 30, 1),
      status: stage2Ran ? 'executed' : 'pending',
      contacts: [
        contactJson(
          brotherId,
          'Brother',
          result: stage2Ran ? 'messaged' : null,
        ),
      ],
      releaseCount: 1,
    ),
  ],
  releases: releases,
);

Incident parsed(Map<String, dynamic> json) => Incident.fromJson(json);
