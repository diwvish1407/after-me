import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/security/secure_screen.dart';
import '../../../core/time/clock.dart';
import '../../../core/time/foreground_ticker.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../checkin/application/checkin_controller.dart';
import '../../checkin/presentation/check_in_notices.dart';
import '../../home/application/home_controller.dart';
import '../../home/presentation/service_interruption_banner.dart';
import '../application/incident_context.dart';
import '../data/models/incident_models.dart';
import 'incident_headline.dart';
import 'incident_releases_view.dart';
import 'incident_timeline_view.dart';
import 'safe_action_button.dart';

/// The whole story of the open incident (USER_FLOWS.md §4): the reminders, the warning
/// before a release, each stage with who was told and what was shared, the views and the
/// releases that were taken back, and what is shared with whom.
///
/// It reads the incident from the Home aggregate (the same object `GET /incidents/current`
/// returns), so it can never disagree with Home, and reads Home again when it opens and
/// on pull-to-refresh. The window is `FLAG_SECURE` while it shows an instruction's title.
class IncidentTimelineScreen extends ConsumerStatefulWidget {
  const IncidentTimelineScreen({super.key});

  @override
  ConsumerState<IncidentTimelineScreen> createState() =>
      _IncidentTimelineScreenState();
}

class _IncidentTimelineScreenState
    extends ConsumerState<IncidentTimelineScreen> {
  late final ForegroundTicker _ticker = ForegroundTicker(
    period: const Duration(seconds: 30),
    onTick: _redraw,
    onForeground: _redraw,
  );

  @override
  void initState() {
    super.initState();
    // Times such as "is due" are decided from the clock plus the server's offset; the
    // timer only triggers a redraw, and only while the app is in the foreground (it is
    // cancelled when the app is paused and redraws once when it returns).
    _ticker.start();
    unawaited(Future.microtask(_refresh));
  }

  @override
  void dispose() {
    _ticker.stop();
    super.dispose();
  }

  void _redraw() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _refresh() async {
    if (mounted) {
      await ref.read(homeControllerProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final home = ref.watch(homeControllerProvider);
    final data = home.value;
    final incident = data?.snapshot.incidentDetails;
    final hasTitles =
        incident?.releases.any((r) => (r.instructionTitle ?? '').isNotEmpty) ??
        false;
    final Widget content;
    if (data != null) {
      content = _loaded(context, data, incident);
    } else if (home.error != null) {
      final error = home.error!;
      final failure = error is AppFailure
          ? error
          : UnknownFailure(cause: error);
      content = ErrorView(
        failure: failure,
        onRetry: () => unawaited(_refresh()),
      );
    } else {
      content = const LoadingView();
    }
    return SecureScreen(
      enabled: hasTitles,
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.incidentTimelineTitle)),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: CenteredScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: content,
            ),
          ),
        ),
      ),
    );
  }

  Widget _loaded(BuildContext context, HomeData data, Incident? incident) {
    final l10n = AppLocalizations.of(context);
    final snapshot = data.snapshot;
    final timezone = ref.watch(incidentTimezoneProvider);
    final now = data.serverNow(ref.read(clockProvider)());
    final checkIn = ref.watch(checkInControllerProvider);

    if (!snapshot.hasIncident) {
      // Nothing is open: no incident, or the person has just checked in or been marked
      // safe. Never shown as if something were still going on.
      return EmptyState(
        icon: Icons.verified_outlined,
        title: l10n.incidentNoneTitle,
        message: l10n.incidentNoneBody,
        action: AppButton.secondary(
          label: l10n.incidentOpenHistory,
          onPressed: () => context.push(AppRoutes.settingsIncidents),
        ),
      );
    }
    if (incident == null) {
      // The server reports an incident this version cannot read. Nothing is guessed.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatusBanner(
            kind: StatusBannerKind.attention,
            title: l10n.homeStatusIncidentTitle,
            message: l10n.homeStatusIncidentBody,
          ),
        ],
      );
    }

    // The `safe_required` answer of a tap counts only for the incident it named.
    final needsSafe =
        incident.needsSafe || checkIn.safeRequiredApplies(incident.id);
    final interruption = snapshot.serviceInterruption;
    final headline = incidentHeadline(
      context,
      incident,
      now: now,
      needsSafe: needsSafe,
      timezone: timezone,
      interruption: interruption,
    );
    final behind = incidentIsBehind(incident, needsSafe: needsSafe);
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
        if (interruption) ...[const ServiceInterruptionBanner(), Gap.md],
        StatusBanner(
          kind: headline.kind,
          title: headline.title,
          message: headline.body,
          liveRegion: true,
        ),
        Gap.lg,
        if (needsSafe)
          SafeActionButton(incidentId: incident.id, incident: incident)
        else
          _CheckInAction(checkIn: checkIn, timezone: timezone, now: now),
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
          IncidentReleasesView(
            incident: incident,
            now: now,
            timezone: timezone,
          ),
        ],
      ],
    );
  }
}

/// I'M OK on the timeline screen while nobody has been told. The state is the check-in
/// controller's: a tap is never shown as recorded before the server says so. What an
/// unconfirmed, refused or expired tap says is what Home says (the same notice).
class _CheckInAction extends ConsumerWidget {
  const _CheckInAction({
    required this.checkIn,
    required this.timezone,
    required this.now,
  });

  final CheckInState checkIn;
  final String? timezone;

  /// The server's idea of now (the aggregate's offset on the phone's clock).
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(checkInControllerProvider.notifier);
    final sending = checkIn.phase == CheckInPhase.sending;
    final unconfirmed = checkIn.isUnconfirmed && !sending;
    final notice = incidentCheckInNotice(
      context,
      ref,
      checkIn,
      now: now,
      deviceNow: ref.read(clockProvider)(),
      timezone: timezone,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (notice != null) ...[notice, Gap.sm],
        AppButton.primary(
          label: l10n.checkInLabelIdle,
          icon: Icons.check_rounded,
          isLoading: sending,
          expand: true,
          onPressed: sending
              ? null
              : () => unconfirmed
                    ? unawaited(controller.retryNow())
                    : unawaited(controller.checkIn()),
        ),
      ],
    );
  }
}
