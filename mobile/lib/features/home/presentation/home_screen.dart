import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/security/secure_screen.dart';
import '../../../core/time/clock.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../activity/presentation/recent_activity_card.dart';
import '../../auth/application/me_controller.dart';
import '../../checkin/application/checkin_controller.dart';
import '../../checkin/data/models/checkin_models.dart';
import '../../checkin/presentation/check_in_notices.dart';
import '../../checkin/presentation/schedule_labels.dart';
import '../../incidents/data/models/incident_models.dart';
import '../../incidents/presentation/incident_headline.dart';
import '../../incidents/presentation/incident_timeline_view.dart';
import '../../incidents/presentation/safe_action_button.dart';
import '../../onboarding/application/onboarding_controller.dart';
import '../../onboarding/application/setup_controller.dart';
import '../application/client_checks.dart';
import '../application/home_controller.dart';
import '../application/home_status.dart';
import '../data/models/home_models.dart';
import 'service_interruption_banner.dart';

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

  /// The stage time a "it has arrived, read Home again" refresh was already made for.
  DateTime? _refreshedForStage;

  /// Ticks since Home was last read again by the ticker. It is read about once a minute
  /// while an incident is open (so views and stages show without pulling), while a
  /// deadline has passed with no incident yet (an incident is about to open, or a Hold is
  /// keeping it from opening), and while a service interruption is on (so its end shows).
  int _pollTicks = 0;

  /// The app is in the foreground and this tab is the one on view. The ticker (and with
  /// it the once-a-minute read of an open incident) runs only then: a phone in a pocket
  /// or a tab nobody is looking at must not keep the server busy.
  bool _foreground = true;
  bool _onView = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncTicker();
    unawaited(Future.microtask(_readClientChecks));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The shell keeps every tab alive and switches off the animations of the hidden ones
    // (and a page pushed above hides this one too).
    final onView = TickerMode.valuesOf(context).enabled;
    if (onView == _onView) {
      return;
    }
    _onView = onView;
    _syncTicker();
    if (onView) {
      _backOnView();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  /// Starts the ticker while the screen is on view in the foreground, stops it otherwise.
  /// It re-evaluates "due soon" as time passes; the decision itself always uses the clock
  /// plus the server offset, the timer only triggers a redraw.
  void _syncTicker() {
    final run = _foreground && _onView;
    if (run && _ticker == null) {
      _pollTicks = 0;
      _ticker = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
    } else if (!run) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// The screen is on view again after being away (another tab, or the background): what
  /// it shows may be old.
  void _backOnView() {
    if (mounted && _foreground) {
      unawaited(ref.read(homeControllerProvider.notifier).refresh());
    }
  }

  Future<void> _readClientChecks() async {
    if (mounted) {
      await ref.read(clientChecksProvider.notifier).refresh();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) {
      return;
    }
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _foreground = false;
        _syncTicker();
      case AppLifecycleState.resumed:
        _foreground = true;
        _syncTicker();
        // A check-in that was not confirmed is sent again with its own key, and the
        // aggregate is read again (the app may have been away for hours).
        unawaited(ref.read(checkInControllerProvider.notifier).onResumed());
        unawaited(ref.read(homeControllerProvider.notifier).refresh());
        unawaited(_readClientChecks());
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
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
      if (status == HomeStatus.overdue && due != _refreshedForDue) {
        // The deadline passed while Home was open: the server may have moved on. The
        // minute of the next read starts from this one.
        _refreshedForDue = due;
        _pollTicks = 0;
        unawaited(ref.read(homeControllerProvider.notifier).refresh());
      } else if (status == HomeStatus.incident) {
        _tickIncident(data.snapshot.incidentDetails, now);
      } else if (status == HomeStatus.overdue ||
          (status != HomeStatus.notActive &&
              data.snapshot.serviceInterruption)) {
        _pollMinute();
      } else {
        _pollTicks = 0;
      }
    }
    setState(() {});
  }

  /// While an incident is open: reads Home again once a stage's time has arrived (it may
  /// have run), and otherwise about once a minute, so a stage that ran or an instruction
  /// that was viewed shows up without pulling. The server's times are only ever compared
  /// with now.
  void _tickIncident(Incident? incident, DateTime now) {
    final stage = incident?.nextStage;
    final at = stage?.scheduledFor;
    if (at != null && !at.isAfter(now) && at != _refreshedForStage) {
      _refreshedForStage = at;
      _pollTicks = 0;
      unawaited(ref.read(homeControllerProvider.notifier).refresh());
      return;
    }
    _pollMinute();
  }

  /// Reads Home again about once a minute (every second tick of the 30-second ticker).
  void _pollMinute() {
    _pollTicks++;
    if (_pollTicks >= 2) {
      _pollTicks = 0;
      unawaited(ref.read(homeControllerProvider.notifier).refresh());
    }
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
      // Whatever the reason, I'M OK and a tap that is still waiting stay within reach: a
      // status that cannot be read must never take the check-in away.
      final problem = failure is AppFailure
          ? failure
          : UnknownFailure(cause: failure);
      content = _unavailable(context, problem, checkIn);
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

  /// No status is known (a cold start while offline, or the aggregate was refused). I'M
  /// OK still works: it queues as a pending check-in and is sent when it can be, and a
  /// tap that is already waiting is shown.
  Widget _unavailable(
    BuildContext context,
    AppFailure failure,
    CheckInState checkIn,
  ) {
    final l10n = AppLocalizations.of(context);
    final timezone = _timezone(null);
    final now = ref.read(clockProvider)();
    // Offline or server trouble is worded as before; any other answer is worded as what
    // it is, never as "offline".
    final offline = failure.isTransient;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusBanner(
          kind: StatusBannerKind.attention,
          title: offline ? l10n.homeOfflineBanner : l10n.homeUnavailableTitle,
          message: offline
              ? l10n.homeUnavailableBody
              : failureMessage(l10n, failure),
          liveRegion: true,
        ),
        Gap.md,
        // What the last tap came to: not received yet, refused, or too old to send (most
        // likely found right here: the app was opened again after a long time without a
        // connection).
        if (_incidentPhaseBanner(context, checkIn, timezone, now)
            case final notice?) ...[
          notice,
          Gap.md,
        ],
        ..._checkInSection(
          context,
          checkIn,
          buttonState: null,
          timezone: timezone,
          now: now,
          // With a tap already waiting, its notice above says what is going on.
          caption: offline || checkIn.isUnconfirmed
              ? null
              : l10n.homeUnavailableTapNote,
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
    // The aggregate carries the name; a profile change reads it again (HomeInputChanges),
    // so Home never starts `GET /v1/me` just to greet the person.
    final name = snapshot.user.displayName;
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
    // The typed incident drives the real incident experience; one this app version
    // cannot read keeps the neutral placeholder (and I'M OK within reach).
    final incident = status == HomeStatus.incident
        ? snapshot.incidentDetails
        : null;
    // A Hold blocks anything contact-facing: nothing is sent and deadlines move. Said
    // calmly at the top, and every sentence below that promised a time leaves it out.
    // An account whose check-ins are off has no deadline to move and no I'M OK to use, so
    // the notice (which says both) is left to the accounts it is true for.
    final interruption =
        snapshot.serviceInterruption && status != HomeStatus.notActive;
    // Instruction titles are content: the window is secure while one is on screen.
    final showsTitles =
        incident?.releases.any((r) => (r.instructionTitle ?? '').isNotEmpty) ??
        false;
    return SecureScreen(
      enabled: showsTitles,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (interruption) ...[const ServiceInterruptionBanner(), Gap.md],
          if (data.stale) ...[
            StatusBanner(
              kind: StatusBannerKind.info,
              message: l10n.homeOfflineBanner,
              // The status on screen is no longer confirmed: said when it happens.
              liveRegion: true,
            ),
            Gap.md,
          ],
          if (name.isNotEmpty && incident == null) ...[
            Text(
              l10n.homeGreeting(name),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Gap.md,
          ],
          if (gap != null) ...[
            // The banner is only judged while check-ins are on (see `gap` above).
            _SafetyNetGapBanner(
              gap: gap,
              checkInsOn: status != HomeStatus.notActive,
            ),
            Gap.md,
          ],
          if (banner != null) ...[_ReadinessBannerView(banner: banner), Gap.md],
          if (incident != null)
            ..._incidentSection(
              context,
              incident,
              checkIn,
              now,
              timezone,
              interruption: interruption,
            )
          else ...[
            _statusHeader(context, data, checkIn, status, now, timezone),
            if (status == HomeStatus.notActive)
              ..._notActive(context, snapshot, checkIn, timezone, now)
            else
              ..._running(context, data, checkIn, status, now, timezone),
          ],
        ],
      ),
    );
  }

  // --- An incident is open ------------------------------------------------------------

  /// Grace (nobody told) and Notified (contacts told) as USER_FLOWS.md §4 describes them:
  /// the headline, the main action (I'M OK, or I'M SAFE once contacts were told), and the
  /// timeline. The aggregate says which action stops it (`requires`); a check-in that the
  /// server answered with `safe_required` moves to I'M SAFE at once, before Home has read
  /// the aggregate again.
  List<Widget> _incidentSection(
    BuildContext context,
    Incident incident,
    CheckInState checkIn,
    DateTime now,
    String? timezone, {
    required bool interruption,
  }) {
    final l10n = AppLocalizations.of(context);
    // The tap's `safe_required` answer counts only for the incident it named: one that
    // outlived its incident must not turn this one (nobody told yet) into "contacts have
    // been notified".
    final needsSafe =
        incident.needsSafe || checkIn.safeRequiredApplies(incident.id);
    // And without it, no part of that answer is left on this incident's screen (the
    // I'M OK button would otherwise stay off).
    final tap = !needsSafe && checkIn.phase == CheckInPhase.safeRequired
        ? const CheckInState()
        : checkIn;
    final headline = incidentHeadline(
      context,
      incident,
      now: now,
      needsSafe: needsSafe,
      timezone: timezone,
      interruption: interruption,
    );
    final phase = _incidentPhaseBanner(context, tap, timezone, now);
    final behind = incidentIsBehind(incident, needsSafe: needsSafe);
    return [
      if (phase != null) ...[phase, Gap.md],
      StatusBanner(
        kind: headline.kind,
        title: headline.title,
        message: headline.body,
        liveRegion: true,
      ),
      const SizedBox(height: AppSpacing.xl),
      if (needsSafe)
        SafeActionButton(incidentId: incident.id, incident: incident)
      else
        ..._checkInSection(
          context,
          tap,
          buttonState: null,
          timezone: timezone,
          now: now,
        ),
      // Until Home has read the aggregate again, the timeline on hand would contradict
      // the headline.
      if (!behind) ...[
        const SizedBox(height: AppSpacing.xl),
        IncidentTimelineView(
          incident: incident,
          now: now,
          timezone: timezone,
          paused: interruption,
          heading: needsSafe
              ? l10n.incidentTimelineHeadingAll
              : l10n.incidentTimelineHeadingNext,
        ),
        Gap.sm,
        AppButton.secondary(
          label: l10n.incidentSeeTimeline,
          onPressed: () => context.push(AppRoutes.homeIncident),
          expand: true,
        ),
      ],
    ];
  }

  /// What an unconfirmed or refused I'M OK says during an incident: the same words as the
  /// header on any other state (and on the timeline screen). Null when the tap is idle,
  /// in its first attempt, recorded (the incident is then over) or answered with
  /// `safe_required` (the incident headline and I'M SAFE say that).
  Widget? _incidentPhaseBanner(
    BuildContext context,
    CheckInState checkIn,
    String? timezone,
    DateTime now,
  ) => incidentCheckInNotice(
    context,
    ref,
    checkIn,
    now: now,
    deviceNow: ref.read(clockProvider)(),
    timezone: timezone,
  );

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
    return StatusBanner(
      kind: kind,
      title: title,
      message: body ?? '',
      liveRegion: true,
    );
  }

  String _pendingBody(
    BuildContext context,
    CheckInState checkIn,
    String? timezone,
  ) => checkInPendingBody(
    context,
    checkIn,
    deviceNow: ref.read(clockProvider)(),
    timezone: timezone,
  );

  /// "Your earlier check-in wasn't received": the tap was too old to be sent and was
  /// dropped. Read out when it appears; "Got it" dismisses it, and so does a new tap.
  Widget _expiredNotice(
    BuildContext context,
    CheckInState checkIn,
    String? timezone,
    DateTime now,
  ) =>
      expiredCheckInNotice(context, ref, checkIn, now: now, timezone: timezone);

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
        StatusBanner(
          kind: StatusBannerKind.attention,
          message: l10n.homeActivationMissing(
            activationMissingText(l10n, missing),
          ),
          liveRegion: true,
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
      if (snapshot.recentActivity.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.xl),
        RecentActivityCard(
          items: snapshot.recentActivity,
          now: now,
          timezone: timezone,
        ),
      ],
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
    // The server said contacts were told but this screen has no readable incident (or
    // has not read it again yet): I'M SAFE is still the way out, with the incident id the
    // server gave in the same answer.
    final safeIncidentId = checkIn.phase == CheckInPhase.safeRequired
        ? _incidentIdFor(snapshot, checkIn)
        : null;
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
      if (safeIncidentId != null) ...[
        Gap.md,
        SafeActionButton(incidentId: safeIncidentId),
      ],
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
      if (snapshot.recentActivity.isNotEmpty) ...[
        Gap.md,
        RecentActivityCard(
          items: snapshot.recentActivity,
          now: now,
          timezone: timezone,
        ),
      ],
    ];
  }

  /// The id of the open incident: the aggregate's, else the one `safe_required` named.
  String? _incidentIdFor(HomeSnapshot snapshot, CheckInState checkIn) {
    final raw = snapshot.incident?['id'];
    if (raw is String && raw.isNotEmpty) {
      return raw;
    }
    return checkIn.failure?.problem?.incidentId;
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
        StatusBanner(
          kind: StatusBannerKind.ok,
          message: _successMessage(context, result, timezone, now),
          liveRegion: true,
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
  const _SafetyNetGapBanner({required this.gap, required this.checkInsOn});

  final SafetyNetGap gap;

  /// Check-ins are already on: the plan is fixed in the plan editor, not in the
  /// onboarding step (which would walk the person through setting the plan up again).
  final bool checkInsOn;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (String message, String action) = switch (gap) {
      SafetyNetGap.noContacts => (
        l10n.homeGapNoContacts,
        l10n.checklistContact,
      ),
      SafetyNetGap.noStages => (l10n.homeGapNoStages, l10n.checklistPlan),
      SafetyNetGap.stageEmpty => (l10n.homeGapStageEmpty, l10n.checklistPlan),
    };
    return StatusBanner(
      kind: StatusBannerKind.attention,
      message: message,
      action: AppButton.text(
        label: action,
        onPressed: () =>
            context.push(safetyNetGapPath(gap, checkInsOn: checkInsOn)),
      ),
    );
  }
}

/// Where the action of the safety-net banner leads (USER_FLOWS.md §4): a missing contact
/// is fixed in the contact step; a plan with no stage, or a stage that tells nobody, is
/// fixed in the **plan editor** when check-ins are already on, and in the onboarding plan
/// step for an account that is still setting up.
String safetyNetGapPath(SafetyNetGap gap, {required bool checkInsOn}) =>
    switch (gap) {
      SafetyNetGap.noContacts => OnboardingStep.contact.path,
      SafetyNetGap.noStages || SafetyNetGap.stageEmpty =>
        checkInsOn ? AppRoutes.planEdit : OnboardingStep.plan.path,
    };

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
