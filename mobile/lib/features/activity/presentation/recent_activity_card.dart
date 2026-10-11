import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../home/data/models/home_models.dart';
import 'activity_labels.dart';

/// How many of Home's `recent_activity` entries the card shows.
const homeRecentActivityCount = 3;

/// Home's short list of what happened lately: the newest three entries of the aggregate's
/// `recent_activity` (an action and a time only: no names or titles), and the way to the
/// whole feed. Nothing is shown while there is nothing to say.
class RecentActivityCard extends StatelessWidget {
  const RecentActivityCard({
    required this.items,
    required this.now,
    required this.timezone,
    super.key,
  });

  /// The aggregate's `recent_activity`, newest first.
  final List<RecentActivity> items;

  /// The server's idea of now, for "Today" and "Yesterday".
  final DateTime now;
  final String? timezone;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    return SectionCard(
      title: l10n.homeActivityTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in items.take(homeRecentActivityCount))
            _line(context, l10n, textTheme, t, item),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppButton.text(
              label: l10n.homeActivitySeeAll,
              onPressed: () => context.push(AppRoutes.settingsActivity),
            ),
          ),
        ],
      ),
    );
  }

  Widget _line(
    BuildContext context,
    AppLocalizations l10n,
    TextTheme textTheme,
    AppColorTokens t,
    RecentActivity item,
  ) {
    final line = describeActivity(l10n, item.action);
    final when = formatDayTime(
      context,
      l10n,
      item.occurredAt,
      now: now,
      timezone: timezone,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: MergeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(line.icon, size: 20, color: t.textMuted),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(line.text, style: textTheme.bodyMedium),
                  Text(
                    when,
                    style: textTheme.bodySmall?.copyWith(color: t.textMuted),
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
