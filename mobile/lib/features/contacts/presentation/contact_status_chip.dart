import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../data/contacts_repository.dart';
import 'contact_labels.dart';

/// The status of a contact: a distinct icon **and** a word, so it is never conveyed by
/// colour alone. The accent colour only supports the icon and the outline; the text
/// keeps the regular text colour. Read out as "Status: Pending".
class ContactStatusChip extends StatelessWidget {
  const ContactStatusChip({required this.status, super.key});

  final VerificationStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final label = statusLabel(l10n, status);
    final accent = switch (status) {
      VerificationStatus.verified => t.ok,
      VerificationStatus.pending => t.textMuted,
      VerificationStatus.declined ||
      VerificationStatus.optedOut ||
      VerificationStatus.bounced => t.attention,
    };
    return Semantics(
      container: true,
      label: l10n.contactStatusLabel(label),
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
