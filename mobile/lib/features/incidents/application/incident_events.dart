import 'package:flutter/foundation.dart';

import '../data/models/incident_models.dart';

/// What a line of the incident timeline is about.
enum IncidentEventKind {
  /// A reminder to the person.
  reminder,

  /// The warning to the person before a stage that shares instructions.
  finalWarning,

  /// A stage: contacts are told.
  stage,

  /// A kind of entry this app version has no wording for.
  other,

  /// A contact opened an instruction (the first time).
  viewed,

  /// A release was taken back.
  revoked,

  /// The incident was closed.
  closed,
}

/// One line of the timeline, in the order things happen.
@immutable
class IncidentEvent {
  const IncidentEvent._({
    required this.kind,
    required this.at,
    this.item,
    this.release,
    this.incident,
  });

  final IncidentEventKind kind;

  /// When it happens or happened, as the server says.
  final DateTime at;

  /// The timeline entry, for reminders, warnings and stages.
  final TimelineItem? item;

  /// The release, for views and take-backs.
  final IncidentRelease? release;

  /// The incident, for the closing line.
  final Incident? incident;
}

/// The timeline of [incident] as one list in time order: its reminders, warnings and
/// stages, each contact's first view of an instruction, each release that was taken back
/// and (when [incident] is closed with a time) how it ended.
///
/// Times are the server's: a stage that was put back is simply at its new time. Entries
/// at the same time keep the order the server gave them (entries first, then views, then
/// take-backs, then the end).
List<IncidentEvent> incidentEvents(Incident incident) {
  final events = <IncidentEvent>[
    for (final item in incident.timeline)
      IncidentEvent._(
        kind: switch (item.kind) {
          TimelineKind.userReminder => IncidentEventKind.reminder,
          TimelineKind.userFinalWarning => IncidentEventKind.finalWarning,
          TimelineKind.executeStage => IncidentEventKind.stage,
          TimelineKind.unknown => IncidentEventKind.other,
        },
        at: item.scheduledFor,
        item: item,
      ),
    for (final release in incident.releases)
      if (release.wasViewed)
        IncidentEvent._(
          kind: IncidentEventKind.viewed,
          at:
              release.firstViewedAt ??
              release.lastViewedAt ??
              release.releasedAt,
          release: release,
        ),
    for (final release in incident.releases)
      if (release.revokedAt != null)
        IncidentEvent._(
          kind: IncidentEventKind.revoked,
          at: release.revokedAt!,
          release: release,
        ),
    if (incident.closedAt != null)
      IncidentEvent._(
        kind: IncidentEventKind.closed,
        at: incident.closedAt!,
        incident: incident,
      ),
  ];
  // List.sort is not stable: the original position breaks ties.
  final indexed = [for (var i = 0; i < events.length; i++) (i, events[i])]
    ..sort((a, b) {
      final byTime = a.$2.at.compareTo(b.$2.at);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
  return [for (final (_, event) in indexed) event];
}
