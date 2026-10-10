import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/time/clock.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/application/me_controller.dart';
import '../../checkin/application/checkin_controller.dart';
import '../../checkin/data/models/checkin_models.dart';
import '../../checkin/presentation/schedule_labels.dart';
import '../../onboarding/application/onboarding_controller.dart';
import '../../onboarding/application/setup_controller.dart';
import '../application/client_checks.dart';
import '../application/home_controller.dart';
import '../application/home_status.dart';
import '../data/models/home_models.dart';

/// Home (USER_FLOWS.md §4, §5): the status, I'M OK, the next and last check-in, the plan,
/// a persistent banner while the safety net has a gap, and the one readiness banner that
/// matters most.
///
/// Everything time-related is decided from the server's `server_time` (kept as an
/// offset from the phone's clock), and shown in the profile's timezone. The screen
/// never claims a check-in that the server has not confirmed.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  Timer? _ticker;
  bool _activating = false;
  AppFailure? _activationFailure;
  List<String>? _missing;

  /// The deadline a "it has passed, read Home again" refresh was already made for.
  DateTime? _refreshedForDue;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Re-evaluates "due soon" as time passes; the decision itself always uses the
    // clock plus the server offset, the timer only triggers a redraw.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
    unawaited(Future.microtask(_readClientChecks));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _readClientChecks() async {
    if (mounted) {
      await ref.read(clientChecksProvider.notifier).refresh();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      // A check-in that was not confirmed is sent again with its own key, and the
      // aggregate is read again (the app may have been away for hours).
      unawaited(ref.read(checkInControllerProvider.notifier).onResumed());
      unawaited(ref.read(homeControllerProvider.notifier).refresh());
      unawaited(_readClientChecks());
    }
  }

  void _tick() {
    if (!mounted) {
      return;
    }
    final data = ref.read(homeControllerProvider).value;
    if (data != null) {
      final now = data.serverNow(ref.read(clockProvider)());
      final status = homeStatus(data.snapshot, serverNow: now);
      final due = data.snapshot.checkin.nextDueAt;
      // The deadline passed while Home was open: the server may have moved on.
      if (status == HomeStatus.overdue && due != _refreshedForDue) {
        _refreshedForDue = due;
        unawaited(ref.read(homeControllerProvider.notifier).refresh());
      }
    }
    setState(() {});
  }

  Future<void> _pullToRefresh() async {
    await ref.read(homeControllerProvider.notifier).refresh();
    await _readClientChecks();
  }

  Future<void> _turnOn() async {
    setState(() {
      _activating = true;
      _activationFailure = null;
      _missing = null;
    });
    try {
      final outcome = await ref
          .read(setupControllerProvider.notifier)
          .activate();
      if (mounted) {
        setState(() {
          _activating = false;
          _missing = outcome.activated ? null : outcome.missing;
        });
      }
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(() {
          _activating = false;
          _activationFailure = failure;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final home = ref.watch(homeControllerProvider);
    final checkIn = ref.watch(checkInControllerProvider);
    final data = home.value;
    final failure = home.error;
    Widget content;
    if (data != null) {
      content = _loaded(context, data, checkIn);
    } else if (failure != null) {
      final problem = failure is AppFailure
          ? failure
          : UnknownFailure(cause: failure);
      content = problem.isTransient
          ? _unavailable(context, problem, checkIn)
          : ErrorView(
              failure: problem,
              onRetry: () => unawaited(
                ref.read(homeControllerProvider.notifier).refresh(),
              ),
            );
    } else {
      content = const LoadingView();
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.navHome)),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _pullToRefresh,
          child: CenteredScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: content,
          ),
        ),
      ),
    );
  }

  /// The profile's timezone, from the aggregate when there is one.
  String? _timezone(HomeData? data) =>
      data?.snapshot.user.timezone ??
      ref.watch(meControllerProvider).value?.profile.timezone;

  // --- Home could not be loaded at all --------------------------------------------

  /// No status is known (a cold start while offline). I'M OK still works: it queues as
  /// a pending check-in and is sent when the connection is back.
  Widget _unavailable(
    BuildContext context,
    AppFailure failure,
    CheckInState checkIn,
  ) {
    final l10n = AppLocalizations.of(context);
    final timezone = _timezone(null);
    final now = ref.read(clockProvider)();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusBanner(
          kind: StatusBannerKind.attention,
          title: l10n.homeOfflineBanner,
          message: l10n.homeUnavailableBody,
        ),
        Gap.md,
        // A tap that was too old to send is most likely found right here: the app was
        // opened again after a long time without a connection.
        if (checkIn.phase == CheckInPhase.expired) ...[
          _expiredNotice(context, checkIn, timezone, now),
          Gap.md,
        ],
        ..._checkInSection(
          context,
          checkIn,
          buttonState: null,
          timezone: timezone,
          now: now,
        ),
        Gap.md,
        AppButton.secondary(
          label: l10n.retry,
          onPressed: () =>
              unawaited(ref.read(homeControllerProvider.notifier).refresh()),
          expand: true,
        ),
      ],
    );
  }

  // --- Home is loaded ---------------------------------------------------------------

  Widget _loaded(BuildContext context, HomeData data, CheckInState checkIn) {
    final l10n = AppLocalizations.of(context);
    final snapshot = data.snapshot;
    final now = data.serverNow(ref.read(clockProvider)());
    final timezone = _timezone(data);
    final status = homeStatus(snapshot, serverNow: now);
    final name =
        ref.watch(meControllerProvider).value?.profile.displayName ??
        snapshot.user.displayName;
    final checks = ref.watch(clientChecksProvider);
    final banner = status == HomeStatus.notActive
        ? null
        : pickReadinessBanner(
            snapshot.readiness,
            client: ClientReadiness(
              notificationsOff: checks.notificationsOff,
              timezoneMismatch:
                  checks.deviceTimezone != null &&
                      checks.deviceTimezone != snapshot.user.timezone
                  ? checks.deviceTimezone
                  : null,
            ),
          );
    // Check-ins are on but nobody would be told: not dismissible, and it never replaces
    // the status, I'M OK or the other banners below it. An account that is not active has
    // the checklist, and during an incident the plan is read-only.
    final gap = switch (status) {
      HomeStatus.active ||
      HomeStatus.dueSoon ||
      HomeStatus.overdue => pickSafetyNetGap(snapshot.readiness),
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (data.stale) ...[
          StatusBanner(
            kind: StatusBannerKind.info,
            message: l10n.homeOfflineBanner,
          ),
          Gap.md,
        ],
        if (name.isNotEmpty) ...[
          Text(
            l10n.homeGreeting(name),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Gap.md,
        ],
        if (gap != null) ...[_SafetyNetGapBanner(gap: gap), Gap.md],
        if (banner != null) ...[_ReadinessBannerView(banner: banner), Gap.md],
        _statusHeader(context, data, checkIn, status, now, timezone),
        if (status == HomeStatus.notActive)
          ..._notActive(context, snapshot, checkIn, timezone, now)
        else
          ..._running(context, data, checkIn, status, now, timezone),
      ],
    );
  }

  /// The header: what a pending check-in says takes precedence over the schedule.
  Widget _statusHeader(
    BuildContext context,
    HomeData data,
    CheckInState checkIn,
    HomeStatus status,
    DateTime now,
    String? timezone,
  ) {
    final l10n = AppLocalizations.of(context);
    // Like a pending tap, this takes precedence over the schedule: nothing here may read
    // as if the tap had counted.
    if (checkIn.phase == CheckInPhase.expired) {
      return _expiredNotice(context, checkIn, timezone, now);
    }
    final due = data.snapshot.checkin.nextDueAt;
    final (
      StatusBannerKind kind,
      String title,
      String? body,
    ) = switch (checkIn.phase) {
      CheckInPhase.safeRequired => (
        StatusBannerKind.escalation,
        l10n.homeSafeRequiredTitle,
        l10n.homeSafeRequiredBody,
      ),
      CheckInPhase.pending ||
      CheckInPhase.rateLimited ||
      CheckInPhase.signInRequired => (
        StatusBannerKind.attention,
        l10n.homePendingTitle,
        _pendingBody(context, checkIn, timezone),
      ),
      // Another attempt at a tap that is not confirmed: still "not received yet".
      CheckInPhase.sending when checkIn.retrying => (
        StatusBannerKind.attention,
        l10n.homePendingTitle,
        _pendingBody(context, checkIn, timezone),
      ),
      CheckInPhase.failed => (
        StatusBannerKind.attention,
        l10n.homeFailedTitle,
        failureMessage(l10n, checkIn.failure!),
      ),
      _ => switch (status) {
        HomeStatus.notActive => (
          StatusBannerKind.info,
          _checklistReady(data) ? l10n.homeReadyTitle : l10n.homeFinishTitle,
          _checklistReady(data) ? l10n.homeReadyBody : l10n.homeFinishBody,
        ),
        HomeStatus.active => (
          StatusBannerKind.ok,
          l10n.homeStatusActiveTitle,
          null,
        ),
        HomeStatus.dueSoon => (
          StatusBannerKind.attention,
          l10n.homeStatusDueSoonTitle(
            formatClockTime(context, due!, timezone: timezone),
            formatUntil(l10n, due.difference(now)),
          ),
          null,
        ),
        HomeStatus.overdue => (
          StatusBannerKind.attention,
          l10n.homeStatusOverdueTitle(
            due == null
                ? ''
                : formatClockTime(context, due, timezone: timezone),
          ),
          l10n.homeStatusOverdueBody,
        ),
        HomeStatus.incident => (
          StatusBannerKind.attention,
          l10n.homeStatusIncidentTitle,
          l10n.homeStatusIncidentBody,
        ),
        HomeStatus.unknown => (
          StatusBannerKind.info,
          l10n.homeStatusUnknownTitle,
          l10n.homeStatusUnknownBody,
        ),
      },
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: StatusBanner(kind: kind, title: title, message: body ?? ''),
    );
  }

  String _pendingBody(
    BuildContext context,
    CheckInState checkIn,
    String? timezone,
  ) {
    final l10n = AppLocalizations.of(context);
    switch (checkIn.phase) {
      case CheckInPhase.rateLimited:
        final retryAt = checkIn.retryAt;
        final wait = retryAt == null
            ? Duration.zero
            : retryAt.difference(ref.read(clockProvider)());
        return l10n.homeRateLimitedBody(formatUntil(l10n, wait));
      case CheckInPhase.signInRequired:
        return l10n.homeSignInRequiredBody;
      case _:
        final tapped = checkIn.tappedAt;
        return tapped == null
            ? l10n.homePendingBody('')
            : l10n.homePendingBody(
                formatClockTime(context, tapped, timezone: timezone),
              );
    }
  }

  /// "Your earlier check-in wasn't received": the tap was too old to be sent and was
  /// dropped. Read out when it appears; "Got it" dismisses it, and so does a new tap.
  Widget _expiredNotice(
    BuildContext context,
    CheckInState checkIn,
    String? timezone,
    DateTime now,
  ) {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: StatusBanner(
        kind: StatusBannerKind.attention,
        title: l10n.homeExpiredTitle,
        message: l10n.homeExpiredBody(
          formatSpokenDayTime(
            context,
            l10n,
            checkIn.tappedAt!,
            now: now,
            timezone: timezone,
          ),
        ),
        action: AppButton.text(
          label: l10n.homeExpiredDismiss,
          onPressed: ref
              .read(checkInControllerProvider.notifier)
              .dismissExpiredNotice,
        ),
      ),
    );
  }

  // --- Not active -------------------------------------------------------------------

  bool _contactDone(HomeData data) => !data.snapshot.readiness.issues.any(
    (issue) => issue.code == ReadinessCode.noContacts,
  );

  bool _checklistReady(HomeData data) =>
      _contactDone(data) &&
      (ref.read(setupControllerProvider).value?.hasPlan ?? false);

  List<Widget> _notActive(
    BuildContext context,
    HomeSnapshot snapshot,
    CheckInState checkIn,
    String? timezone,
    DateTime now,
  ) {
    final l10n = AppLocalizations.of(context);
    final setup =
        ref.watch(setupControllerProvider).value ?? const SetupState();
    final contactDone = !snapshot.readiness.issues.any(
      (issue) => issue.code == ReadinessCode.noContacts,
    );
    final schedule = snapshot.checkin.schedule;
    final missing = _missing;
    return [
      Gap.md,
      _ChecklistItem(
        done: contactDone,
        label: l10n.checklistContact,
        actionLabel: l10n.checklistAdd,
        path: OnboardingStep.contact.path,
      ),
      _ChecklistItem(
        done: schedule != null,
        label: schedule == null
            ? l10n.checklistSchedule
            : l10n.scheduleSummary(
                intervalLabel(l10n, schedule.intervalDays).toLowerCase(),
                formatMinutesOfDay(context, schedule.dueMinutes),
              ),
        actionLabel: schedule == null
            ? l10n.checklistSetUp
            : l10n.checklistChange,
        path: OnboardingStep.schedule.path,
        actionWhenDone: true,
      ),
      _ChecklistItem(
        done: setup.hasPlan,
        label: l10n.checklistPlan,
        actionLabel: l10n.checklistSetUp,
        path: OnboardingStep.plan.path,
      ),
      Gap.md,
      if (_activationFailure != null) ...[
        FailureNotice.of(context, _activationFailure!),
        Gap.md,
      ],
      if (missing != null) ...[
        Semantics(
          liveRegion: true,
          container: true,
          child: StatusBanner(
            kind: StatusBannerKind.attention,
            message: l10n.homeActivationMissing(
              activationMissingText(l10n, missing),
            ),
          ),
        ),
        Gap.md,
      ],
      AppButton.primary(
        label: l10n.homeTurnOn,
        isLoading: _activating,
        onPressed: contactDone ? _turnOn : null,
        expand: true,
      ),
      const SizedBox(height: AppSpacing.xl),
      ..._checkInSection(
        context,
        checkIn,
        buttonState: CheckInButtonState.disabled,
        timezone: timezone,
        now: now,
        caption: l10n.homeCheckInUnavailable,
      ),
    ];
  }

  // --- Active, due soon, overdue, incident, unknown ------------------------------

  List<Widget> _running(
    BuildContext context,
    HomeData data,
    CheckInState checkIn,
    HomeStatus status,
    DateTime now,
    String? timezone,
  ) {
    final l10n = AppLocalizations.of(context);
    final snapshot = data.snapshot;
    final next = snapshot.checkin.nextDueAt;
    final last = snapshot.checkin.lastCheckinAt;
    return [
      const SizedBox(height: AppSpacing.xl),
      ..._checkInSection(
        context,
        checkIn,
        buttonState: checkIn.phase == CheckInPhase.safeRequired
            ? CheckInButtonState.disabled
            : null,
        timezone: timezone,
        now: now,
      ),
      const SizedBox(height: AppSpacing.xl),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InfoRow(
                label: l10n.homeNextCheckIn,
                value: next == null
                    ? l10n.homeNextCheckInNone
                    : formatDayTime(
                        context,
                        l10n,
                        next,
                        now: now,
                        timezone: timezone,
                      ),
              ),
              Gap.sm,
              _InfoRow(
                label: l10n.homeLastCheckIn,
                value: last == null
                    ? l10n.homeLastCheckInNone
                    : formatDayTime(
                        context,
                        l10n,
                        last,
                        now: now,
                        timezone: timezone,
                      ),
              ),
            ],
          ),
        ),
      ),
      Gap.md,
      _PlanCard(summary: snapshot.planSummary),
    ];
  }

  // --- The check-in button and what it just did ------------------------------------

  /// [buttonState] overrides the state derived from the check-in controller (used for
  /// "not available"). The button itself never decides success: it shows
  /// [CheckInButtonState.success] only while the controller holds the server's 200.
  List<Widget> _checkInSection(
    BuildContext context,
    CheckInState checkIn, {
    required CheckInButtonState? buttonState,
    required String? timezone,
    required DateTime now,
    String? caption,
  }) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final controller = ref.read(checkInControllerProvider.notifier);
    final derived = switch (checkIn.phase) {
      CheckInPhase.sending => CheckInButtonState.sending,
      CheckInPhase.success => CheckInButtonState.success,
      CheckInPhase.pending ||
      CheckInPhase.rateLimited ||
      CheckInPhase.signInRequired => CheckInButtonState.pending,
      CheckInPhase.safeRequired => CheckInButtonState.disabled,
      CheckInPhase.idle ||
      CheckInPhase.failed ||
      CheckInPhase.expired => CheckInButtonState.idle,
    };
    // Off (not active) wins over idle, but never hides a tap that is still unconfirmed.
    final state =
        buttonState == CheckInButtonState.disabled &&
            !checkIn.isUnconfirmed &&
            checkIn.phase != CheckInPhase.success
        ? CheckInButtonState.disabled
        : derived;
    final VoidCallback? onPressed = switch (state) {
      CheckInButtonState.idle => () => unawaited(controller.checkIn()),
      CheckInButtonState.pending => () => unawaited(controller.retryNow()),
      _ => null,
    };
    final result = checkIn.result;
    return [
      Center(
        child: CheckInButton(state: state, onPressed: onPressed),
      ),
      if (checkIn.phase == CheckInPhase.success && result != null) ...[
        Gap.md,
        Semantics(
          liveRegion: true,
          container: true,
          child: StatusBanner(
            kind: StatusBannerKind.ok,
            message: _successMessage(context, result, timezone, now),
          ),
        ),
      ] else if (checkIn.isUnconfirmed &&
          checkIn.phase != CheckInPhase.sending) ...[
        Gap.md,
        AppButton.secondary(
          label: l10n.retry,
          onPressed: () => unawaited(controller.retryNow()),
          expand: true,
        ),
      ],
      if (caption != null) ...[
        const SizedBox(height: AppSpacing.lg),
        Text(
          caption,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: t.textMuted),
        ),
      ],
    ];
  }

  /// "Checked in. Next check-in tomorrow at 8:00 PM." (read out as a live region).
  /// [now] is the clock calibrated by `GET /home`; the check-in's own `server_time` may
  /// be an old replay and is not used.
  String _successMessage(
    BuildContext context,
    CheckInResult result,
    String? timezone,
    DateTime now,
  ) {
    final l10n = AppLocalizations.of(context);
    if (result.incidentResolved) {
      return l10n.homeWelcomeBack;
    }
    final next = result.nextDueAt;
    if (next == null) {
      return l10n.homeCheckedInNoNext;
    }
    return l10n.homeCheckedIn(
      formatSpokenDayTime(context, l10n, next, now: now, timezone: timezone),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: textTheme.bodySmall?.copyWith(
              color: context.tokens.textMuted,
            ),
          ),
          Text(value, style: textTheme.titleMedium),
        ],
      ),
    );
  }
}

/// The plan at a glance: only what the server counts; nothing is claimed beyond it.
class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.summary});

  final PlanSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SectionCard(
      title: l10n.homePlanTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            summary.contactsTotal == 0
                ? l10n.homePlanContactsNone
                : l10n.homePlanContacts(
                    summary.contactsVerified,
                    summary.contactsTotal,
                  ),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(l10n.homePlanStages(summary.stages)),
          const SizedBox(height: AppSpacing.xxs),
          Text(l10n.homePlanInstructions(summary.instructionsActive)),
        ],
      ),
    );
  }
}

/// The banner for a hole in the safety net (USER_FLOWS.md §4): what is wrong and what it
/// means in one sentence, and the one thing to do as its action, which opens the step
/// that fixes it, contact first (a stage needs someone to tell), like the checklist and
/// the last onboarding step. Kept short on purpose: it sits above I'M OK, which must stay
/// within reach on a small phone.
class _SafetyNetGapBanner extends StatelessWidget {
  const _SafetyNetGapBanner({required this.gap});

  final SafetyNetGap gap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (String message, String action, String path) = switch (gap) {
      SafetyNetGap.noContacts => (
        l10n.homeGapNoContacts,
        l10n.checklistContact,
        OnboardingStep.contact.path,
      ),
      SafetyNetGap.noStages => (
        l10n.homeGapNoStages,
        l10n.checklistPlan,
        OnboardingStep.plan.path,
      ),
      SafetyNetGap.stageEmpty => (
        l10n.homeGapStageEmpty,
        l10n.checklistPlan,
        OnboardingStep.plan.path,
      ),
    };
    return StatusBanner(
      kind: StatusBannerKind.attention,
      message: message,
      action: AppButton.text(
        label: action,
        onPressed: () => context.push(path),
      ),
    );
  }
}

/// One readiness banner with the action that leads to the fix.
class _ReadinessBannerView extends StatelessWidget {
  const _ReadinessBannerView({required this.banner});

  final ReadinessBanner banner;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final contactId = banner.contactId;
    final (
      StatusBannerKind kind,
      String message,
      String action,
      String path,
    ) = switch (banner.kind) {
      ReadinessBannerKind.contactProblem => (
        StatusBannerKind.attention,
        l10n.readinessContactProblem(banner.count),
        contactId == null
            ? l10n.readinessOpenPeople
            : l10n.readinessOpenContact,
        contactId == null
            ? AppRoutes.people
            : AppRoutes.contactDetail(contactId),
      ),
      ReadinessBannerKind.contactPending => (
        StatusBannerKind.info,
        l10n.readinessContactPending(banner.count),
        contactId == null
            ? l10n.readinessOpenPeople
            : l10n.readinessOpenContact,
        contactId == null
            ? AppRoutes.people
            : AppRoutes.contactDetail(contactId),
      ),
      ReadinessBannerKind.notificationsOff => (
        StatusBannerKind.attention,
        l10n.readinessNotificationsOff,
        l10n.readinessOpenNotifications,
        AppRoutes.settingsNotifications,
      ),
      ReadinessBannerKind.timezoneMismatch => (
        StatusBannerKind.info,
        l10n.readinessTimezone,
        l10n.readinessOpenProfile,
        AppRoutes.settingsProfile,
      ),
    };
    return StatusBanner(
      kind: kind,
      message: message,
      action: AppButton.text(label: action, onPressed: () => context.go(path)),
    );
  }
}

class _ChecklistItem extends StatelessWidget {
  const _ChecklistItem({
    required this.done,
    required this.label,
    required this.actionLabel,
    required this.path,
    this.actionWhenDone = false,
  });

  final bool done;
  final String label;
  final String actionLabel;
  final String path;

  /// Offer the action even when the item is done (the schedule can be changed).
  final bool actionWhenDone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      done
                          ? Icons.check_circle_outline
                          : Icons.radio_button_unchecked,
                      color: done ? t.ok : t.textMuted,
                      semanticLabel: done
                          ? l10n.statusDone
                          : l10n.statusNotDone,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(label)),
                ],
              ),
              if (!done || actionWhenDone)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: AppButton.text(
                    label: actionLabel,
                    onPressed: () => context.push(path),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
