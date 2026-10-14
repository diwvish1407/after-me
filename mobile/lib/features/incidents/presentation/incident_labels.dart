import 'package:material_ui/material_ui.dart';

import '../../../core/time/time_format.dart';
import '../../../core/time/zoned_time.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../plan/presentation/plan_preview.dart';
import '../application/incident_events.dart';
import '../data/models/incident_models.dart';

/// A time inside a sentence, in the profile's timezone, with the day counted from [now]
/// (the server's idea of now, never the phone's): "at 11:00 PM" for later today,
/// "tomorrow at 8:00 PM", "on Oct 16 at 8:00 PM".
String incidentWhen(
  BuildContext context,
  AppLocalizations l10n,
  DateTime at, {
  required DateTime now,
  String? timezone,
}) {
  if (calendarDaysBetween(now, at, timezone) == 0) {
    return l10n.incidentWhenToday(
      formatClockTime(context, at, timezone: timezone),
    );
  }
  return formatSpokenDayTime(context, l10n, at, now: now, timezone: timezone);
}

/// How a closed incident ended, in calm words. A value this app version does not know
/// (or none) is a plain "closed"; the app never claims who closed it.
String incidentOutcomeText(
  AppLocalizations l10n, {
  required bool isClosed,
  required IncidentClosedBy? closedBy,
  required IncidentStatus status,
  required bool contactsMessaged,
}) {
  if (!isClosed) {
    return l10n.incidentOutcomeOpen;
  }
  final by = switch (closedBy) {
    null || IncidentClosedBy.unknown => switch (status) {
      IncidentStatus.resolved => IncidentClosedBy.userCheckin,
      IncidentStatus.cancelled => IncidentClosedBy.userSafe,
      IncidentStatus.voided => IncidentClosedBy.operatorVoid,
      _ => IncidentClosedBy.unknown,
    },
    final known => known,
  };
  return switch (by) {
    IncidentClosedBy.userCheckin =>
      contactsMessaged
          ? l10n.incidentOutcomeCheckinTold
          : l10n.incidentOutcomeCheckin,
    IncidentClosedBy.userSafe =>
      contactsMessaged
          ? l10n.incidentOutcomeSafe
          : l10n.incidentOutcomeSafeNobody,
    IncidentClosedBy.accountDeleted => l10n.incidentOutcomeDeleted,
    IncidentClosedBy.operatorVoid => l10n.incidentOutcomeVoided,
    IncidentClosedBy.unknown => l10n.incidentOutcomeClosed,
  };
}

/// Why a release was taken back, in calm words.
String revokeReasonText(AppLocalizations l10n, ReleaseRevokeReason? reason) =>
    switch (reason) {
      ReleaseRevokeReason.userCheckin => l10n.incidentRevokeUserCheckin,
      ReleaseRevokeReason.userSafe => l10n.incidentRevokeUserSafe,
      ReleaseRevokeReason.byOperator => l10n.incidentRevokeOperator,
      ReleaseRevokeReason.contactRemoved => l10n.incidentRevokeContactRemoved,
      ReleaseRevokeReason.contactOptedOut => l10n.incidentRevokeContactOptedOut,
      ReleaseRevokeReason.instructionRemoved =>
        l10n.incidentRevokeInstructionRemoved,
      ReleaseRevokeReason.recipientRemoved =>
        l10n.incidentRevokeRecipientRemoved,
      ReleaseRevokeReason.holdRollback => l10n.incidentRevokeHoldRollback,
      ReleaseRevokeReason.unknown || null => l10n.incidentRevokeUnknown,
    };

/// The names of the contacts of [item], in the plan's order, without blanks.
/// The names of the people the all-clear went to, in an order that never changes between
/// two reads of the same answer ("Mom and Brother", never "Brother and Mom" the next
/// time): the order in which they were first notified ([notifiedOrder], contact ids, as
/// the incident's timeline lists them), and whoever that order does not know after them,
/// alphabetically (ignoring case; the id breaks a tie). Targets without a name are left
/// out.
List<String> allClearNames(
  List<AllClearTarget> targets, {
  List<String> notifiedOrder = const [],
}) {
  final rank = {
    for (var i = 0; i < notifiedOrder.length; i++) notifiedOrder[i]: i,
  };
  final named = [
    for (final target in targets)
      if (target.displayName.isNotEmpty) target,
  ];
  int byRank(AllClearTarget a, AllClearTarget b) {
    final ra = rank[a.contactId];
    final rb = rank[b.contactId];
    if (ra != null && rb != null) {
      return ra.compareTo(rb);
    }
    if (ra != null) {
      return -1;
    }
    if (rb != null) {
      return 1;
    }
    final byName = a.displayName.toLowerCase().compareTo(
      b.displayName.toLowerCase(),
    );
    if (byName != 0) {
      return byName;
    }
    final exact = a.displayName.compareTo(b.displayName);
    return exact != 0 ? exact : a.contactId.compareTo(b.contactId);
  }

  return [for (final target in named..sort(byRank)) target.displayName];
}

List<String> stageNames(TimelineItem item) => [
  for (final contact in item.contacts ?? const <TimelineContact>[])
    if (contact.displayName.isNotEmpty) contact.displayName,
];

/// What a timeline line says, ready to show: an icon, a title, a status word (never
/// colour alone) and optional detail lines.
class EventText {
  const EventText({
    required this.icon,
    required this.title,
    this.status,
    this.details = const [],
  });

  final IconData icon;
  final String title;

  /// "Done", "Scheduled", "On hold" ...; null for lines that have none.
  final String? status;
  final List<String> details;

  /// The line as one sentence for a screen reader: when, what, and how it stands.
  String semantics(String when) =>
      [when, title, ?status, ...details].join('. ');
}

String _timelineStatusText(
  AppLocalizations l10n,
  TimelineItem item, {
  required bool reminder,
}) => switch (item.status) {
  TimelineStatus.pending => l10n.incidentStatusScheduled,
  TimelineStatus.executed =>
    reminder ? l10n.incidentStatusSent : l10n.incidentStatusDone,
  TimelineStatus.held => l10n.incidentStatusHeld,
  TimelineStatus.cancelled =>
    reminder ? l10n.incidentStatusNotSent : l10n.incidentStatusStoppedStage,
  TimelineStatus.unknown => l10n.incidentStatusUnknown,
};

/// The wording of one timeline line.
///
/// Nothing here names an instruction before the server lists it as released: a stage
/// that has not run is only a count. A title (the owner's own view) appears only in the
/// view and take-back lines, which exist only for releases the server lists.
EventText describeIncidentEvent(
  BuildContext context,
  AppLocalizations l10n,
  IncidentEvent event, {
  required Incident incident,
  required DateTime now,
  String? timezone,
}) {
  final item = event.item;
  final release = event.release;
  switch (event.kind) {
    case IncidentEventKind.reminder:
      final variant = item!.variant;
      return EventText(
        icon: Icons.notifications_none_rounded,
        title: switch (variant) {
          TimelineVariant.missed => l10n.incidentEventReminderMissed,
          TimelineVariant.midpoint => l10n.incidentEventReminderMidpoint,
          TimelineVariant.lastChance => l10n.incidentEventReminderLastChance,
          _ => l10n.incidentEventReminderOther,
        },
        status: _timelineStatusText(l10n, item, reminder: true),
      );
    case IncidentEventKind.finalWarning:
      // The names of the stage this warns about, from the stage entry with the same
      // position (the warning itself carries none).
      final stage = incident.timeline
          .where((t) => t.isStage && t.stagePosition == item!.stagePosition)
          .firstOrNull;
      final names = stage == null ? <String>[] : stageNames(stage);
      final count = item!.releaseCount ?? stage?.releaseCount ?? 0;
      return EventText(
        icon: Icons.notifications_active_outlined,
        title: names.isNotEmpty && count > 0
            ? l10n.incidentEventFinalWarningFor(count, joinNames(l10n, names))
            : l10n.incidentEventFinalWarning,
        status: _timelineStatusText(l10n, item, reminder: true),
      );
    case IncidentEventKind.stage:
      final names = stageNames(item!);
      final joined = joinNames(l10n, names);
      final count = item.releaseCount ?? 0;
      switch (item.status) {
        case TimelineStatus.executed:
          final messaged = [
            for (final c in item.messagedContacts)
              if (c.displayName.isNotEmpty) c.displayName,
          ];
          final skipped = [
            for (final c in item.contacts ?? const <TimelineContact>[])
              if (c.result == ContactResult.skipped && c.displayName.isNotEmpty)
                c.displayName,
          ];
          return EventText(
            icon: Icons.mark_email_read_outlined,
            title: messaged.isEmpty
                ? l10n.incidentEventStageNobody
                : l10n.incidentEventStageDone(
                    messaged.length,
                    joinNames(l10n, messaged),
                  ),
            status: l10n.incidentStatusDone,
            details: [
              if (skipped.isNotEmpty)
                l10n.incidentEventSkipped(joinNames(l10n, skipped)),
              if (count > 0) l10n.incidentEventReleasesDone(count),
            ],
          );
        case TimelineStatus.pending:
        case TimelineStatus.held:
          return EventText(
            icon: Icons.mark_email_unread_outlined,
            title: names.isEmpty
                ? l10n.incidentEventStageGeneric
                : l10n.incidentEventStageWill(joined),
            status: _timelineStatusText(l10n, item, reminder: false),
            details: [if (count > 0) l10n.incidentEventReleasesPending(count)],
          );
        case TimelineStatus.cancelled:
          return EventText(
            icon: Icons.cancel_outlined,
            title: names.isEmpty
                ? l10n.incidentEventStageStoppedGeneric
                : l10n.incidentEventStageStopped(joined),
            status: _timelineStatusText(l10n, item, reminder: false),
          );
        case TimelineStatus.unknown:
          return EventText(
            icon: Icons.mark_email_unread_outlined,
            title: l10n.incidentEventOther,
            status: l10n.incidentStatusUnknown,
          );
      }
    case IncidentEventKind.other:
      return EventText(
        icon: Icons.more_horiz_rounded,
        title: l10n.incidentEventOther,
        status: _timelineStatusText(l10n, item!, reminder: false),
      );
    case IncidentEventKind.viewed:
      final title = release!.instructionTitle;
      final name = release.contactDisplayName;
      return EventText(
        icon: Icons.visibility_outlined,
        title: title == null || title.isEmpty
            ? l10n.incidentEventViewedUntitled(name)
            : l10n.incidentEventViewed(name, title),
        details: [
          if (release.viewCount > 1 && release.lastViewedAt != null)
            l10n.incidentEventViewedMore(
              release.viewCount,
              formatDayTime(
                context,
                l10n,
                release.lastViewedAt!,
                now: now,
                timezone: timezone,
              ),
            ),
        ],
      );
    case IncidentEventKind.revoked:
      final title = release!.instructionTitle;
      final name = release.contactDisplayName;
      return EventText(
        icon: Icons.link_off_rounded,
        title: title == null || title.isEmpty
            ? l10n.incidentEventRevokedUntitled(name)
            : l10n.incidentEventRevoked(title, name),
        details: [revokeReasonText(l10n, release.revokeReason)],
      );
    case IncidentEventKind.closed:
      final closed = event.incident!;
      return EventText(
        icon: Icons.check_circle_outline_rounded,
        title: incidentOutcomeText(
          l10n,
          isClosed: true,
          closedBy: closed.closedBy,
          status: closed.status,
          contactsMessaged: closed.contactsMessaged,
        ),
      );
  }
}
