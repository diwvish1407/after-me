import 'package:material_ui/material_ui.dart';

/// One unbreakable value (an email address, a timezone id) on a single line that
/// shrinks to fit instead of being cut in the middle at large text sizes
/// (USER_FLOWS.md §1.4). Normal text should wrap; use this only for tokens that must
/// stay whole.
class FitText extends StatelessWidget {
  const FitText(
    this.text, {
    this.style,
    this.alignment = AlignmentDirectional.centerStart,
    super.key,
  });

  final String text;
  final TextStyle? style;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: Text(text, style: style, maxLines: 1, softWrap: false),
    );
  }
}
