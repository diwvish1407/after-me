import 'package:material_ui/material_ui.dart';

import '../../app/theme/dimens.dart';
import '../../app/theme/tokens.dart';
import '../../l10n/gen/app_localizations.dart';
import '../forms/validators.dart';

/// A strength bar and the four password rules, each ticked as it is met. Sits under a
/// new-password field.
class PasswordChecklist extends StatelessWidget {
  const PasswordChecklist({required this.rules, super.key});

  final PasswordRules rules;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final score = rules.score;
    final barColor = switch (score) {
      4 => t.ok,
      3 => t.attention,
      _ => t.escalation,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: score / 4,
              minHeight: 4,
              color: barColor,
              backgroundColor: t.border,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xxs),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xxs,
          children: [
            _Rule(met: rules.length, label: l10n.passwordRuleLength),
            _Rule(met: rules.upper, label: l10n.passwordRuleUpper),
            _Rule(met: rules.number, label: l10n.passwordRuleNumber),
            _Rule(met: rules.special, label: l10n.passwordRuleSpecial),
          ],
        ),
      ],
    );
  }
}

class _Rule extends StatelessWidget {
  const _Rule({required this.met, required this.label});

  final bool met;
  final String label;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final color = met ? t.ok : t.textMuted;
    return Semantics(
      label: '$label: ${met ? l10n.statusDone : l10n.statusNotDone}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            met ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
