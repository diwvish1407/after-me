import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// WCAG 2.x relative luminance of an opaque colour.
double relativeLuminance(Color color) {
  double channel(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// WCAG 2.x contrast ratio between two opaque colours, from 1 to 21.
double contrastRatio(Color a, Color b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

/// WCAG AA thresholds.
abstract final class WcagAA {
  /// Normal text.
  static const double text = 4.5;

  /// Large text (>= 18pt / 14pt bold), icons and component boundaries.
  static const double largeTextOrGraphics = 3;
}
