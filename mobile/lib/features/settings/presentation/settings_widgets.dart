import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';

/// A tappable settings row: icon, title, optional value/subtitle, chevron. At least
/// 56 dp tall and reflows at large text sizes.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    required this.title,
    this.icon,
    this.subtitle,
    this.subtitleWidget,
    this.onTap,
    this.trailing,
    super.key,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;

  /// Replaces [subtitle] for values that must stay whole (an email address).
  final Widget? subtitleWidget;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListTile(
      minTileHeight: 56,
      contentPadding: EdgeInsets.zero,
      leading: icon == null ? null : Icon(icon, color: t.textMuted),
      title: Text(title),
      subtitle: subtitleWidget ?? (subtitle == null ? null : Text(subtitle!)),
      trailing:
          trailing ??
          (onTap == null
              ? null
              : Icon(Icons.chevron_right_rounded, color: t.textMuted)),
      onTap: onTap,
    );
  }
}

/// A small section heading in a settings list.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        top: AppSpacing.md,
        bottom: AppSpacing.xxs,
      ),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(color: context.tokens.textMuted),
        ),
      ),
    );
  }
}

/// A modal confirmation with a cancel and a confirm action. Returns true on confirm.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required String cancelLabel,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
