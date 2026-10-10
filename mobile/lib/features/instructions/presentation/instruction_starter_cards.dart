import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../data/instructions_repository.dart';
import 'instruction_labels.dart';
import 'instruction_starters.dart';

/// One example as a tappable card: its title and what it is for (EXAMPLES ONLY, see
/// [InstructionStarter]).
class StarterCard extends StatelessWidget {
  const StarterCard({required this.starter, required this.onTap, super.key});

  final InstructionStarter starter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = starterText(AppLocalizations.of(context), starter);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          minTileHeight: 64,
          title: Text(text.title),
          subtitle: Text(text.hint),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        ),
      ),
    );
  }
}

/// "Start from an example": the examples of [category], or all of them grouped by
/// category while none is chosen (or the chosen one, such as Business, has none).
/// Returns the one the person picked, or null.
Future<InstructionStarter?> showStarterSheet(
  BuildContext context, {
  InstructionCategory? category,
}) {
  return showModalBottomSheet<InstructionStarter>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => _StarterSheet(category: category),
  );
}

class _StarterSheet extends StatelessWidget {
  const _StarterSheet({required this.category});

  final InstructionCategory? category;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final only =
        category != null &&
        InstructionStarter.forCategory(category!).isNotEmpty;
    final categories = only
        ? [category!]
        : [
            for (final c in InstructionCategory.values)
              if (InstructionStarter.forCategory(c).isNotEmpty) c,
          ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        0,
        AppSpacing.page,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeading(l10n.instructionExamplesTitle),
          Gap.xs,
          BodyText(l10n.instructionExamplesBody),
          Gap.md,
          for (final c in categories) ...[
            if (!only)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Semantics(
                  header: true,
                  child: Text(
                    categoryName(l10n, c),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ),
            for (final starter in InstructionStarter.forCategory(c))
              StarterCard(
                starter: starter,
                onTap: () => Navigator.of(context).pop(starter),
              ),
          ],
        ],
      ),
    );
  }
}
