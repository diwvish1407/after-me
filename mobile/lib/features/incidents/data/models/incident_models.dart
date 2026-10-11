import 'package:freezed_annotation/freezed_annotation.dart';

part 'incident_models.freezed.dart';
part 'incident_models.g.dart';

/// Where an incident stands (`status`, API_SPEC.md §9). A value from a newer server is
/// [unknown]: the app then claims neither that the incident is open nor that it is over.
@JsonEnum(fieldRename: FieldRename.snake)
enum IncidentStatus {
  /// A check-in was missed and nobody has been told yet.
  grace,

  /// Contacts are being told, stage by stage.
  escalating,

  /// Every stage has run.
  escalated,

  /// The person checked in before anyone was told.
  resolved,

  /// The person confirmed they are safe (I'M SAFE).
  cancelled,

  /// Closed by the operator after a problem on the service's side.
  voided,

  /// A status this version of the app does not know.
  unknown,
}

/// What stops an open incident (`requires`, API_SPEC.md §9). A value from a newer server
/// is [unknown]; the screens then follow `contacts_messaged`, which says the same thing.
@JsonEnum(fieldRename: FieldRename.snake)
enum IncidentRequires {
  /// Nobody has been messaged: I'M OK resolves it.
  checkin,

  /// Somebody has been messaged: I'M SAFE is needed.
  safe,

  /// A value this version of the app does not know.
  unknown,
}

/// How a closed incident was closed (`closed_by`). A value from a newer server is
/// [unknown] and is worded as a plain "closed".
@JsonEnum(fieldRename: FieldRename.snake)
enum IncidentClosedBy {
  userCheckin,
  userSafe,
  accountDeleted,
  operatorVoid,

  /// A value this version of the app does not know.
  unknown,
}

/// What a timeline entry is (`kind`).
@JsonEnum(fieldRename: FieldRename.snake)
enum TimelineKind {
  /// A reminder to the person.
  userReminder,

  /// The warning to the person before a stage that shares instructions.
  userFinalWarning,

  /// A stage of the plan: contacts are told (and instructions shared).
  executeStage,

  /// A kind this version of the app does not know.
  unknown,
}

/// Which reminder (`variant`) of [TimelineKind.userReminder].
@JsonEnum(fieldRename: FieldRename.snake)
enum TimelineVariant {
  missed,
  midpoint,
  lastChance,

  /// A variant this version of the app does not know.
  unknown,
}

/// What became of an entry (`status`). A held entry is never run automatically: it waits
/// for the service's operator.
@JsonEnum()
enum TimelineStatus {
  pending,
  executed,
  cancelled,
  held,

  /// A status this version of the app does not know. Nothing is claimed for it.
  unknown,
}

/// What happened for one contact of a stage (`contacts[].result`).
@JsonEnum()
enum ContactResult {
  messaged,
  skipped,

  /// A result this version of the app does not know. It is not shown as "notified".
  unknown,
}

/// Why a release was taken back (`revoke_reason`, ESCALATION_ENGINE.md). A value from a
/// newer server is [unknown] and is worded as a plain "no longer available".
@JsonEnum(fieldRename: FieldRename.snake)
enum ReleaseRevokeReason {
  /// The person checked in.
  userCheckin,

  /// The person confirmed they are safe.
  userSafe,

  /// The operator closed the incident or took it back.
  @JsonValue('operator')
  byOperator,

  /// The contact was removed from the plan.
  contactRemoved,

  /// The contact asked not to be contacted.
  contactOptedOut,

  /// The instruction was switched off or deleted.
  instructionRemoved,

  /// The person was taken off the instruction.
  recipientRemoved,

  /// A stage was put back after an interruption on the service's side.
  holdRollback,

  /// A reason this version of the app does not know.
  unknown,
}

/// One contact of a stage in the timeline.
@freezed
abstract class TimelineContact with _$TimelineContact {
  const TimelineContact._();

  /// Redacted: names must never reach a log.
  @override
  String toString() => 'TimelineContact(<redacted>)';

  const factory TimelineContact({
    required String id,
    @Default('') String displayName,
    @JsonKey(unknownEnumValue: ContactResult.unknown) ContactResult? result,
  }) = _TimelineContact;

  factory TimelineContact.fromJson(Map<String, dynamic> json) =>
      _$TimelineContactFromJson(json);

  /// The server confirmed this person was messaged.
  bool get wasMessaged => result == ContactResult.messaged;
}

/// One entry of an incident's timeline: a reminder, the warning before a release, or a
/// stage. [scheduledFor] is what the server says: a stage that was put back (a Hold, a
/// late stage) is simply at its new time.
@freezed
abstract class TimelineItem with _$TimelineItem {
  const TimelineItem._();

  /// Redacted: it carries contact names.
  @override
  String toString() => 'TimelineItem(<redacted>)';

  const factory TimelineItem({
    @JsonKey(unknownEnumValue: TimelineKind.unknown) required TimelineKind kind,
    @JsonKey(unknownEnumValue: TimelineVariant.unknown)
    TimelineVariant? variant,
    int? stagePosition,
    required DateTime scheduledFor,
    @JsonKey(unknownEnumValue: TimelineStatus.unknown)
    required TimelineStatus status,
    List<TimelineContact>? contacts,
    int? releaseCount,
  }) = _TimelineItem;

  factory TimelineItem.fromJson(Map<String, dynamic> json) =>
      _$TimelineItemFromJson(json);

  bool get isStage => kind == TimelineKind.executeStage;

  /// Still to happen (or waiting): `pending` and `held`.
  bool get isUpcoming =>
      status == TimelineStatus.pending || status == TimelineStatus.held;

  /// Contacts of this stage that the server says were messaged.
  List<TimelineContact> get messagedContacts => [
    for (final contact in contacts ?? const <TimelineContact>[])
      if (contact.wasMessaged) contact,
  ];
}

/// One instruction released to one contact in an incident, as its owner sees it.
///
/// [instructionTitle] is the owner's own view and is null when the server could not open
/// it. Nothing here is shown before the server lists it: a stage that has not run has only
/// a `release_count`.
@freezed
abstract class IncidentRelease with _$IncidentRelease {
  const IncidentRelease._();

  /// Redacted: contact names and instruction titles must never reach a log.
  @override
  String toString() => 'IncidentRelease(<redacted>)';

  const factory IncidentRelease({
    required String contactId,
    @Default('') String contactDisplayName,
    required String instructionId,
    String? instructionTitle,
    int? stagePosition,
    required DateTime releasedAt,
    DateTime? visibleAfter,
    DateTime? firstViewedAt,
    DateTime? lastViewedAt,
    @Default(0) int viewCount,
    DateTime? revokedAt,
    @JsonKey(unknownEnumValue: ReleaseRevokeReason.unknown)
    ReleaseRevokeReason? revokeReason,
  }) = _IncidentRelease;

  factory IncidentRelease.fromJson(Map<String, dynamic> json) =>
      _$IncidentReleaseFromJson(json);

  /// The contact opened it at least once. That cannot be undone.
  bool get wasViewed => firstViewedAt != null || viewCount > 0;

  /// It was taken back; the contact can no longer open it.
  bool get isRevoked => revokedAt != null;
}

/// An incident (API_SPEC.md §9): `GET /incidents/{id}`, `incident` of
/// `GET /incidents/current` and of `GET /home`.
@freezed
abstract class Incident with _$Incident {
  const Incident._();

  /// Redacted: the timeline names contacts and the releases name instructions.
  @override
  String toString() => 'Incident(<redacted>)';

  const factory Incident({
    required String id,
    @JsonKey(unknownEnumValue: IncidentStatus.unknown)
    required IncidentStatus status,
    @JsonKey(unknownEnumValue: IncidentRequires.unknown)
    IncidentRequires? requires,
    required DateTime missedDueAt,
    required DateTime anchorAt,
    required DateTime graceEndsAt,
    @Default(false) bool contactsMessaged,
    DateTime? closedAt,
    @JsonKey(unknownEnumValue: IncidentClosedBy.unknown)
    IncidentClosedBy? closedBy,
    @Default(<TimelineItem>[]) List<TimelineItem> timeline,
    @Default(<IncidentRelease>[]) List<IncidentRelease> releases,
    required DateTime serverTime,
  }) = _Incident;

  factory Incident.fromJson(Map<String, dynamic> json) =>
      _$IncidentFromJson(json);

  /// The incident from a raw object, or null when this app version cannot read it. A
  /// screen that gets null shows what it can without the details; it never guesses.
  static Incident? tryFromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return null;
    }
    try {
      return Incident.fromJson(json);
    } on Object {
      return null;
    }
  }

  /// The incident is over. An unknown status with no `closed_at` is **not** closed: the
  /// app never claims an incident ended unless the server said so.
  bool get isClosed =>
      closedAt != null ||
      status == IncidentStatus.resolved ||
      status == IncidentStatus.cancelled ||
      status == IncidentStatus.voided;

  bool get isOpen => !isClosed;

  /// Contacts told so far, once each, in the order they were told.
  List<TimelineContact> get notifiedContacts {
    final seen = <String>{};
    return [
      for (final item in timeline)
        if (item.isStage)
          for (final contact in item.messagedContacts)
            if (seen.add(contact.id)) contact,
    ];
  }

  /// Whether the person must use I'M SAFE rather than I'M OK. `requires` says it; when
  /// the server sends a value this version does not know, `contacts_messaged` decides.
  bool get needsSafe => switch (requires) {
    IncidentRequires.safe => true,
    IncidentRequires.checkin => false,
    _ => contactsMessaged,
  };

  /// The first stage that is still to run (pending or held), by its time.
  TimelineItem? get nextStage {
    TimelineItem? next;
    for (final item in timeline) {
      if (item.isStage &&
          item.isUpcoming &&
          (next == null || item.scheduledFor.isBefore(next.scheduledFor))) {
        next = item;
      }
    }
    return next;
  }
}

/// One row of `GET /incidents`: no timeline and no names.
@freezed
abstract class IncidentSummary with _$IncidentSummary {
  const IncidentSummary._();

  const factory IncidentSummary({
    required String id,
    @JsonKey(unknownEnumValue: IncidentStatus.unknown)
    required IncidentStatus status,
    required DateTime missedDueAt,
    required DateTime openedAt,
    DateTime? closedAt,
    @JsonKey(unknownEnumValue: IncidentClosedBy.unknown)
    IncidentClosedBy? closedBy,
    @Default(false) bool contactsMessaged,
  }) = _IncidentSummary;

  factory IncidentSummary.fromJson(Map<String, dynamic> json) =>
      _$IncidentSummaryFromJson(json);

  bool get isClosed =>
      closedAt != null ||
      status == IncidentStatus.resolved ||
      status == IncidentStatus.cancelled ||
      status == IncidentStatus.voided;
}

/// `GET /incidents` (newest first). [nextCursor] is null on the last page.
@freezed
abstract class IncidentPage with _$IncidentPage {
  const factory IncidentPage({
    @Default(<IncidentSummary>[]) List<IncidentSummary> items,
    String? nextCursor,
  }) = _IncidentPage;

  factory IncidentPage.fromJson(Map<String, dynamic> json) =>
      _$IncidentPageFromJson(json);
}

/// One contact the all-clear is going to (`all_clear_sent_to[]`).
@freezed
abstract class AllClearTarget with _$AllClearTarget {
  const AllClearTarget._();

  /// Redacted: names must never reach a log.
  @override
  String toString() => 'AllClearTarget(<redacted>)';

  const factory AllClearTarget({
    required String contactId,
    @Default('') String displayName,
  }) = _AllClearTarget;

  factory AllClearTarget.fromJson(Map<String, dynamic> json) =>
      _$AllClearTargetFromJson(json);
}

/// `POST /incidents/{id}/safe` -> 200. [nextDueAt] is null while the schedule is off.
@freezed
abstract class SafeResult with _$SafeResult {
  const SafeResult._();

  /// Redacted: it names the contacts who are told.
  @override
  String toString() => 'SafeResult(<redacted>)';

  const factory SafeResult({
    required String incidentId,
    @Default(<AllClearTarget>[]) List<AllClearTarget> allClearSentTo,
    DateTime? nextDueAt,
    required DateTime serverTime,
  }) = _SafeResult;

  factory SafeResult.fromJson(Map<String, dynamic> json) =>
      _$SafeResultFromJson(json);
}
