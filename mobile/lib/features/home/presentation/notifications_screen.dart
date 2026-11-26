import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/time/clock.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../checkin/application/checkin_controller.dart';
import '../../contacts/application/contacts_controller.dart';
import '../../onboarding/application/onboarding_controller.dart';
import '../application/client_checks.dart';
import '../application/home_controller.dart';
import '../application/home_status.dart';
import '../data/models/home_models.dart';
import 'home_screen.dart';

/// One alert of the notifications section.
@immutable
class HomeNotice {
  const HomeNotice({
    required this.kind,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.path,
    this.counts = true,
  });

  final StatusBannerKind kind;
  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final String? path;

  /// Counted in the badge on the bell (good news is not).
  final bool counts;
}

/// Every alert Home has for the person, most important first: the check-in status, a
/// hole in the safety net, contacts who have not accepted (or cannot be reached), and the
/// phone's own checks. [names] maps contact ids to names when they are known.
/// [tapUnconfirmed]: the last I'M OK has not been confirmed (still sending, not received,
/// refused or too old), so nothing may read as if it had counted.
List<HomeNotice> homeNotices(
  BuildContext context,
  HomeData data, {
  required DateTime deviceNow,
  required ClientChecks checks,
  Map<String, String> names = const {},
  bool tapUnconfirmed = false,
}) {
  final l10n = AppLocalizations.of(context);
  final snapshot = data.snapshot;
  final now = data.serverNow(deviceNow);
  final timezone = snapshot.user.timezone;
  final status = homeStatus(snapshot, serverNow: now);
  final due = snapshot.checkin.nextDueAt;
  final notices = <HomeNotice>[];

  switch (status) {
    // Home says what the tap came to; "checked in" would contradict it.
    case HomeStatus.active when tapUnconfirmed:
      break;
    case HomeStatus.active:
      notices.add(
        HomeNotice(
          kind: StatusBannerKind.ok,
          icon: Icons.check_circle_rounded,
          title: l10n.homeStatusActiveTitle,
          message: due == null
              ? null
              : '${l10n.homeNextCheckIn}: ${formatSpokenDayTime(context, l10n, due, now: now, timezone: timezone)}',
          counts: false,
        ),
      );
    case HomeStatus.dueSoon:
      notices.add(
        HomeNotice(
          kind: StatusBannerKind.attention,
          icon: Icons.schedule_rounded,
          title: l10n.homeStatusDueSoonTitle(
            formatClockTime(context, due!, timezone: timezone),
            formatUntil(l10n, due.difference(now)),
          ),
        ),
      );
    case HomeStatus.overdue:
      notices.add(
        HomeNotice(
          kind: StatusBannerKind.attention,
          icon: Icons.alarm_rounded,
          title: l10n.homeStatusOverdueTitle(
            due == null
                ? ''
                : formatClockTime(context, due, timezone: timezone),
          ),
          message: l10n.homeStatusOverdueBody,
        ),
      );
    case HomeStatus.incident:
      notices.add(
        HomeNotice(
          kind: StatusBannerKind.escalation,
          icon: Icons.warning_amber_rounded,
          title: l10n.homeStatusIncidentTitle,
          message: l10n.homeStatusIncidentBody,
          actionLabel: l10n.incidentSeeTimeline,
          path: AppRoutes.homeIncident,
        ),
      );
    case HomeStatus.notActive:
      notices.add(
        HomeNotice(
          kind: StatusBannerKind.info,
          icon: Icons.playlist_add_check_rounded,
          title: l10n.homeHeroSetupTitle,
          message: l10n.homeHeroSetupBody,
          actionLabel: l10n.checklistSetUp,
          path: OnboardingStep.schedule.path,
        ),
      );
    case HomeStatus.unknown:
      notices.add(
        HomeNotice(
          kind: StatusBannerKind.info,
          icon: Icons.help_outline_rounded,
          title: l10n.homeStatusUnknownTitle,
          message: l10n.homeStatusUnknownBody,
          counts: false,
        ),
      );
  }

  final running =
      status == HomeStatus.active ||
      status == HomeStatus.dueSoon ||
      status == HomeStatus.overdue;
  final gap = running ? pickSafetyNetGap(snapshot.readiness) : null;
  if (gap != null) {
    final (message, action) = switch (gap) {
      SafetyNetGap.noContacts => (
        l10n.homeGapNoContacts,
        l10n.checklistContact,
      ),
      SafetyNetGap.noStages => (l10n.homeGapNoStages, l10n.checklistPlan),
      SafetyNetGap.stageEmpty => (l10n.homeGapStageEmpty, l10n.checklistPlan),
    };
    notices.add(
      HomeNotice(
        kind: StatusBannerKind.attention,
        icon: Icons.shield_outlined,
        title: message,
        actionLabel: action,
        path: safetyNetGapPath(gap, checkInsOn: true),
      ),
    );
  }

  for (final issue in snapshot.readiness.issues) {
    final id = issue.contactId;
    final name = id == null ? null : names[id];
    switch (issue.code) {
      case ReadinessCode.contactPending:
        notices.add(
          HomeNotice(
            kind: StatusBannerKind.info,
            icon: Icons.hourglass_top_rounded,
            title: name == null
                ? l10n.readinessContactPending(1)
                : l10n.notificationsPendingContact(name),
            actionLabel: l10n.readinessOpenContact,
            path: id == null ? AppRoutes.people : AppRoutes.contactDetail(id),
          ),
        );
      case ReadinessCode.contactDeclined ||
          ReadinessCode.contactBounced ||
          ReadinessCode.contactOptedOut:
        notices.add(
          HomeNotice(
            kind: StatusBannerKind.attention,
            icon: Icons.person_off_outlined,
            title: name ?? l10n.readinessOpenPeople,
            message: l10n.readinessContactProblem(1),
            actionLabel: l10n.readinessOpenContact,
            path: id == null ? AppRoutes.people : AppRoutes.contactDetail(id),
          ),
        );
      default:
        break;
    }
  }

  if (status != HomeStatus.notActive) {
    if (checks.notificationsOff) {
      notices.add(
        HomeNotice(
          kind: StatusBannerKind.attention,
          icon: Icons.notifications_off_outlined,
          title: l10n.readinessNotificationsOff,
          actionLabel: l10n.readinessOpenNotifications,
          path: AppRoutes.settingsNotifications,
        ),
      );
    }
    final deviceZone = checks.deviceTimezone;
    if (deviceZone != null && deviceZone != snapshot.user.timezone) {
      notices.add(
        HomeNotice(
          kind: StatusBannerKind.info,
          icon: Icons.public_rounded,
          title: l10n.readinessTimezone,
          actionLabel: l10n.readinessOpenProfile,
          path: AppRoutes.settingsProfile,
        ),
      );
    }
  }
  return notices;
}

/// How many alerts the bell shows (good news is not counted).
int homeAlertCount(
  BuildContext context,
  HomeData data, {
  required DateTime deviceNow,
  required ClientChecks checks,
}) => homeNotices(
  context,
  data,
  deviceNow: deviceNow,
  checks: checks,
).where((n) => n.counts).length;

/// Whether the last I'M OK tap is not (or no longer) confirmed by the server.
bool tapIsUnconfirmed(CheckInState tap) =>
    tap.isUnconfirmed ||
    tap.phase == CheckInPhase.failed ||
    tap.phase == CheckInPhase.expired ||
    tap.phase == CheckInPhase.safeRequired;

/// The notifications section: every alert in one list, each with the action that fixes
/// it, and a link to the full activity.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(
      Future.microtask(() {
        if (mounted) {
          unawaited(ref.read(homeControllerProvider.notifier).refresh());
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final data = ref.watch(homeControllerProvider).value;
    final checks = ref.watch(clientChecksProvider);
    final contacts = ref.watch(contactsControllerProvider).value ?? const [];
    final names = {for (final c in contacts) c.id: c.displayName};
    final notices = data == null
        ? const <HomeNotice>[]
        : homeNotices(
            context,
            data,
            deviceNow: ref.read(clockProvider)(),
            checks: checks,
            names: names,
            tapUnconfirmed: tapIsUnconfirmed(
              ref.watch(checkInControllerProvider),
            ),
          );
    return Scaffold(
      appBar: AppBar(title: Text(l10n.notificationsTitle)),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => ref.read(homeControllerProvider.notifier).refresh(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.page),
            children: [
              if (data == null)
                const LoadingView()
              else if (notices.isEmpty)
                EmptyState(
                  icon: Icons.notifications_none_rounded,
                  title: l10n.notificationsTitle,
                  message: l10n.notificationsEmpty,
                )
              else
                for (final notice in notices) ...[
                  _NoticeCard(notice: notice),
                  Gap.sm,
                ],
              Gap.sm,
              Center(
                child: AppButton.text(
                  label: l10n.notificationsSeeActivity,
                  icon: Icons.history_rounded,
                  onPressed: () => context.push(AppRoutes.settingsActivity),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.notice});

  final HomeNotice notice;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final (Color accent, Color tint) = switch (notice.kind) {
      StatusBannerKind.ok => (t.ok, t.ok.withValues(alpha: 0.10)),
      StatusBannerKind.info => (t.primary, t.primaryContainer),
      StatusBannerKind.attention => (t.attention, t.attentionContainer),
      StatusBannerKind.escalation => (
        t.escalation,
        t.escalation.withValues(alpha: 0.10),
      ),
    };
    final path = notice.path;
    return Semantics(
      container: true,
      child: GlassCard(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: path == null ? null : () => context.push(path),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: tint,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(notice.icon, color: accent, size: 22),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(notice.title, style: text.titleSmall),
                      if (notice.message != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          notice.message!,
                          style: text.bodySmall?.copyWith(color: t.textMuted),
                        ),
                      ],
                      if (notice.actionLabel != null && path != null)
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: AppButton.text(
                            label: notice.actionLabel!,
                            onPressed: () => context.push(path),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
