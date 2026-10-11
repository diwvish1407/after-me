import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../contacts/data/contacts_repository.dart';
import '../data/plan_repository.dart';

/// One sentence of the plan preview.
class PlanPreviewLine {
  const PlanPreviewLine(this.icon, this.text);

  final IconData icon;
  final String text;
}

/// "Mom", "Mom and Brother", "Mom, Brother and Sam".
String joinNames(AppLocalizations l10n, List<String> names) {
  if (names.isEmpty) {
    return '';
  }
  if (names.length == 1) {
    return names.first;
  }
  return l10n.namesJoined(
    names.sublist(0, names.length - 1).join(', '),
    names.last,
  );
}

/// The plan in plain words (USER_FLOWS.md §3 step 6): when we remind, who is told when.
/// [dueMinutes] is the local deadline as minutes after midnight. [plan] is the saved
/// plan as a draft (`Plan.toDraft`) or one that is about to be saved.
///
/// The times are only the deadline plus the offsets the server defined: nothing is worked
/// out beyond adding them. [releaseCounts] are the instructions the server says each
/// existing stage shares (by stage id); a stage that shares some says so, with or
/// without people to tell.
List<PlanPreviewLine> buildPlanPreview(
  BuildContext context, {
  required int dueMinutes,
  required PlanDraft plan,
  required List<TrustedContact> contacts,
  Map<String, int> releaseCounts = const {},
}) {
  final l10n = AppLocalizations.of(context);
  final lines = <PlanPreviewLine>[
    PlanPreviewLine(
      Icons.notifications_active_outlined,
      l10n.planPreviewMissed(formatMinutesOfDay(context, dueMinutes)),
    ),
  ];
  for (final stage in plan.stages) {
    final names = [
      for (final id in stage.contactIds)
        for (final contact in contacts)
          if (contact.id == id) contact.displayName,
    ];
    final shared = stage.id == null ? 0 : releaseCounts[stage.id] ?? 0;
    if (names.isEmpty && shared == 0) {
      continue;
    }
    final when = formatMinutesWithDay(
      context,
      l10n,
      dueMinutes + stage.offsetMinutes,
    );
    final String text;
    if (names.isEmpty) {
      text = l10n.planPreviewSharesOnly(shared, when);
    } else {
      final notified = l10n.planPreviewNotify(
        names.length,
        when,
        joinNames(l10n, names),
      );
      text = shared == 0
          ? notified
          : '$notified ${l10n.planPreviewShares(shared)}';
    }
    lines.add(PlanPreviewLine(Icons.mark_email_unread_outlined, text));
  }
  lines.add(PlanPreviewLine(Icons.verified_outlined, l10n.planPreviewStop));
  return lines;
}

/// The preview lines as a list with icons (icon and text, never colour alone).
class PlanPreview extends StatelessWidget {
  const PlanPreview({required this.lines, super.key});

  final List<PlanPreviewLine> lines;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(child: Icon(line.icon, color: t.primary)),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(line.text)),
              ],
            ),
          ),
      ],
    );
  }
}
