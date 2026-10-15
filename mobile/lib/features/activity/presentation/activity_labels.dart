import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../incidents/data/models/incident_models.dart';
import '../../incidents/presentation/incident_labels.dart';

/// One Activity entry in words: an icon, a sentence, optional smaller lines under it.
class ActivityLine {
  const ActivityLine({
    required this.icon,
    required this.text,
    this.details = const <String>[],
    this.showsTitle = false,
  });

  final IconData icon;

  /// "Brother viewed "House emergency"".
  final String text;

  /// Smaller lines under the sentence ("2 stages in your plan").
  final List<String> details;

  /// An instruction's title is part of [text] or [details]: titles are the owner's
  /// content, so the window is kept secure while such a line is on screen.
  final bool showsTitle;

  /// The whole entry as one sentence for a screen reader.
  String semantics(String when) => [when, text, ...details].join('. ');
}

String? _text(Map<String, dynamic> params, String key) {
  final value = params[key];
  if (value is! String) {
    return null;
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _count(Map<String, dynamic> params, String key) {
  final value = params[key];
  return value is num && value >= 0 ? value.toInt() : null;
}

/// The contact's name, or null when the server could not name them.
String? _name(Map<String, dynamic> params) =>
    _text(params, 'contact_display_name');

/// `release.viewed`'s `instruction_titles`: the titles that could be read, without blanks.
List<String> _titles(Map<String, dynamic> params) {
  final value = params['instruction_titles'];
  if (value is! List) {
    return const [];
  }
  return [
    for (final title in value)
      if (title is String && title.trim().isNotEmpty) title.trim(),
  ];
}

ReleaseRevokeReason? _revokeReason(Map<String, dynamic> params) {
  final reason = switch (_text(params, 'reason')) {
    'user_checkin' => ReleaseRevokeReason.userCheckin,
    'user_safe' => ReleaseRevokeReason.userSafe,
    'operator' => ReleaseRevokeReason.byOperator,
    'contact_removed' => ReleaseRevokeReason.contactRemoved,
    'contact_opted_out' => ReleaseRevokeReason.contactOptedOut,
    'instruction_removed' => ReleaseRevokeReason.instructionRemoved,
    'recipient_removed' => ReleaseRevokeReason.recipientRemoved,
    'hold_rollback' => ReleaseRevokeReason.holdRollback,
    _ => null,
  };
  return reason;
}

/// Every action of API_SPEC.md §11, in calm plain language, from [action] and [params]
/// alone (the server never sends sentences).
///
/// Anything this app version does not know is "Something changed on your account": an
/// entry is never hidden and a missing name, title or number never breaks a sentence (it
/// falls back to a wording that does not need it). [params] is empty for Home's short
/// lines, which come with an action and a time only.
ActivityLine describeActivity(
  AppLocalizations l10n,
  String action, [
  Map<String, dynamic> params = const <String, dynamic>{},
]) {
  final name = _name(params);
  switch (action) {
    case 'checkin.recorded':
      final safe = _text(params, 'kind') == 'safe';
      final web = _text(params, 'source') == 'web';
      return ActivityLine(
        icon: safe ? Icons.verified_user_outlined : Icons.check_circle_outline,
        text: safe
            ? (web ? l10n.activitySafeWeb : l10n.activitySafe)
            : (web ? l10n.activityCheckedInWeb : l10n.activityCheckedIn),
      );
    case 'contact.created':
      return ActivityLine(
        icon: Icons.person_add_alt_1_outlined,
        text: name == null
            ? l10n.activityContactCreatedNoName
            : l10n.activityContactCreated(name),
      );
    case 'contact.deleted':
      return ActivityLine(
        icon: Icons.person_remove_outlined,
        text: name == null
            ? l10n.activityContactDeletedNoName
            : l10n.activityContactDeleted(name),
      );
    case 'contact.invitation_sent':
      final again = (_count(params, 'send_count') ?? 1) > 1;
      return ActivityLine(
        icon: Icons.mail_outline_rounded,
        text: switch ((again, name)) {
          (true, null) => l10n.activityInvitationResentNoName,
          (true, final String n) => l10n.activityInvitationResent(n),
          (false, null) => l10n.activityInvitationSentNoName,
          (false, final String n) => l10n.activityInvitationSent(n),
        },
      );
    case 'contact.accepted':
      return ActivityLine(
        icon: Icons.how_to_reg_outlined,
        text: name == null
            ? l10n.activityContactAcceptedNoName
            : l10n.activityContactAccepted(name),
      );
    case 'contact.declined':
      return ActivityLine(
        icon: Icons.person_off_outlined,
        text: name == null
            ? l10n.activityContactDeclinedNoName
            : l10n.activityContactDeclined(name),
      );
    case 'contact.opted_out':
      return ActivityLine(
        icon: Icons.block_outlined,
        text: name == null
            ? l10n.activityContactOptedOutNoName
            : l10n.activityContactOptedOut(name),
      );
    case 'contact.bounced':
      return ActivityLine(
        icon: Icons.mark_email_unread_outlined,
        text: name == null
            ? l10n.activityContactBouncedNoName
            : l10n.activityContactBounced(name),
      );
    case 'schedule.updated':
      return ActivityLine(
        icon: Icons.schedule_rounded,
        text: l10n.activityScheduleUpdated,
      );
    case 'schedule.activated':
      return ActivityLine(
        icon: Icons.notifications_active_outlined,
        text: l10n.activityScheduleActivated,
      );
    case 'schedule.deactivated':
      return ActivityLine(
        icon: Icons.notifications_off_outlined,
        text: l10n.activityScheduleDeactivated,
      );
    case 'plan.updated':
      final stages = _count(params, 'stages');
      final removed = _count(params, 'removed');
      return ActivityLine(
        icon: Icons.timeline_outlined,
        text: l10n.activityPlanUpdated,
        details: [
          if (stages != null) l10n.activityPlanStages(stages),
          if (removed != null && removed > 0) l10n.activityPlanRemoved(removed),
        ],
      );
    case 'incident.opened':
      return ActivityLine(
        icon: Icons.event_busy_outlined,
        text: l10n.activityIncidentOpened,
      );
    case 'incident.resolved' || 'incident.cancelled' || 'incident.voided':
      final allClear = _count(params, 'all_clear');
      return ActivityLine(
        icon: Icons.event_available_outlined,
        text: switch (action) {
          'incident.resolved' => l10n.activityIncidentResolved,
          'incident.cancelled' => l10n.activityIncidentCancelled,
          _ => l10n.activityIncidentVoided,
        },
        details: [
          if (allClear != null && allClear > 0) l10n.activityAllClear(allClear),
        ],
      );
    case 'escalation.final_warning_sent':
      final stage = _count(params, 'stage');
      return ActivityLine(
        icon: Icons.notifications_none_rounded,
        text: stage == null
            ? l10n.activityFinalWarningNoStage
            : l10n.activityFinalWarning(stage),
      );
    case 'escalation.stage_executed':
      final stage = _count(params, 'stage');
      final notified = _count(params, 'notified');
      final skipped = _count(params, 'skipped');
      return ActivityLine(
        icon: Icons.campaign_outlined,
        text: stage == null
            ? l10n.activityStageRanNoStage
            : l10n.activityStageRan(stage),
        details: [
          if (notified != null) l10n.activityStageNotified(notified),
          if (skipped != null && skipped > 0)
            l10n.activityStageSkipped(skipped),
        ],
      );
    case 'release.created':
      final releases = _count(params, 'releases');
      final stage = _count(params, 'stage');
      return ActivityLine(
        icon: Icons.share_outlined,
        text: releases == null
            ? l10n.activityReleaseCreatedNoCount
            : l10n.activityReleaseCreated(releases),
        details: [if (stage != null) l10n.activityAtStage(stage)],
      );
    case 'release.revoked':
      final releases = _count(params, 'releases');
      final reason = _revokeReason(params);
      return ActivityLine(
        icon: Icons.undo_rounded,
        text: releases == null
            ? l10n.activityReleaseRevokedNoCount
            : l10n.activityReleaseRevoked(releases),
        details: [if (reason != null) revokeReasonText(l10n, reason)],
      );
    case 'release.viewed':
      final titles = _titles(params);
      final releases = _count(params, 'release_count') ?? 0;
      if (titles.length == 1) {
        return ActivityLine(
          icon: Icons.visibility_outlined,
          showsTitle: true,
          text: name == null
              ? l10n.activityReleaseViewedOneNoName(titles.single)
              : l10n.activityReleaseViewedOne(name, titles.single),
        );
      }
      final count = titles.length > releases ? titles.length : releases;
      if (count > 0) {
        final listed = titles.map((t) => '"$t"').join(', ');
        final more = count - titles.length;
        return ActivityLine(
          icon: Icons.visibility_outlined,
          showsTitle: titles.isNotEmpty,
          text: name == null
              ? l10n.activityReleaseViewedCountNoName(count)
              : l10n.activityReleaseViewedCount(name, count),
          details: [
            if (titles.isNotEmpty)
              more > 0 ? '$listed ${l10n.activityAndMore(more)}' : listed,
          ],
        );
      }
      return ActivityLine(
        icon: Icons.visibility_outlined,
        text: name == null
            ? l10n.activityReleaseViewedUnknownNoName
            : l10n.activityReleaseViewedUnknown(name),
      );
    case 'instruction.recipients_changed':
      final title = _text(params, 'instruction_title');
      final added = _count(params, 'added');
      final removed = _count(params, 'removed');
      return ActivityLine(
        icon: Icons.group_outlined,
        showsTitle: title != null,
        text: title == null
            ? l10n.activityRecipientsChangedNoTitle
            : l10n.activityRecipientsChanged(title),
        details: [
          if (added != null && added > 0) l10n.activityRecipientsAdded(added),
          if (removed != null && removed > 0)
            l10n.activityRecipientsRemoved(removed),
        ],
      );
    case 'auth.logout_all':
      final sessions = _count(params, 'sessions_revoked');
      return ActivityLine(
        icon: Icons.logout_rounded,
        text: l10n.activityLogoutAll,
        details: [
          if (sessions != null && sessions > 0)
            l10n.activitySessionsEnded(sessions),
        ],
      );
    case 'auth.password_changed':
      return ActivityLine(
        icon: Icons.password_rounded,
        text: l10n.activityPasswordChanged,
      );
    case 'auth.password_reset_completed':
      return ActivityLine(
        icon: Icons.password_rounded,
        text: l10n.activityPasswordReset,
      );
    case 'auth.email_changed':
      return ActivityLine(
        icon: Icons.alternate_email_rounded,
        text: l10n.activityEmailChanged,
      );
    case 'profile.timezone_changed':
      return ActivityLine(
        icon: Icons.public_rounded,
        text: l10n.activityTimezoneChanged,
      );
    case 'auth.refresh_reuse_detected':
      return ActivityLine(
        icon: Icons.shield_outlined,
        text: l10n.activityRefreshReuse,
      );
    case 'auth.login_succeeded':
      return ActivityLine(
        icon: Icons.smartphone_rounded,
        text: l10n.activityLoginNewDevice,
      );
    case 'auth.web_login_succeeded':
      return ActivityLine(
        icon: Icons.language_rounded,
        text: l10n.activityWebLogin,
      );
    case 'account.exported':
      return ActivityLine(
        icon: Icons.download_outlined,
        text: l10n.activityExported,
      );
    // Worded as a plan change, not a purchase: there is no billing in 1.0 (PRD D5).
    case 'billing.subscription_changed':
      return ActivityLine(
        icon: Icons.inventory_2_outlined,
        text: l10n.activitySubscription,
      );
    default:
      return ActivityLine(
        icon: Icons.info_outline_rounded,
        text: l10n.activityUnknown,
      );
  }
}
