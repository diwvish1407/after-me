import 'package:material_ui/material_ui.dart';

import '../../../core/design_system/status_banner.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../plan/presentation/plan_preview.dart';
import '../data/models/incident_models.dart';
import 'incident_labels.dart';

/// The header of Home (and of the timeline screen) while an incident is open
/// (USER_FLOWS.md §4): what is going on, who is told when, and what is next.
@immutable
class IncidentHeadline {
  const IncidentHeadline({
    required this.kind,
    required this.title,
    required this.body,
  });

  final StatusBannerKind kind;
  final String title;
  final String body;
}

/// The headline of [incident] at [now] (the server's idea of now).
///
/// **Grace** (nobody has been told): "You missed your 8:00 PM check-in" and who will be
/// notified when. **Notified** (a contact was messaged, or the server says I'M SAFE is
/// needed): "Your contacts have been notified", who was told when, what happens next,
/// and the prompt to use I'M SAFE.
///
/// When [needsSafe] is true only because a check-in was answered with `safe_required`
/// (the incident on hand is a moment behind), the headline says only that contacts have
/// been notified and offers I'M SAFE.
///
/// Every time is the server's `scheduled_for` of the stage (or `grace_ends_at` when the
/// timeline names no stage); the phone computes none. A stage whose time has arrived but
/// has not run is never described with a time in the past: it "will be notified unless
/// you check in". A stage the server holds is said to be on hold.
///
/// While a service [interruption] is on (a Hold: nothing is sent, and the stages move
/// later by the length of it) no sentence states a time at which anybody will be told:
/// the time on hand is out of date, and the sentence says it is paused instead. Times of
/// things that already happened are facts and stay.
/// The incident on hand is a moment behind the server: a check-in was just answered with
/// `safe_required` ([needsSafe] because of that) while the incident still says nobody was
/// told. Its timeline would contradict the headline, so screens leave it out until Home
/// has read the aggregate again.
bool incidentIsBehind(Incident incident, {required bool needsSafe}) =>
    needsSafe && !incident.needsSafe && !incident.contactsMessaged;

IncidentHeadline incidentHeadline(
  BuildContext context,
  Incident incident, {
  required DateTime now,
  required bool needsSafe,
  String? timezone,
  bool interruption = false,
}) {
  final l10n = AppLocalizations.of(context);
  if (incidentIsBehind(incident, needsSafe: needsSafe)) {
    // The server just answered a check-in with `safe_required`, but the incident on hand
    // still says nobody was told: it is a moment behind. It is not used for who was told
    // or what is next (that may be out of date); only what the server said is.
    return IncidentHeadline(
      kind: StatusBannerKind.escalation,
      title: l10n.incidentNotifiedTitle,
      body: l10n.incidentSafePrompt,
    );
  }
  return needsSafe || incident.contactsMessaged
      ? _notified(context, l10n, incident, now, timezone, interruption)
      : _grace(context, l10n, incident, now, timezone, interruption);
}

IncidentHeadline _grace(
  BuildContext context,
  AppLocalizations l10n,
  Incident incident,
  DateTime now,
  String? timezone,
  bool interruption,
) {
  final stage = incident.nextStage;
  final missed = formatClockTime(
    context,
    incident.missedDueAt,
    timezone: timezone,
  );
  final title = l10n.incidentGraceTitle(missed);
  if (stage != null && stage.status == TimelineStatus.held) {
    return IncidentHeadline(
      kind: StatusBannerKind.attention,
      title: title,
      body: l10n.incidentGraceOnHold,
    );
  }
  final at = stage?.scheduledFor ?? incident.graceEndsAt;
  final due = !at.isAfter(now);
  final names = stage == null ? <String>[] : stageNames(stage);
  if (interruption) {
    // The time (which may be past) is not shown: nothing is sent until it is over.
    final who = names.isNotEmpty
        ? l10n.incidentGraceBodyNamesDue(joinNames(l10n, names))
        : l10n.incidentGraceBodyGenericDue;
    return IncidentHeadline(
      kind: StatusBannerKind.attention,
      title: title,
      body: '$who ${l10n.incidentPausedNote}',
    );
  }
  final when = incidentWhen(context, l10n, at, now: now, timezone: timezone);
  final body = names.isNotEmpty
      ? (due
            ? l10n.incidentGraceBodyNamesDue(joinNames(l10n, names))
            : l10n.incidentGraceBodyNamesAt(joinNames(l10n, names), when))
      : (due
            ? l10n.incidentGraceBodyGenericDue
            : l10n.incidentGraceBodyGenericAt(when));
  return IncidentHeadline(
    kind: StatusBannerKind.attention,
    title: title,
    body: body,
  );
}

IncidentHeadline _notified(
  BuildContext context,
  AppLocalizations l10n,
  Incident incident,
  DateTime now,
  String? timezone,
  bool interruption,
) {
  String when(DateTime at) =>
      incidentWhen(context, l10n, at, now: now, timezone: timezone);
  final sentences = <String>[];
  // Who was told, and when: one sentence per stage that the server says messaged
  // somebody. Contacts that were skipped are not named as told.
  for (final item in incident.timeline) {
    if (!item.isStage || item.status != TimelineStatus.executed) {
      continue;
    }
    final told = [
      for (final c in item.messagedContacts)
        if (c.displayName.isNotEmpty) c.displayName,
    ];
    if (told.isNotEmpty) {
      sentences.add(
        l10n.incidentNotifiedWhen(
          told.length,
          joinNames(l10n, told),
          when(item.scheduledFor),
        ),
      );
    }
  }
  // What happens next.
  final next = incident.nextStage;
  if (next == null) {
    sentences.add(l10n.incidentNextNone);
  } else if (next.status == TimelineStatus.held) {
    sentences.add(l10n.incidentNextOnHold);
  } else {
    final names = stageNames(next);
    final joined = joinNames(l10n, names);
    final count = next.releaseCount ?? 0;
    // While a service interruption is on, the time-free wording is used and its time is
    // paused (the "due" sentences are not used: nothing is due while nothing is sent).
    final due = interruption || !next.scheduledFor.isAfter(now);
    final at = interruption ? '' : when(next.scheduledFor);
    final note = interruption ? ' ${l10n.incidentPausedNote}' : '';
    sentences.add(
      names.isEmpty
          ? (interruption
                ? l10n.incidentNextUnnamedPaused
                : due
                ? l10n.incidentNextUnnamedDue
                : l10n.incidentNextUnnamed(at))
          : count > 0
          ? (due
                ? '${l10n.incidentNextNotifyShareDue(joined, count)}$note'
                : l10n.incidentNextNotifyShare(joined, at, count))
          : (due
                ? '${l10n.incidentNextNotifyDue(joined)}$note'
                : l10n.incidentNextNotify(joined, at)),
    );
  }
  sentences.add(l10n.incidentSafePrompt);
  return IncidentHeadline(
    kind: StatusBannerKind.escalation,
    title: l10n.incidentNotifiedTitle,
    body: sentences.join(' '),
  );
}
