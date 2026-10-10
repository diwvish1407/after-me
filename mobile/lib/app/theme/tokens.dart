import 'package:material_ui/material_ui.dart';

/// Colour tokens from USER_FLOWS.md §1.2 (the source of truth), plus the derived
/// tokens documented there. Every pair the UI uses for text is checked against
/// WCAG 2.x AA by `test/app/theme/contrast_test.dart`.
///
/// Status colours ([ok], [attention], [escalation]) pass 4.5:1 as text on [bg] and
/// [surface] in both themes, so they may be used for text, icons and borders. On the
/// tinted status containers they are used for icons/accents only (>= 3:1); text on
/// containers always uses [text].
@immutable
class AppColorTokens {
  const AppColorTokens({
    required this.bg,
    required this.surface,
    required this.text,
    required this.textMuted,
    required this.primary,
    required this.onPrimary,
    required this.ok,
    required this.attention,
    required this.escalation,
    required this.border,
    required this.outline,
    required this.primaryContainer,
    required this.okContainer,
    required this.attentionContainer,
    required this.escalationContainer,
  });

  // --- USER_FLOWS.md §1.2 base tokens -------------------------------------------

  /// App background (warm off-white / deep slate).
  final Color bg;

  /// Cards, sheets, navigation bar.
  final Color surface;

  /// Primary text.
  final Color text;

  /// Secondary text.
  final Color textMuted;

  /// Calm teal: primary actions, I'M OK.
  final Color primary;

  /// Checked in / healthy.
  final Color ok;

  /// Due soon / grace period.
  final Color attention;

  /// Contacts notified (muted brick, not alarm red).
  final Color escalation;

  /// Dividers and decorative card outlines (not for interactive boundaries).
  final Color border;

  // --- Derived tokens (USER_FLOWS.md §1.2, "Derived tokens") ------------------

  /// Text and icons on filled [primary], [ok], [attention] and [escalation].
  final Color onPrimary;

  /// Boundaries of interactive components (text fields, outlined buttons):
  /// >= 3:1 against [bg] and [surface] (WCAG 1.4.11).
  final Color outline;

  /// Tinted background for info banners and the selected navigation indicator.
  final Color primaryContainer;

  /// Tinted backgrounds for status banners.
  final Color okContainer;
  final Color attentionContainer;
  final Color escalationContainer;

  static const AppColorTokens light = AppColorTokens(
    bg: Color(0xFFF7F5F2),
    surface: Color(0xFFFFFFFF),
    text: Color(0xFF1F2A30),
    textMuted: Color(0xFF5B6770),
    primary: Color(0xFF1F6F6B),
    onPrimary: Color(0xFFFFFFFF),
    ok: Color(0xFF2E7D5B),
    attention: Color(0xFF9A6412),
    escalation: Color(0xFFA4472F),
    border: Color(0xFFE3DED7),
    outline: Color(0xFF737E85),
    primaryContainer: Color(0xFFE4EEED),
    okContainer: Color(0xFFE6EFEB),
    attentionContainer: Color(0xFFF3ECE3),
    escalationContainer: Color(0xFFF4E9E6),
  );

  static const AppColorTokens dark = AppColorTokens(
    bg: Color(0xFF121718),
    surface: Color(0xFF1B2224),
    text: Color(0xFFE8ECEC),
    textMuted: Color(0xFFA9B4B8),
    primary: Color(0xFF5FB3AD),
    onPrimary: Color(0xFF121718),
    ok: Color(0xFF6CC39B),
    attention: Color(0xFFE3B263),
    escalation: Color(0xFFE58C74),
    border: Color(0xFF2C3538),
    outline: Color(0xFF7F8B90),
    primaryContainer: Color(0xFF273C3D),
    okContainer: Color(0xFF2A3F39),
    attentionContainer: Color(0xFF3F3C2F),
    escalationContainer: Color(0xFF3F3532),
  );
}

/// Exposes [AppColorTokens] to widgets through the theme:
/// `Theme.of(context).extension<AppTokens>()!.colors` or `context.tokens`.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens(this.colors);

  final AppColorTokens colors;

  @override
  AppTokens copyWith({AppColorTokens? colors}) =>
      AppTokens(colors ?? this.colors);

  @override
  AppTokens lerp(covariant AppTokens? other, double t) =>
      (other == null || t < 0.5) ? this : other;
}

extension AppTokensContext on BuildContext {
  /// The colour tokens of the ambient theme.
  AppColorTokens get tokens =>
      (Theme.of(this).extension<AppTokens>() ??
              const AppTokens(AppColorTokens.light))
          .colors;
}
