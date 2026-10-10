import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../app/theme/dimens.dart';
import '../../app/theme/tokens.dart';

/// A calm placeholder: icon, title, explanation and an optional action.
///
/// Not scrollable on its own; page bodies wrap it in [CenteredScrollView] so it
/// reflows at large text sizes.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: t.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Icon(icon, size: 40, color: t.primary),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Semantics(
          header: true,
          child: Text(
            title,
            style: textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          message,
          style: textTheme.bodyMedium?.copyWith(color: t.textMuted),
          textAlign: TextAlign.center,
        ),
        if (action != null) ...[const SizedBox(height: AppSpacing.lg), action!],
      ],
    );
  }
}

/// Scrollable page body that centres [child] when it fits and scrolls when the text
/// is scaled up, so content is never clipped (USER_FLOWS.md §1.4).
class CenteredScrollView extends StatelessWidget {
  const CenteredScrollView({
    required this.child,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.page,
      vertical: AppSpacing.lg,
    ),
    this.physics,
    super.key,
  });

  final Widget child;

  /// Scroll physics; pass [AlwaysScrollableScrollPhysics] for pull-to-refresh.
  final ScrollPhysics? physics;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: padding,
        physics: physics,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight
                ? math.max(0.0, constraints.maxHeight - padding.vertical)
                : 0.0,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppSizes.maxContentWidth,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
