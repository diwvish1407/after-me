import 'package:afterme/app/theme/app_theme.dart';
import 'package:afterme/app/theme/dimens.dart';
import 'package:afterme/core/design_system/check_in_button.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';

const _labels = {
  CheckInButtonState.idle: "I'M OK",
  CheckInButtonState.sending: 'Sending…',
  CheckInButtonState.success: 'Checked in',
  CheckInButtonState.pending: 'Not received yet',
  CheckInButtonState.disabled: "I'M OK",
};

const _hints = {
  CheckInButtonState.idle: "Lets AfterMe know you're OK",
  CheckInButtonState.sending: 'Sending your check-in',
  CheckInButtonState.success: 'AfterMe received your check-in',
  CheckInButtonState.pending: "We'll keep trying. Tap to try again now",
  CheckInButtonState.disabled: 'Not available right now',
};

const _icons = {
  CheckInButtonState.idle: Icons.check_rounded,
  CheckInButtonState.success: Icons.check_circle_rounded,
  CheckInButtonState.pending: Icons.schedule_rounded,
  CheckInButtonState.disabled: Icons.lock_clock_outlined,
};

/// The button's own semantics node (the Semantics widget inside CheckInButton).
Finder _node() => find
    .descendant(
      of: find.byType(CheckInButton),
      matching: find.byType(Semantics),
    )
    .first;

bool _interactive(CheckInButtonState state) =>
    state == CheckInButtonState.idle || state == CheckInButtonState.pending;

void main() {
  for (final state in CheckInButtonState.values) {
    group('$state', () {
      testWidgets('shows its own icon and text, and is at least 160 dp', (
        tester,
      ) async {
        await tester.pumpWidget(
          wrapForTest(CheckInButton(state: state, onPressed: () {})),
        );

        expect(find.text(_labels[state]!), findsOneWidget);
        if (state == CheckInButtonState.sending) {
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
        } else {
          expect(find.byIcon(_icons[state]!), findsOneWidget);
        }
        final size = tester.getSize(find.byType(CheckInButton));
        expect(size.width, greaterThanOrEqualTo(AppSizes.checkInButton));
        expect(size.height, greaterThanOrEqualTo(AppSizes.checkInButton));
      });

      testWidgets(
        'exposes button semantics with label, hint and a live region',
        (tester) async {
          final handle = tester.ensureSemantics();
          await tester.pumpWidget(
            wrapForTest(CheckInButton(state: state, onPressed: () {})),
          );

          expect(
            tester.getSemantics(_node()),
            isSemantics(
              label: _labels[state],
              hint: _hints[state],
              isButton: true,
              hasEnabledState: true,
              isEnabled: _interactive(state),
              isLiveRegion: true,
              hasTapAction: _interactive(state),
            ),
          );
          expect(find.bySemanticsLabel(_labels[state]!), findsOneWidget);
          handle.dispose();
        },
      );

      for (final (themeName, theme) in [
        ('light', AppTheme.light()),
        ('dark', AppTheme.dark()),
      ]) {
        testWidgets('meets the accessibility guidelines ($themeName)', (
          tester,
        ) async {
          final handle = tester.ensureSemantics();
          await tester.pumpWidget(
            wrapForTest(
              CheckInButton(state: state, onPressed: () {}),
              theme: theme,
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));

          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          handle.dispose();
        });
      }
    });
  }

  testWidgets('tapping idle calls onPressed once with haptic feedback', (
    tester,
  ) async {
    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add('${call.arguments}');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    var presses = 0;
    await tester.pumpWidget(
      wrapForTest(
        CheckInButton(
          state: CheckInButtonState.idle,
          onPressed: () => presses++,
        ),
      ),
    );

    await tester.tap(find.byType(CheckInButton));
    await tester.pump();

    expect(presses, 1);
    expect(haptics, ['HapticFeedbackType.mediumImpact']);
  });

  testWidgets('pending is tappable to retry', (tester) async {
    var presses = 0;
    await tester.pumpWidget(
      wrapForTest(
        CheckInButton(
          state: CheckInButtonState.pending,
          onPressed: () => presses++,
        ),
      ),
    );
    await tester.tap(find.byType(CheckInButton));
    expect(presses, 1);
  });

  for (final state in [
    CheckInButtonState.sending,
    CheckInButtonState.success,
    CheckInButtonState.disabled,
  ]) {
    testWidgets('$state ignores taps', (tester) async {
      var presses = 0;
      await tester.pumpWidget(
        wrapForTest(CheckInButton(state: state, onPressed: () => presses++)),
      );
      await tester.tap(find.byType(CheckInButton), warnIfMissed: false);
      await tester.pump();
      expect(presses, 0);
    });
  }

  testWidgets('idle without a callback is not interactive', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      wrapForTest(
        const CheckInButton(state: CheckInButtonState.idle, onPressed: null),
      ),
    );
    expect(
      tester.getSemantics(_node()),
      isSemantics(isEnabled: false, hasTapAction: false),
    );
    handle.dispose();
  });

  testWidgets('a state change updates the live-region label', (tester) async {
    final handle = tester.ensureSemantics();
    Widget build(CheckInButtonState state) =>
        wrapForTest(CheckInButton(state: state, onPressed: () {}));

    await tester.pumpWidget(build(CheckInButtonState.idle));
    await tester.pumpWidget(build(CheckInButtonState.sending));
    expect(
      tester.getSemantics(_node()),
      isSemantics(label: 'Sending…', isLiveRegion: true),
    );
    await tester.pumpWidget(build(CheckInButtonState.success));
    expect(
      tester.getSemantics(_node()),
      isSemantics(label: 'Checked in', isLiveRegion: true),
    );
    handle.dispose();
  });

  for (final state in CheckInButtonState.values) {
    testWidgets('$state grows with 2.0 text scale and does not overflow', (
      tester,
    ) async {
      usePhoneScreen(tester);
      await tester.pumpWidget(
        wrapForTest(
          CheckInButton(state: state, onPressed: () {}),
          textScaler: const TextScaler.linear(2),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      final size = tester.getSize(find.byType(CheckInButton));
      expect(size.width, greaterThan(AppSizes.checkInButton));
      expect(size.width, lessThanOrEqualTo(390));
      expect(find.text(_labels[state]!), findsOneWidget);
    });
  }

  for (final scale in [1.0, 1.5, 2.0]) {
    for (final state in CheckInButtonState.values) {
      testWidgets(
        '$state at ${scale}x never splits a word and stays inside the circle',
        (tester) async {
          usePhoneScreen(tester);
          await tester.pumpWidget(
            wrapForTest(
              CheckInButton(state: state, onPressed: () {}),
              textScaler: TextScaler.linear(scale),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);

          // A word is split only when the laid-out width is below its own minimum width.
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(_labels[state]!),
          );
          expect(
            paragraph.size.width,
            greaterThanOrEqualTo(
              paragraph.getMinIntrinsicWidth(double.infinity) - 0.5,
            ),
            reason: 'a word of "${_labels[state]}" is broken across lines',
          );

          // The whole icon + label block lies within the circle (corners no farther
          // than the radius from the centre).
          final circle = tester.getRect(find.byType(CheckInButton));
          final block = tester.getRect(
            find.descendant(
              of: find.byType(FittedBox),
              matching: find.byType(Column),
            ),
          );
          for (final corner in [
            block.topLeft,
            block.topRight,
            block.bottomLeft,
            block.bottomRight,
          ]) {
            expect(
              (corner - circle.center).distance,
              lessThanOrEqualTo(circle.width / 2 + 0.5),
              reason: 'content corner $corner pokes outside the circle $circle',
            );
          }
        },
      );
    }
  }
}
