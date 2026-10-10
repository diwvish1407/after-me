import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../data/instructions_repository.dart';
import 'instruction_labels.dart';

/// Active or inactive: a distinct icon **and** a word, so it is never conveyed by colour
/// alone. The accent supports the icon and the outline; the text keeps the regular text
/// colour. Read out as "Status: Active".
class InstructionStatusChip extends StatelessWidget {
  const InstructionStatusChip({required this.status, super.key});

  final InstructionStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final label = statusName(l10n, status);
    final accent = status == InstructionStatus.active ? t.ok : t.textMuted;
    return Semantics(
      container: true,
      label: l10n.instructionStatusLabel(label),
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: accent, width: 1.5),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xxs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(statusIcon(status), size: 18, color: accent),
                ),
                const SizedBox(width: AppSpacing.xxs),
                Flexible(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(color: t.text),
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

/// A round avatar with a person's initials. Decoration only: the name is always in text
/// next to it, so it is hidden from screen readers.
class RecipientAvatar extends StatelessWidget {
  const RecipientAvatar({required this.name, super.key});

  final String name;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: t.primaryContainer,
          shape: BoxShape.circle,
        ),
        child: SizedBox.square(
          dimension: 32,
          // Two letters in a circle: they shrink with large text instead of breaking.
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                initialsOf(name),
                maxLines: 1,
                softWrap: false,
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: t.text),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
