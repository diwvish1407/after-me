import 'package:material_ui/material_ui.dart';

/// The app's "something is happening" mark: a spinning arc, or, when the person asked
/// the phone to remove animations (`MediaQuery.disableAnimationsOf`, Android's "Remove
/// animations"), a still hourglass. The words next to it ("Sending...", "Loading") say
/// what is going on, so the motion is never the only signal.
///
/// Every place that used a [CircularProgressIndicator] uses this instead, so there is
/// exactly one place that decides.
class ProgressSpinner extends StatelessWidget {
  const ProgressSpinner({
    this.size,
    this.strokeWidth = 4,
    this.color,
    this.backgroundColor,
    this.semanticsLabel,
    super.key,
  });

  /// The side of the mark in dp; the spinner's own size when null.
  final double? size;
  final double strokeWidth;
  final Color? color;
  final Color? backgroundColor;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      final mark = Icon(
        Icons.hourglass_top_rounded,
        size: size ?? 40,
        color: color ?? Theme.of(context).colorScheme.primary,
      );
      return semanticsLabel == null
          ? ExcludeSemantics(child: mark)
          : Semantics(
              label: semanticsLabel,
              child: ExcludeSemantics(child: mark),
            );
    }
    final spinner = CircularProgressIndicator(
      strokeWidth: strokeWidth,
      color: color,
      backgroundColor: backgroundColor,
      semanticsLabel: semanticsLabel,
    );
    return size == null
        ? spinner
        : SizedBox.square(dimension: size, child: spinner);
  }
}
