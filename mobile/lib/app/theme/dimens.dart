/// Spacing scale (logical pixels). Generous whitespace (USER_FLOWS.md §1.1).
abstract final class AppSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  /// Horizontal page padding.
  static const double page = 20;
}

/// Corner radii.
abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 28;
}

/// Accessibility sizes (USER_FLOWS.md §1.3–1.4).
abstract final class AppSizes {
  /// Minimum touch target for every interactive element.
  static const double minTouchTarget = 48;

  /// Minimum diameter of the check-in button.
  static const double checkInButton = 160;

  /// Maximum content width on large screens.
  static const double maxContentWidth = 560;

  /// Bottom-navigation label size (Material 3 default). The longest label,
  /// "Instructions", must fit one fifth of a 320 dp screen.
  static const double navLabelSp = 12;

  /// Horizontal room kept free inside each navigation destination.
  static const double navLabelPadding = 8;
}
