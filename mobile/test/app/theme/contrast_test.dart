import 'dart:io';

import 'package:afterme/app/theme/app_theme.dart';
import 'package:afterme/app/theme/contrast.dart';
import 'package:afterme/app/theme/tokens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// WCAG 2.x AA contrast for every token pair the UI uses (USER_FLOWS.md §1.2, §1.4).
///
/// Usage rules the thresholds encode:
/// * text, textMuted: body text on bg and surface → 4.5:1.
/// * primary/onPrimary: filled buttons and the I'M OK button → 4.5:1.
/// * ok, attention, escalation: used as TEXT (status labels) on bg and surface →
///   4.5:1. On their tinted containers they are only icons/accents → 3:1, while the
///   banner text uses `text` → 4.5:1.
/// * onPrimary on filled ok/attention/escalation (check-in success etc.) → 4.5:1.
/// * outline: interactive component boundaries → 3:1 (WCAG 1.4.11).
void main() {
  const themes = {'light': AppColorTokens.light, 'dark': AppColorTokens.dark};

  group('contrastRatio', () {
    test('matches the WCAG reference values', () {
      expect(
        contrastRatio(const Color(0xFF000000), const Color(0xFFFFFFFF)),
        closeTo(21, 0.001),
      );
      expect(
        contrastRatio(const Color(0xFFFFFFFF), const Color(0xFFFFFFFF)),
        closeTo(1, 0.001),
      );
      // #767676 on white is the classic 4.54:1 boundary colour.
      expect(
        contrastRatio(const Color(0xFF767676), const Color(0xFFFFFFFF)),
        closeTo(4.54, 0.01),
      );
    });
  });

  for (final MapEntry(key: name, value: t) in themes.entries) {
    group('$name tokens', () {
      void expectContrast(String label, Color fg, Color bg, double minimum) {
        final ratio = contrastRatio(fg, bg);
        expect(
          ratio,
          greaterThanOrEqualTo(minimum),
          reason:
              '$name: $label is ${ratio.toStringAsFixed(2)}:1, needs $minimum:1',
        );
      }

      test('text and textMuted on bg and surface >= 4.5', () {
        for (final (label, color) in [
          ('text', t.text),
          ('textMuted', t.textMuted),
        ]) {
          expectContrast('$label on bg', color, t.bg, WcagAA.text);
          expectContrast('$label on surface', color, t.surface, WcagAA.text);
        }
      });

      test('primary/onPrimary >= 4.5, and primary as text >= 4.5', () {
        expectContrast(
          'onPrimary on primary',
          t.onPrimary,
          t.primary,
          WcagAA.text,
        );
        expectContrast('primary on bg', t.primary, t.bg, WcagAA.text);
        expectContrast('primary on surface', t.primary, t.surface, WcagAA.text);
      });

      test('status colours as text on bg and surface >= 4.5', () {
        for (final (label, color) in [
          ('ok', t.ok),
          ('attention', t.attention),
          ('escalation', t.escalation),
        ]) {
          expectContrast('$label on bg', color, t.bg, WcagAA.text);
          expectContrast('$label on surface', color, t.surface, WcagAA.text);
        }
      });

      test('onPrimary on filled status colours >= 4.5', () {
        for (final (label, color) in [
          ('ok', t.ok),
          ('attention', t.attention),
          ('escalation', t.escalation),
        ]) {
          expectContrast(
            'onPrimary on $label',
            t.onPrimary,
            color,
            WcagAA.text,
          );
        }
      });

      test('status containers: text >= 4.5, accent icons >= 3', () {
        for (final (label, accent, container) in [
          ('info', t.primary, t.primaryContainer),
          ('ok', t.ok, t.okContainer),
          ('attention', t.attention, t.attentionContainer),
          ('escalation', t.escalation, t.escalationContainer),
        ]) {
          expectContrast(
            'text on ${label}Container',
            t.text,
            container,
            WcagAA.text,
          );
          expectContrast(
            '$label icon on ${label}Container',
            accent,
            container,
            WcagAA.largeTextOrGraphics,
          );
        }
      });

      test('outline (component boundaries) >= 3 on bg and surface', () {
        expectContrast(
          'outline on bg',
          t.outline,
          t.bg,
          WcagAA.largeTextOrGraphics,
        );
        expectContrast(
          'outline on surface',
          t.outline,
          t.surface,
          WcagAA.largeTextOrGraphics,
        );
      });
    });
  }

  test('tokens match the tables in USER_FLOWS.md §1.2', () {
    // `flutter test` runs with the package root (mobile/) as the working directory.
    final doc = File('../docs/USER_FLOWS.md').readAsStringSync();
    final start = doc.indexOf('### 1.2');
    final end = doc.indexOf('### 1.3');
    expect(start, isNonNegative, reason: 'section 1.2 not found');
    expect(end, greaterThan(start), reason: 'section 1.3 not found');
    final section = doc.substring(start, end);

    final fields = <String, Color Function(AppColorTokens)>{
      'bg': (t) => t.bg,
      'surface': (t) => t.surface,
      'text': (t) => t.text,
      'textMuted': (t) => t.textMuted,
      'primary': (t) => t.primary,
      'ok': (t) => t.ok,
      'attention': (t) => t.attention,
      'escalation': (t) => t.escalation,
      'border': (t) => t.border,
      'onPrimary': (t) => t.onPrimary,
      'outline': (t) => t.outline,
      'primaryContainer': (t) => t.primaryContainer,
      'okContainer': (t) => t.okContainer,
      'attentionContainer': (t) => t.attentionContainer,
      'escalationContainer': (t) => t.escalationContainer,
    };

    final row = RegExp(
      r'^\|\s*`(\w+)`\s*\|\s*`#([0-9A-Fa-f]{6})`\s*\|\s*`#([0-9A-Fa-f]{6})`',
      multiLine: true,
    );
    final documented = <String>{};
    for (final match in row.allMatches(section)) {
      final name = match.group(1)!;
      final field = fields[name];
      expect(
        field,
        isNotNull,
        reason: 'USER_FLOWS.md names unknown token $name',
      );
      documented.add(name);
      final lightHex = 0xFF000000 | int.parse(match.group(2)!, radix: 16);
      final darkHex = 0xFF000000 | int.parse(match.group(3)!, radix: 16);
      expect(
        field!(AppColorTokens.light).toARGB32(),
        lightHex,
        reason: 'light $name differs from USER_FLOWS.md',
      );
      expect(
        field(AppColorTokens.dark).toARGB32(),
        darkHex,
        reason: 'dark $name differs from USER_FLOWS.md',
      );
    }
    expect(
      documented,
      fields.keys.toSet(),
      reason: 'every token must be documented in USER_FLOWS.md §1.2',
    );
  });

  group('AppTheme', () {
    for (final (name, theme, tokens) in [
      ('light', AppTheme.light(), AppColorTokens.light),
      ('dark', AppTheme.dark(), AppColorTokens.dark),
    ]) {
      test('$name ColorScheme is built from tokens', () {
        final scheme = theme.colorScheme;
        expect(theme.useMaterial3, isTrue);
        expect(scheme.primary, tokens.primary);
        expect(scheme.onPrimary, tokens.onPrimary);
        expect(scheme.surface, tokens.bg);
        expect(scheme.surfaceContainerLow, tokens.surface);
        expect(scheme.onSurface, tokens.text);
        expect(scheme.onSurfaceVariant, tokens.textMuted);
        expect(scheme.error, tokens.escalation);
        expect(scheme.outline, tokens.outline);
        expect(scheme.outlineVariant, tokens.border);
        expect(theme.scaffoldBackgroundColor, tokens.bg);
        expect(theme.extension<AppTokens>()!.colors, same(tokens));
      });

      test(
        '$name typography and component sizes follow USER_FLOWS.md §1.3',
        () {
          final text = theme.textTheme;
          expect(text.bodyMedium!.fontSize, 16);
          expect(text.bodyLarge!.fontSize, 16);
          expect(text.bodyMedium!.height, 1.4);
          expect(text.titleLarge!.fontSize, 22);
          expect(text.headlineMedium!.fontSize, 28);
          expect(text.displaySmall!.fontSize, 34);
          expect(AppTypography.checkInLabel.fontSize, 24);
          expect(AppTypography.checkInLabel.fontWeight, FontWeight.w600);
          final minimum = theme.filledButtonTheme.style!.minimumSize!.resolve(
            {},
          )!;
          expect(minimum.height, greaterThanOrEqualTo(48));
          expect(
            theme.outlinedButtonTheme.style!.minimumSize!.resolve({})!.height,
            greaterThanOrEqualTo(48),
          );
          expect(
            theme.textButtonTheme.style!.minimumSize!.resolve({})!.height,
            greaterThanOrEqualTo(48),
          );
        },
      );
    }

    test('AppTokens lerp and copyWith', () {
      const a = AppTokens(AppColorTokens.light);
      const b = AppTokens(AppColorTokens.dark);
      expect(a.lerp(b, 0.2), same(a));
      expect(a.lerp(b, 0.8), same(b));
      expect(a.lerp(null, 0.8), same(a));
      expect(a.copyWith().colors, same(AppColorTokens.light));
      expect(
        a.copyWith(colors: AppColorTokens.dark).colors,
        same(AppColorTokens.dark),
      );
    });
  });
}
