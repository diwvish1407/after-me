// The AfterMe mark (PLAY_STORE §5): a soft check inside a rounded tile, calm teal on the
// warm off-white of the app (USER_FLOWS §1.2 tokens: `primary` #1F6F6B, `bg` #F7F5F2).
//
// This file is the ONE description of the mark. The Android vector drawables (adaptive
// launcher icon, its monochrome layer for themed icons, the Android 12+ splash icon) are
// written from the same numbers, and tool/store_assets/render_test.dart fails when their
// pathData drifts from [AfterMeMark.tilePathData] / [AfterMeMark.checkPathData]. The
// store PNGs and the legacy launcher PNGs are painted from it by [MarkPainter].
//
// Geometry is in the adaptive-icon viewport: 108 x 108 units, of which the launcher
// shows the central 72 x 72 through its mask and keeps the central circle of diameter 66
// always visible. The tile (48 x 48, corner radius 15) and the check stay inside that
// safe circle, so no launcher mask ever cuts them.
import 'dart:math' as math;

import 'package:flutter/rendering.dart';

/// The numbers of the mark, in the 108-unit adaptive-icon viewport.
abstract final class AfterMeMark {
  static const double viewport = 108;

  /// The part of the viewport a launcher shows (the rest is for the system's parallax
  /// and pulse effects).
  static const double visible = 72;

  static const double tileLeft = 30;
  static const double tileTop = 30;
  static const double tileSize = 48;
  static const double tileRadius = 15;

  /// The check: short arm down to the corner, long arm up.
  static const Offset checkStart = Offset(42, 54);
  static const Offset checkCorner = Offset(50, 62);
  static const Offset checkEnd = Offset(66, 46);
  static const double checkStroke = 5.5;

  /// The monochrome (themed-icon) layer draws the tile as an outline of this width,
  /// with its outer edge where the filled tile's edge is.
  static const double monochromeTileStroke = 4.5;

  // Colours: USER_FLOWS §1.2 (lib/app/theme/tokens.dart).
  static const Color warmWhite = Color(0xFFF7F5F2); // bg, light
  static const Color teal = Color(0xFF1F6F6B); // primary, light
  static const Color darkBackground = Color(0xFF121718); // bg, dark
  static const Color tealOnDark = Color(0xFF5FB3AD); // primary, dark
  static const Color text = Color(0xFF1F2A30); // text, light
  static const Color textMuted = Color(0xFF5B6770); // textMuted, light
  static const Color surface = Color(0xFFFFFFFF); // surface, light
  static const Color border = Color(0xFFE3DED7); // border, light
  static const Color ok = Color(0xFF2E7D5B); // ok, light

  static String _n(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  /// A rounded square as vector-drawable path data.
  static String roundedSquarePathData(
    double left,
    double top,
    double size,
    double radius,
  ) {
    final right = left + size;
    final bottom = top + size;
    final r = _n(radius);
    final arc = 'A$r,$r 0,0 1,';
    return 'M${_n(left + radius)},${_n(top)}'
        'H${_n(right - radius)}$arc${_n(right)},${_n(top + radius)}'
        'V${_n(bottom - radius)}$arc${_n(right - radius)},${_n(bottom)}'
        'H${_n(left + radius)}$arc${_n(left)},${_n(bottom - radius)}'
        'V${_n(top + radius)}$arc${_n(left + radius)},${_n(top)}Z';
  }

  /// The filled tile.
  static String get tilePathData =>
      roundedSquarePathData(tileLeft, tileTop, tileSize, tileRadius);

  /// The monochrome tile outline (stroked, centred on this path).
  static String get monochromeTilePathData {
    const inset = monochromeTileStroke / 2;
    return roundedSquarePathData(
      tileLeft + inset,
      tileTop + inset,
      tileSize - monochromeTileStroke,
      tileRadius - inset,
    );
  }

  /// The check, stroked with round caps and joins.
  static String get checkPathData =>
      'M${_n(checkStart.dx)},${_n(checkStart.dy)}'
      'L${_n(checkCorner.dx)},${_n(checkCorner.dy)}'
      'L${_n(checkEnd.dx)},${_n(checkEnd.dy)}';
}

/// Paints the mark (no background) into [rect], which stands for the whole 108-unit
/// viewport.
void paintMark(
  Canvas canvas,
  Rect rect, {
  Color tile = AfterMeMark.teal,
  Color check = AfterMeMark.warmWhite,
}) {
  final scale = rect.width / AfterMeMark.viewport;
  canvas
    ..save()
    ..translate(rect.left, rect.top)
    ..scale(scale);
  final tileRect = RRect.fromRectAndRadius(
    const Rect.fromLTWH(
      AfterMeMark.tileLeft,
      AfterMeMark.tileTop,
      AfterMeMark.tileSize,
      AfterMeMark.tileSize,
    ),
    const Radius.circular(AfterMeMark.tileRadius),
  );
  canvas.drawRRect(
    tileRect,
    Paint()
      ..isAntiAlias = true
      ..color = tile,
  );
  final path = Path()
    ..moveTo(AfterMeMark.checkStart.dx, AfterMeMark.checkStart.dy)
    ..lineTo(AfterMeMark.checkCorner.dx, AfterMeMark.checkCorner.dy)
    ..lineTo(AfterMeMark.checkEnd.dx, AfterMeMark.checkEnd.dy);
  canvas
    ..drawPath(
      path,
      Paint()
        ..isAntiAlias = true
        ..color = check
        ..style = PaintingStyle.stroke
        ..strokeWidth = AfterMeMark.checkStroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    )
    ..restore();
}

/// The launcher icon as a launcher shows it: the warm-white background layer and the
/// mark, the central [AfterMeMark.visible] units of the viewport filling [size], clipped
/// to [shape] (null: the full square, as Play wants its 512 px icon: Play applies its own
/// mask).
class LauncherIconPainter extends CustomPainter {
  const LauncherIconPainter({this.shape, this.margin = 0});

  /// Null (full bleed), [BoxShape.circle] or [BoxShape.rectangle] (a rounded square).
  final BoxShape? shape;

  /// Transparent space around the shape, as a fraction of the side (legacy icons keep a
  /// little room, as the system's own did).
  final double margin;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final inset = side * margin;
    final box = Rect.fromLTWH(inset, inset, side - 2 * inset, side - 2 * inset);
    canvas.save();
    switch (shape) {
      case BoxShape.circle:
        canvas.clipPath(Path()..addOval(box));
      case BoxShape.rectangle:
        canvas.clipRRect(
          RRect.fromRectAndRadius(box, Radius.circular(box.width * 0.2)),
        );
      case null:
        break;
    }
    canvas.drawRect(box, Paint()..color = AfterMeMark.warmWhite);
    // The visible 72 units fill the box, so the whole viewport is 1.5 times larger.
    final full = box.width * AfterMeMark.viewport / AfterMeMark.visible;
    final offset = (full - box.width) / 2;
    paintMark(
      canvas,
      Rect.fromLTWH(box.left - offset, box.top - offset, full, full),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(LauncherIconPainter oldDelegate) =>
      oldDelegate.shape != shape || oldDelegate.margin != margin;
}

/// The Play feature graphic (1024 x 500): the mark and "AfterMe" with the listing's
/// headline on the left, and on the right a calm phone silhouette showing Home's
/// "You're checked in" and the I'M OK button (PLAY_STORE §5). No death imagery, no
/// claims about encryption.
class FeatureGraphicPainter extends CustomPainter {
  const FeatureGraphicPainter({
    required this.fontFamily,
    required this.name,
    required this.headline,
    required this.statusTitle,
    required this.buttonLabel,
  });

  final String fontFamily;
  final String name;
  final String headline;
  final String statusTitle;
  final String buttonLabel;

  TextPainter _text(
    String value,
    double size,
    FontWeight weight,
    Color color, {
    double? maxWidth,
    double height = 1.2,
    TextAlign align = TextAlign.left,
    double letterSpacing = 0,
  }) => TextPainter(
    text: TextSpan(
      text: value,
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
      ),
    ),
    textAlign: align,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxWidth ?? double.infinity);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = AfterMeMark.warmWhite);

    // --- left: the mark, the name, the headline -------------------------------------
    const left = 84.0;
    const markSide = 112.0; // the tile's side in pixels
    final markViewport = markSide * AfterMeMark.viewport / AfterMeMark.tileSize;
    final markOrigin = Offset(
      left - AfterMeMark.tileLeft * markViewport / AfterMeMark.viewport,
      138 - AfterMeMark.tileTop * markViewport / AfterMeMark.viewport,
    );
    paintMark(
      canvas,
      Rect.fromLTWH(markOrigin.dx, markOrigin.dy, markViewport, markViewport),
    );
    final title = _text(
      name,
      86,
      FontWeight.w500,
      AfterMeMark.text,
      letterSpacing: -0.5,
      height: 1,
    );
    title.paint(
      canvas,
      Offset(left + markSide + 30, 138 + (markSide - title.height) / 2),
    );
    final line = _text(
      headline,
      34,
      FontWeight.w400,
      AfterMeMark.textMuted,
      maxWidth: 470,
      height: 1.3,
    );
    line.paint(canvas, const Offset(left, 286));

    // --- right: a phone with Home on it --------------------------------------------
    const phone = Rect.fromLTWH(660, 64, 270, 520); // runs off the bottom edge
    final body = RRect.fromRectAndRadius(phone, const Radius.circular(42));
    canvas
      ..drawRRect(
        body.shift(const Offset(0, 6)),
        Paint()
          ..color = const Color(0x141F2A30)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
      )
      ..drawRRect(body, Paint()..color = AfterMeMark.surface)
      ..drawRRect(
        body,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = AfterMeMark.border,
      );
    final cx = phone.center.dx;
    // The status line: a check in a circle and "You're checked in".
    final status = _text(statusTitle, 22, FontWeight.w500, AfterMeMark.text);
    const iconSize = 24.0;
    const gap = 10.0;
    final statusWidth = iconSize + gap + status.width;
    final statusLeft = cx - statusWidth / 2;
    const statusTop = 130.0;
    final iconCenter = Offset(
      statusLeft + iconSize / 2,
      statusTop + status.height / 2,
    );
    canvas.drawCircle(
      iconCenter,
      iconSize / 2,
      Paint()..color = AfterMeMark.ok,
    );
    canvas.drawPath(
      Path()
        ..moveTo(iconCenter.dx - 5.5, iconCenter.dy + 0.5)
        ..lineTo(iconCenter.dx - 1.5, iconCenter.dy + 4.5)
        ..lineTo(iconCenter.dx + 6, iconCenter.dy - 4),
      Paint()
        ..color = AfterMeMark.surface
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    status.paint(canvas, Offset(statusLeft + iconSize + gap, statusTop));
    // Two quiet lines standing for the details under the status.
    final quiet = Paint()..color = const Color(0xFFEDE9E3);
    canvas
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, 186), width: 170, height: 12),
          const Radius.circular(6),
        ),
        quiet,
      )
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, 208), width: 120, height: 12),
          const Radius.circular(6),
        ),
        quiet,
      );
    // The I'M OK button.
    const buttonCenterY = 352.0;
    canvas
      ..drawCircle(
        Offset(cx, buttonCenterY),
        92,
        Paint()
          ..color = const Color(0xFFE4EEED), // primaryContainer: a soft halo
      )
      ..drawCircle(
        Offset(cx, buttonCenterY),
        78,
        Paint()..color = AfterMeMark.teal,
      );
    final label = _text(
      buttonLabel,
      30,
      FontWeight.w500,
      AfterMeMark.surface,
      letterSpacing: 0.5,
    );
    label.paint(
      canvas,
      Offset(cx - label.width / 2, buttonCenterY - label.height / 2),
    );
  }

  @override
  bool shouldRepaint(FeatureGraphicPainter oldDelegate) => false;
}
