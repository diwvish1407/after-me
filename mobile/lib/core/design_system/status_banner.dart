import 'package:material_ui/material_ui.dart';

import '../../app/theme/dimens.dart';
import '../../app/theme/tokens.dart';
import '../../l10n/gen/app_localizations.dart';

/// Banner severity (USER_FLOWS.md §1.3, §4).
enum StatusBannerKind {
  /// Everything is fine (checked in).
  ok,

  /// Neutral information (contact accepted, plan not active yet).
  info,

  /// Due soon / grace period: the user should act.
  attention,

  /// Contacts have been notified. Muted brick, never alarm red.
  escalation,
}

/// A status message with an icon **and** text. The kind is also announced to screen
/// readers, so status is never conveyed by colour alone.
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    required this.kind,
    required this.message,
    this.title,
    this.action,
    super.key,
  });

  final StatusBannerKind kind;
  final String? title;
  final String message;

  /// Optional action, usually an [AppButton.text].
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final (
      IconData icon,
      Color accent,
      Color background,
      String kindLabel,
    ) = switch (kind) {
      StatusBannerKind.ok => (
        Icons.check_circle_outline_rounded,
        t.ok,
        t.okContainer,
        l10n.bannerKindOk,
      ),
      StatusBannerKind.info => (
        Icons.info_outline_rounded,
        t.primary,
        t.primaryContainer,
        l10n.bannerKindInfo,
      ),
      StatusBannerKind.attention => (
        Icons.error_outline_rounded,
        t.attention,
        t.attentionContainer,
        l10n.bannerKindAttention,
      ),
      StatusBannerKind.escalation => (
        Icons.campaign_outlined,
        t.escalation,
        t.escalationContainer,
        l10n.bannerKindEscalation,
      ),
    };

    return Semantics(
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: BorderDirectional(start: BorderSide(color: accent, width: 4)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: accent, semanticLabel: kindLabel),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null) ...[
                      Text(
                        title!,
                        style: textTheme.titleSmall?.copyWith(color: t.text),
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                    ],
                    Text(
                      message,
                      style: textTheme.bodyMedium?.copyWith(color: t.text),
                    ),
                    if (action != null) ...[
                      const SizedBox(height: AppSpacing.xs),
                      action!,
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
