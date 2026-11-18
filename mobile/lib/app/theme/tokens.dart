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

  /// App background (cool blue-white / deep navy).
  final Color bg;

  /// Cards, sheets, navigation bar.
  final Color surface;

  /// Primary text.
  final Color text;

  /// Secondary text.
  final Color textMuted;

  /// AfterMe blue: primary actions, I'M OK.
  final Color primary;

  /// Checked in / healthy.
  final Color ok;

  /// Due soon / grace period.
  final Color attention;

  /// Contacts notified / incident (red).
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
    bg: Color(0xFFF3F7FF),
    surface: Color(0xFFFFFFFF),
    text: Color(0xFF0F1B3D),
    textMuted: Color(0xFF55627D),
    primary: Color(0xFF0B57E3),
    onPrimary: Color(0xFFFFFFFF),
    ok: Color(0xFF1B7F3E),
    attention: Color(0xFFA85A00),
    escalation: Color(0xFFC62828),
    border: Color(0xFFDCE5F5),
    outline: Color(0xFF6B7A99),
    primaryContainer: Color(0xFFE3EDFF),
    okContainer: Color(0xFFE5F5EA),
    attentionContainer: Color(0xFFFFF1DF),
    escalationContainer: Color(0xFFFDE8E8),
  );

  static const AppColorTokens dark = AppColorTokens(
    bg: Color(0xFF0B1530),
    surface: Color(0xFF0F1C40),
    text: Color(0xFFEAF0FF),
    textMuted: Color(0xFFA8B6D6),
    primary: Color(0xFF6EA8FF),
    onPrimary: Color(0xFF0B1530),
    ok: Color(0xFF5FD38D),
    attention: Color(0xFFFFB75E),
    escalation: Color(0xFFFF8A80),
    border: Color(0xFF24325C),
    outline: Color(0xFF7C8DB5),
    primaryContainer: Color(0xFF1E3270),
    okContainer: Color(0xFF183D2C),
    attentionContainer: Color(0xFF3F3018),
    escalationContainer: Color(0xFF4A2026),
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
