import 'package:material_ui/material_ui.dart';

import 'dimens.dart';
import 'reduced_motion_transitions.dart';
import 'tokens.dart';

/// Type scale from USER_FLOWS.md §1.3: body 16 sp (line height 1.4), titles
/// 22/28/34 sp, check-in label 24 sp semibold.
///
/// The platform default font (Roboto on Android) is still used. Bundling an
/// OFL-licensed humanist sans (no runtime downloads) is deferred to Phase 11.
abstract final class AppTypography {
  static const TextStyle checkInLabel = TextStyle(
    fontSize: 24,
    height: 1.2,
    fontWeight: FontWeight.w600,
  );

  static TextTheme textTheme(AppColorTokens t) {
    const theme = TextTheme(
      displaySmall: TextStyle(
        fontSize: 34,
        height: 1.2,
        fontWeight: FontWeight.w600,
      ),
      headlineMedium: TextStyle(
        fontSize: 28,
        height: 1.25,
        fontWeight: FontWeight.w600,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        height: 1.3,
        fontWeight: FontWeight.w600,
      ),
      titleLarge: TextStyle(
        fontSize: 22,
        height: 1.3,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: TextStyle(
        fontSize: 18,
        height: 1.35,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: TextStyle(
        fontSize: 16,
        height: 1.4,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.4),
      bodyMedium: TextStyle(fontSize: 16, height: 1.4),
      bodySmall: TextStyle(fontSize: 14, height: 1.4),
      labelLarge: TextStyle(
        fontSize: 16,
        height: 1.25,
        fontWeight: FontWeight.w600,
      ),
      labelMedium: TextStyle(
        fontSize: 14,
        height: 1.3,
        fontWeight: FontWeight.w600,
      ),
      labelSmall: TextStyle(
        fontSize: 12,
        height: 1.3,
        fontWeight: FontWeight.w500,
      ),
    );
    return theme.apply(bodyColor: t.text, displayColor: t.text);
  }
}

/// Builds the light and dark Material 3 themes explicitly from [AppColorTokens].
abstract final class AppTheme {
  /// The header colour of every app bar (the dark end of the brand gradient).
  static const Color headerBlue = Color(0xFF07267F);

  /// [fontFamily] is null in the app (the platform font). Layout tests pass `Roboto`
  /// so they measure real glyphs instead of the test engine's square fallback font.
  static ThemeData light({String? fontFamily}) =>
      build(AppColorTokens.light, Brightness.light, fontFamily: fontFamily);

  static ThemeData dark({String? fontFamily}) =>
      build(AppColorTokens.dark, Brightness.dark, fontFamily: fontFamily);

  /// The colour scheme, every role set from a token (no seed generation).
  ///
  /// Mapping: `surface` is the app background ([AppColorTokens.bg]); the surface
  /// containers (cards, sheets, navigation bar, dialogs) are [AppColorTokens.surface].
  static ColorScheme colorScheme(AppColorTokens t, Brightness brightness) {
    final inverse = brightness == Brightness.light
        ? AppColorTokens.dark
        : AppColorTokens.light;
    return ColorScheme(
      brightness: brightness,
      primary: t.primary,
      onPrimary: t.onPrimary,
      primaryContainer: t.primaryContainer,
      onPrimaryContainer: t.text,
      secondary: t.primary,
      onSecondary: t.onPrimary,
      secondaryContainer: t.primaryContainer,
      onSecondaryContainer: t.text,
      tertiary: t.ok,
      onTertiary: t.onPrimary,
      tertiaryContainer: t.okContainer,
      onTertiaryContainer: t.text,
      error: t.escalation,
      onError: t.onPrimary,
      errorContainer: t.escalationContainer,
      onErrorContainer: t.text,
      surface: t.bg,
      onSurface: t.text,
      onSurfaceVariant: t.textMuted,
      surfaceDim: t.bg,
      surfaceBright: t.surface,
      surfaceContainerLowest: t.surface,
      surfaceContainerLow: t.surface,
      surfaceContainer: t.surface,
      surfaceContainerHigh: t.surface,
      surfaceContainerHighest: t.border,
      outline: t.outline,
      outlineVariant: t.border,
      shadow: const Color(0xFF000000),
      scrim: const Color(0xFF000000),
      inverseSurface: inverse.surface,
      onInverseSurface: inverse.text,
      inversePrimary: inverse.primary,
      surfaceTint: const Color(0x00000000),
    );
  }

  static ThemeData build(
    AppColorTokens t,
    Brightness brightness, {
    String? fontFamily,
  }) {
    final scheme = colorScheme(t, brightness);
    final base = AppTypography.textTheme(t);
    final text = fontFamily == null ? base : base.apply(fontFamily: fontFamily);
    const minSize = Size(AppSizes.minTouchTarget, AppSizes.minTouchTarget);
    const buttonPadding = EdgeInsets.symmetric(
      horizontal: AppSpacing.lg,
      vertical: AppSpacing.sm,
    );
    // The 2026-11 redesign: pill buttons, softly filled fields, rounder cards.
    const buttonShape = StadiumBorder();
    OutlineInputBorder inputBorder(Color color, {double width = 1}) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: BorderSide(color: color, width: width),
        );

    return ThemeData(
      useMaterial3: true,
      fontFamily: fontFamily,
      brightness: brightness,
      colorScheme: scheme,
      textTheme: text,
      scaffoldBackgroundColor: t.bg,
      canvasColor: t.bg,
      dividerColor: t.border,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      // Pages stand still when the phone is set to remove animations.
      pageTransitionsTheme: reducedMotionPageTransitions(),
      extensions: [AppTokens(t)],
      // The 2026-11 redesign: every screen's header is the deep brand blue with white
      // text (>= 12:1), like the gradient headers of the design screens.
      appBarTheme: AppBarThemeData(
        backgroundColor: AppTheme.headerBlue,
        foregroundColor: const Color(0xFFFFFFFF),
        iconTheme: const IconThemeData(color: Color(0xFFFFFFFF)),
        actionsIconTheme: const IconThemeData(color: Color(0xFFFFFFFF)),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(
          color: const Color(0xFFFFFFFF),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.primary,
          foregroundColor: t.onPrimary,
          minimumSize: minSize,
          padding: buttonPadding,
          shape: buttonShape,
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.primary,
          minimumSize: minSize,
          padding: buttonPadding,
          shape: buttonShape,
          side: BorderSide(color: t.outline),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: t.primary,
          minimumSize: minSize,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          shape: buttonShape,
          textStyle: text.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: minSize),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: brightness == Brightness.light
            ? const Color(0xFFF4F7FF)
            : t.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        border: inputBorder(t.outline),
        enabledBorder: inputBorder(t.outline),
        focusedBorder: inputBorder(t.primary, width: 2),
        errorBorder: inputBorder(t.escalation),
        focusedErrorBorder: inputBorder(t.escalation, width: 2),
        disabledBorder: inputBorder(t.border),
        labelStyle: text.bodyLarge?.copyWith(color: t.textMuted),
        floatingLabelStyle: text.bodyMedium?.copyWith(color: t.primary),
        hintStyle: text.bodyLarge?.copyWith(color: t.textMuted),
        helperStyle: text.bodySmall?.copyWith(color: t.textMuted),
        errorStyle: text.bodySmall?.copyWith(color: t.escalation),
        errorMaxLines: 3,
        helperMaxLines: 3,
      ),
      cardTheme: CardThemeData(
        color: t.surface,
        elevation: 3,
        shadowColor: const Color(0x2E0B4FE0),
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: t.border),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: const Color(0x00000000),
        indicatorColor: t.primaryContainer,
        elevation: 0,
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? text.labelMedium?.copyWith(
                  color: t.primary,
                  fontSize: AppSizes.navLabelSp,
                )
              : text.labelMedium?.copyWith(
                  color: t.textMuted,
                  fontSize: AppSizes.navLabelSp,
                  fontWeight: FontWeight.w500,
                ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected)
                ? t.primary
                : t.textMuted,
          ),
        ),
      ),
      dividerTheme: DividerThemeData(color: t.border, thickness: 1, space: 1),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: t.primary,
        circularTrackColor: t.border,
        linearTrackColor: t.border,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: inverseSurfaceFor(brightness),
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: t.textMuted,
        textColor: t.text,
        minTileHeight: AppSizes.minTouchTarget,
        // Subtitles are small and greyed out everywhere.
        subtitleTextStyle: text.bodySmall?.copyWith(color: t.textMuted),
      ),
    );
  }

  static Color inverseSurfaceFor(Brightness brightness) =>
      brightness == Brightness.light
      ? AppColorTokens.dark.surface
      : AppColorTokens.light.surface;
}
