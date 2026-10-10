import 'package:material_ui/material_ui.dart';

import '../../app/theme/dimens.dart';
import '../../app/theme/tokens.dart';

/// A calm card grouping related content, with an optional title and subtitle.
class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.child,
    this.title,
    this.subtitle,
    this.onTap,
    super.key,
  });

  final String? title;
  final String? subtitle;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final t = context.tokens;
    final content = Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Semantics(
              header: true,
              child: Text(title!, style: textTheme.titleMedium),
            ),
          if (subtitle != null) ...[
            const SizedBox(height: AppSpacing.xxs),
            Text(
              subtitle!,
              style: textTheme.bodySmall?.copyWith(color: t.textMuted),
            ),
          ],
          if (title != null || subtitle != null)
            const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? content : InkWell(onTap: onTap, child: content),
    );
  }
}
