import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/incident_events.dart';
import '../data/models/incident_models.dart';
import 'incident_labels.dart';

/// The incident's timeline as a list of lines in time order (USER_FLOWS.md §4): the
/// reminders, the warning before a release, each stage with who was told and what was
/// shared, each view ("Brother viewed “House emergency”") and each release taken back.
///
/// Times are the server's, shown in the profile's timezone with the day counted from the
/// server's idea of now. Every line has a word as well as an icon, and is read out as one
/// sentence. A stage that was put back later is simply at its new time.
class IncidentTimelineView extends StatelessWidget {
  const IncidentTimelineView({
    required this.incident,
    required this.now,
    required this.timezone,
    this.heading,
    super.key,
  });

  final Incident incident;

  /// The server's idea of now (the phone's clock plus the offset of the last Home read).
  final DateTime now;
  final String? timezone;

  /// A heading above the lines; none when null.
  final String? heading;

  @override
  Widget build(BuildContext context) {
    final events = incidentEvents(incident);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (heading != null) ...[
          Semantics(
            header: true,
            child: Text(
              heading!,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        for (final event in events)
          _EventTile(
            event: event,
            incident: incident,
            now: now,
            timezone: timezone,
          ),
      ],
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({
    required this.event,
    required this.incident,
    required this.now,
    required this.timezone,
  });

  final IncidentEvent event;
  final Incident incident;
  final DateTime now;
  final String? timezone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final text = describeIncidentEvent(
      context,
      l10n,
      event,
      incident: incident,
      now: now,
      timezone: timezone,
    );
    final when = formatDayTime(
      context,
      l10n,
      event.at,
      now: now,
      timezone: timezone,
    );
    final upcoming = event.item?.isUpcoming ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Semantics(
        container: true,
        excludeSemantics: true,
        label: text.semantics(when),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(text.icon, color: upcoming ? t.textMuted : t.primary),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    when,
                    style: textTheme.bodySmall?.copyWith(color: t.textMuted),
                  ),
                  Text(text.title, style: textTheme.bodyLarge),
                  if (text.status != null)
                    Text(
                      text.status!,
                      style: textTheme.bodyMedium?.copyWith(
                        color: t.textMuted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  for (final detail in text.details)
                    Text(
                      detail,
                      style: textTheme.bodyMedium?.copyWith(color: t.textMuted),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
