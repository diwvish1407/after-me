import 'package:material_ui/material_ui.dart';

import '../../app/theme/dimens.dart';
import '../../app/theme/tokens.dart';

/// The actions at the bottom of a page on one line: [secondary] on the left, [middle] in
/// the centre and [primary] on the right. When [pinned] it sits on its own strip at the
/// bottom of the screen (always visible); otherwise it is a plain row inside the page.
///
/// At very large text sizes the buttons stack (primary first) instead of squeezing a
/// label onto two lines.
class ActionBar extends StatelessWidget {
  const ActionBar({
    this.primary,
    this.secondary,
    this.middle,
    this.pinned = true,
    super.key,
  });

  final Widget? primary;
  final Widget? secondary;
  final Widget? middle;
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    final large = MediaQuery.textScalerOf(context).scale(16) > 16 * 1.3;
    final Widget row;
    if (large) {
      row = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, b) in [?primary, ?middle, ?secondary].indexed) ...[
            if (i > 0) const SizedBox(height: AppSpacing.xs),
            b,
          ],
        ],
      );
    } else {
      row = Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (secondary != null)
            Flexible(child: secondary!)
          else
            const SizedBox.shrink(),
          if (middle != null) Flexible(child: middle!),
          if (primary != null)
            Flexible(child: primary!)
          else
            const SizedBox.shrink(),
        ],
      );
    }
    if (!pinned) {
      return row;
    }
    final t = context.tokens;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.bg,
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.sm,
          AppSpacing.page,
          AppSpacing.sm,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppSizes.maxContentWidth,
            ),
            child: row,
          ),
        ),
      ),
    );
  }
}

/// A form's [fields] with its [actions]: when [pinned], the fields fill the room above a
/// footer that stays at the bottom of the screen (they scroll only when they do not fit);
/// otherwise the actions simply follow the fields.
Widget pinnedFormLayout({
  required bool pinned,
  required Widget fields,
  required Widget actions,
}) {
  if (!pinned) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        fields,
        const SizedBox(height: AppSpacing.lg),
        actions,
      ],
    );
  }
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            AppSpacing.xs,
            AppSpacing.page,
            AppSpacing.md,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppSizes.maxContentWidth,
              ),
              child: fields,
            ),
          ),
        ),
      ),
      actions,
    ],
  );
}
