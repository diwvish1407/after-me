import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/repository_providers.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/security/secure_screen.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../home/application/home_controller.dart';
import '../application/incident_context.dart';
import '../data/models/incident_models.dart';
import 'incident_labels.dart';
import 'incident_releases_view.dart';
import 'incident_timeline_view.dart';

/// One past (or current) incident in full: how it ended, its timeline with the views and
/// the releases that were taken back, and what was shared with whom.
///
/// The incident is read for this screen and dropped with it: titles of instructions are
/// content, so they are never kept in a provider. The window is `FLAG_SECURE` while a
/// title is on screen.
class IncidentDetailScreen extends ConsumerStatefulWidget {
  const IncidentDetailScreen({required this.incidentId, super.key});

  final String incidentId;

  @override
  ConsumerState<IncidentDetailScreen> createState() =>
      _IncidentDetailScreenState();
}

class _IncidentDetailScreenState extends ConsumerState<IncidentDetailScreen> {
  Incident? _incident;
  AppFailure? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant IncidentDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.incidentId != widget.incidentId) {
      // Another incident in the same place: never show the old one's names.
      setState(() {
        _incident = null;
        _failure = null;
      });
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    try {
      final incident = await ref
          .read(incidentsRepositoryProvider)
          .get(widget.incidentId);
      if (mounted) {
        setState(() {
          _incident = incident;
          _failure = null;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _failure = toAppFailure(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final incident = _incident;
    final failure = _failure;
    final Widget content;
    if (incident != null) {
      content = _Detail(incident: incident);
    } else if (failure != null) {
      content = ErrorView(
        failure: failure,
        onRetry: () {
          setState(() => _failure = null);
          unawaited(_load());
        },
      );
    } else {
      content = const LoadingView();
    }
    final hasTitles =
        incident?.releases.any((r) => (r.instructionTitle ?? '').isNotEmpty) ??
        false;
    return SecureScreen(
      enabled: hasTitles,
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.incidentDetailTitle)),
        body: SafeArea(child: CenteredScrollView(child: content)),
      ),
    );
  }
}

class _Detail extends ConsumerWidget {
  const _Detail({required this.incident});

  final Incident incident;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final timezone = ref.watch(incidentTimezoneProvider);
    final now = ref.watch(serverNowProvider)();
    final interruption = ref.watch(serviceInterruptionProvider);
    final closedAt = incident.closedAt;
    final outcome = incidentOutcomeText(
      l10n,
      isClosed: incident.isClosed,
      closedBy: incident.closedBy,
      status: incident.status,
      contactsMessaged: incident.contactsMessaged,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeading(
          l10n.incidentRowTitle(
            formatDateTime(context, incident.missedDueAt, timezone: timezone),
          ),
        ),
        Gap.xs,
        Text(outcome, style: textTheme.bodyLarge),
        Gap.sm,
        if (closedAt != null)
          Text(
            l10n.incidentDetailClosedAt(
              formatDateTime(context, closedAt, timezone: timezone),
            ),
            style: textTheme.bodyMedium?.copyWith(color: t.textMuted),
          ),
        const SizedBox(height: AppSpacing.lg),
        IncidentTimelineView(
          incident: incident,
          now: now,
          timezone: timezone,
          paused: interruption,
          heading: l10n.incidentDetailTimelineHeading,
        ),
        IncidentReleasesView(incident: incident, now: now, timezone: timezone),
      ],
    );
  }
}
