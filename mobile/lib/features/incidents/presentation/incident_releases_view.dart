import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../data/models/incident_models.dart';
import 'incident_labels.dart';

/// What was shared in an incident, with whom, and what became of it: shared, viewed (and
/// how often), or taken back and why. This is the owner's own record: titles appear
/// only for releases the server lists, and never before that. A view cannot be undone;
/// a release that was taken back says so calmly.
class IncidentReleasesView extends StatelessWidget {
  const IncidentReleasesView({
    required this.incident,
    required this.now,
    required this.timezone,
    super.key,
  });

  final Incident incident;
  final DateTime now;
  final String? timezone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SectionCard(
      title: l10n.incidentReleasesHeading,
      child: incident.releases.isEmpty
          ? BodyText(l10n.incidentReleasesNone)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final release in incident.releases)
                  _ReleaseTile(release: release, now: now, timezone: timezone),
              ],
            ),
    );
  }
}

class _ReleaseTile extends StatelessWidget {
  const _ReleaseTile({
    required this.release,
    required this.now,
    required this.timezone,
  });

  final IncidentRelease release;
  final DateTime now;
  final String? timezone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    String when(DateTime at) =>
        formatDayTime(context, l10n, at, now: now, timezone: timezone);
    final title = release.instructionTitle;
    final heading = title == null || title.isEmpty
        ? l10n.incidentReleaseUntitled
        : title;
    final lines = <String>[
      l10n.incidentReleaseWith(release.contactDisplayName),
      l10n.incidentReleaseSharedAt(when(release.releasedAt)),
      if (release.wasViewed)
        release.viewCount > 1 && release.lastViewedAt != null
            ? l10n.incidentReleaseViewedMany(
                release.viewCount,
                when(release.lastViewedAt!),
              )
            : l10n.incidentReleaseViewed(
                when(
                  release.firstViewedAt ??
                      release.lastViewedAt ??
                      release.releasedAt,
                ),
              )
      else
        l10n.incidentReleaseNotViewed,
      if (release.revokedAt != null) ...[
        l10n.incidentReleaseRevoked(when(release.revokedAt!)),
        revokeReasonText(l10n, release.revokeReason),
      ],
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Semantics(
        container: true,
        excludeSemantics: true,
        label: [heading, ...lines].join('. '),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(heading, style: textTheme.bodyLarge),
            for (final line in lines)
              Text(
                line,
                style: textTheme.bodyMedium?.copyWith(color: t.textMuted),
              ),
          ],
        ),
      ),
    );
  }
}
