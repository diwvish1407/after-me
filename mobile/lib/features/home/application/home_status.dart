import 'package:flutter/foundation.dart';

import '../../checkin/data/models/checkin_models.dart';
import '../data/models/home_models.dart';

/// The state of the Home header (USER_FLOWS.md §4) that follows from the aggregate and
/// the time. Pending check-ins and the offline banner are separate: they come from the
/// check-in controller and from the refresh, and are layered on top.
enum HomeStatus {
  /// Check-ins are off: the checklist is shown.
  notActive,

  /// Checked in, nothing due soon.
  active,

  /// Within the reminder lead of the deadline.
  dueSoon,

  /// The deadline has passed but the server has not reported an incident yet (the
  /// aggregate is a moment behind). Never shown as "you're checked in".
  overdue,

  /// An incident is open (Phase 5 and later), or the server said so. Home shows a
  /// neutral placeholder until those screens exist.
  incident,

  /// A status this version of the app does not know. Nothing is claimed.
  unknown,
}

/// The status of [snapshot] at [serverNow] (the server's time, estimated from the
/// phone's clock plus the offset of the last response: never the phone's clock alone).
///
/// The app never computes a deadline: the server's `next_due_at` is compared with now,
/// that is all.
HomeStatus homeStatus(HomeSnapshot snapshot, {required DateTime serverNow}) {
  final checkin = snapshot.checkin;
  if (snapshot.incident != null ||
      checkin.status == CheckInStatus.incidentOpen) {
    return HomeStatus.incident;
  }
  switch (checkin.status) {
    case CheckInStatus.inactive:
      return HomeStatus.notActive;
    case CheckInStatus.unknown:
      return HomeStatus.unknown;
    case CheckInStatus.incidentOpen:
      return HomeStatus.incident;
    case CheckInStatus.active:
      final due = checkin.nextDueAt;
      if (due == null) {
        return HomeStatus.active;
      }
      final left = due.difference(serverNow);
      if (left <= Duration.zero) {
        return HomeStatus.overdue;
      }
      final lead = Duration(
        minutes: checkin.schedule?.reminderLeadMinutes ?? 0,
      );
      if (lead > Duration.zero && left <= lead) {
        return HomeStatus.dueSoon;
      }
      return HomeStatus.active;
  }
}

/// A hole in the safety net of an account whose check-ins are on: if a check-in were
/// missed, nobody would be told, or nobody at one stage of the plan. It is more than a
/// readiness hint, so Home shows it as its own persistent banner (USER_FLOWS.md §4).
enum SafetyNetGap {
  /// No trusted contact is switched on (`no_contacts`). The fix is a contact.
  noContacts,

  /// The plan has no stage (`no_stages`). The fix is the plan.
  noStages,

  /// A plan stage notifies nobody who is switched on (`stage_empty`). The fix is the
  /// plan.
  stageEmpty,
}

/// The gap to tell the person about, or null. Contact first: a stage needs someone to
/// tell, so adding a contact is what makes the plan fixable. Per-contact issues
/// (declined, bounced, opted out, pending) are not gaps here: they have their own
/// readiness banner, and a contact who is switched on keeps the plan from being empty.
///
/// The caller shows it only while check-ins are on; an account that is not active has
/// the checklist, and an open incident makes the plan read-only.
SafetyNetGap? pickSafetyNetGap(Readiness readiness) {
  final codes = {for (final issue in readiness.issues) issue.code};
  if (codes.contains(ReadinessCode.noContacts)) {
    return SafetyNetGap.noContacts;
  }
  if (codes.contains(ReadinessCode.noStages)) {
    return SafetyNetGap.noStages;
  }
  if (codes.contains(ReadinessCode.stageEmpty)) {
    return SafetyNetGap.stageEmpty;
  }
  return null;
}

/// Which readiness banner Home shows. One at a time, highest priority first
/// (USER_FLOWS.md §4): a contact that declined or cannot be reached, a contact that
/// has not answered, notifications off, timezone mismatch.
enum ReadinessBannerKind {
  contactProblem,
  contactPending,
  notificationsOff,
  timezoneMismatch,
}

@immutable
class ReadinessBanner {
  const ReadinessBanner(this.kind, {this.contactId, this.count = 1});

  final ReadinessBannerKind kind;

  /// The contact to open when exactly one contact is affected.
  final String? contactId;

  /// How many contacts are affected (contact banners).
  final int count;

  @override
  bool operator ==(Object other) =>
      other is ReadinessBanner &&
      other.kind == kind &&
      other.contactId == contactId &&
      other.count == count;

  @override
  int get hashCode => Object.hash(kind, contactId, count);
}

/// What the phone itself knows (no new permission plumbing: both checks already exist).
@immutable
class ClientReadiness {
  const ClientReadiness({this.notificationsOff = false, this.timezoneMismatch});

  /// The notification permission is known to be off.
  final bool notificationsOff;

  /// The phone's timezone when it differs from the profile's, else null.
  final String? timezoneMismatch;
}

/// The one readiness banner to show, or null.
ReadinessBanner? pickReadinessBanner(
  Readiness readiness, {
  ClientReadiness client = const ClientReadiness(),
}) {
  List<ReadinessIssue> issuesOf(Set<ReadinessCode> codes) => [
    for (final issue in readiness.issues)
      if (codes.contains(issue.code)) issue,
  ];
  ReadinessBanner? contactBanner(
    ReadinessBannerKind kind,
    List<ReadinessIssue> issues,
  ) {
    if (issues.isEmpty) {
      return null;
    }
    final ids = {
      for (final issue in issues)
        if (issue.contactId != null) issue.contactId!,
    };
    return ReadinessBanner(
      kind,
      contactId: ids.length == 1 && issues.length == 1 ? ids.single : null,
      count: issues.length,
    );
  }

  final problem = contactBanner(
    ReadinessBannerKind.contactProblem,
    issuesOf({
      ReadinessCode.contactDeclined,
      ReadinessCode.contactBounced,
      ReadinessCode.contactOptedOut,
    }),
  );
  if (problem != null) {
    return problem;
  }
  final pending = contactBanner(
    ReadinessBannerKind.contactPending,
    issuesOf({ReadinessCode.contactPending}),
  );
  if (pending != null) {
    return pending;
  }
  if (client.notificationsOff) {
    return const ReadinessBanner(ReadinessBannerKind.notificationsOff);
  }
  if (client.timezoneMismatch != null) {
    return const ReadinessBanner(ReadinessBannerKind.timezoneMismatch);
  }
  return null;
}
