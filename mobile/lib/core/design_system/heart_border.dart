import 'package:material_ui/material_ui.dart';

/// A heart-shaped border (for the I'M OK button). The heart fills the rect it is given;
/// its widest, calmest area (for a label) is around 45% from the top.
class HeartBorder extends OutlinedBorder {
  const HeartBorder({super.side});

  static Path heart(Rect r) {
    final w = r.width;
    final h = r.height;
    double x(double f) => r.left + w * f;
    double y(double f) => r.top + h * f;
    return Path()
      ..moveTo(x(0.5), y(0.24))
      ..cubicTo(x(0.5), y(0.16), x(0.40), y(0.04), x(0.24), y(0.04))
      ..cubicTo(x(0.04), y(0.04), x(0), y(0.24), x(0), y(0.34))
      ..cubicTo(x(0), y(0.60), x(0.26), y(0.80), x(0.5), y(0.97))
      ..cubicTo(x(0.74), y(0.80), x(1), y(0.60), x(1), y(0.34))
      ..cubicTo(x(1), y(0.24), x(0.96), y(0.04), x(0.76), y(0.04))
      ..cubicTo(x(0.60), y(0.04), x(0.5), y(0.16), x(0.5), y(0.24))
      ..close();
  }

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      heart(rect.deflate(side.strokeInset));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => heart(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) {
      return;
    }
    canvas.drawPath(heart(rect.deflate(side.width / 2)), side.toPaint());
  }

  @override
  ShapeBorder scale(double t) => HeartBorder(side: side.scale(t));

  @override
  HeartBorder copyWith({BorderSide? side}) =>
      HeartBorder(side: side ?? this.side);

  @override
  bool operator ==(Object other) => other is HeartBorder && other.side == side;

  @override
  int get hashCode => side.hashCode;
}
