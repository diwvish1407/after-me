import 'package:afterme/app/app.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/real_fonts.dart';
import '../helpers/test_app.dart';

/// The bottom-navigation labels must never wrap inside a word or spill into a
/// neighbouring destination, on narrow phones and at large system font sizes.
void main() {
  setUpAll(loadRoboto);

  const screens = {
    'Galaxy 360x780': Size(360, 780),
    'small 320x690': Size(320, 690),
  };
  for (final MapEntry(key: screenName, value: size) in screens.entries) {
    for (final scale in [1.0, 1.15, 2.0]) {
      testWidgets('labels fit their destination on $screenName at ${scale}x', (
        tester,
      ) async {
        usePhoneScreen(tester, size: size);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(
          ProviderScope(
            overrides: testOverrides(authStatus: AuthStatus.signedIn),
            child: const AfterMeApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final bar = find.byType(NavigationBar);
        final barRect = tester.getRect(bar);
        final texts = find.descendant(of: bar, matching: find.byType(Text));
        expect(texts, findsNWidgets(5));

        final destinationWidth = barRect.width / 5;
        final tops = <double>[];
        for (var i = 0; i < 5; i++) {
          final label = texts.at(i);
          final paragraph = tester.renderObject<RenderParagraph>(label);
          expect(
            paragraph.size.width,
            greaterThanOrEqualTo(
              paragraph.getMinIntrinsicWidth(double.infinity) - 0.5,
            ),
            reason: 'label $i is broken across lines',
          );
          final rect = tester.getRect(label);
          expect(rect.left, greaterThanOrEqualTo(i * destinationWidth - 0.5));
          expect(
            rect.right,
            lessThanOrEqualTo((i + 1) * destinationWidth + 0.5),
          );
          tops.add(rect.top);
        }
        // All five labels sit on the same line, so no icon is pushed out of line.
        expect(
          tops.reduce((a, b) => a > b ? a : b) -
              tops.reduce((a, b) => a < b ? a : b),
          lessThan(1),
        );
      });
    }
  }
}
