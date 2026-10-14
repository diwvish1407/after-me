import 'package:material_ui/material_ui.dart';

import '../../app/theme/dimens.dart';
import '../../l10n/gen/app_localizations.dart';
import 'progress_spinner.dart';

enum AppButtonVariant { primary, secondary, text }

/// The app's button. One primary action per screen (USER_FLOWS.md §1.1).
///
/// * Minimum 48 dp tall (from the theme), full width when [expand] is true.
/// * [isLoading] shows a progress indicator, ignores taps, and keeps the enabled
///   colours so the label stays readable.
/// * `onPressed: null` disables the button.
class AppButton extends StatelessWidget {
  const AppButton({
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.icon,
    this.isLoading = false,
    this.expand = false,
    super.key,
  });

  const AppButton.primary({
    required this.label,
    required this.onPressed,
    this.icon,
    this.isLoading = false,
    this.expand = false,
    super.key,
  }) : variant = AppButtonVariant.primary;

  const AppButton.secondary({
    required this.label,
    required this.onPressed,
    this.icon,
    this.isLoading = false,
    this.expand = false,
    super.key,
  }) : variant = AppButtonVariant.secondary;

  const AppButton.text({
    required this.label,
    required this.onPressed,
    this.icon,
    this.isLoading = false,
    this.expand = false,
    super.key,
  }) : variant = AppButtonVariant.text;

  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final IconData? icon;
  final bool isLoading;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effectiveOnPressed = isLoading ? null : onPressed;
    // At large text sizes the icon and the side padding give way to the label, so a
    // word is never broken to make room for decoration (USER_FLOWS.md §1.4).
    final large = MediaQuery.textScalerOf(context).scale(16) > 16 * 1.3;
    final showIcon = icon != null && !large;
    final compactPadding = large
        ? const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.sm,
          )
        : null;

    final (Color foreground, Color? background) = switch (variant) {
      AppButtonVariant.primary => (scheme.onPrimary, scheme.primary),
      AppButtonVariant.secondary ||
      AppButtonVariant.text => (scheme.primary, null),
    };
    // While loading the button is disabled for taps but keeps its enabled colours.
    final loadingStyle = isLoading
        ? ButtonStyle(
            foregroundColor: WidgetStatePropertyAll(foreground),
            backgroundColor: background == null
                ? null
                : WidgetStatePropertyAll(background),
            padding: compactPadding == null
                ? null
                : WidgetStatePropertyAll(compactPadding),
          )
        : (compactPadding == null
              ? null
              : ButtonStyle(padding: WidgetStatePropertyAll(compactPadding)));

    final Widget child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (isLoading)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: AppSpacing.xs),
            child: ProgressSpinner(
              size: 18,
              strokeWidth: 2,
              semanticsLabel: AppLocalizations.of(context).loading,
              color: foreground,
              backgroundColor: foreground.withValues(alpha: 0.25),
            ),
          )
        else if (showIcon)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: AppSpacing.xs),
            child: Icon(icon, size: 20),
          ),
        Flexible(child: Text(label, textAlign: TextAlign.center)),
      ],
    );

    final Widget button = switch (variant) {
      AppButtonVariant.primary => FilledButton(
        onPressed: effectiveOnPressed,
        style: loadingStyle,
        child: child,
      ),
      AppButtonVariant.secondary => OutlinedButton(
        onPressed: effectiveOnPressed,
        style: loadingStyle,
        child: child,
      ),
      AppButtonVariant.text => TextButton(
        onPressed: effectiveOnPressed,
        style: loadingStyle,
        child: child,
      ),
    };

    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}
