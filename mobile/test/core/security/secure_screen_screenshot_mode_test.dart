import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/config/app_config.dart';
import 'package:afterme/core/security/secure_screen.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/fake_platform.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

/// `SCREENSHOT_MODE` (a staging or dev build made to capture store screenshots) leaves the
/// window capturable and says so on every screen; the default keeps `FLAG_SECURE`.
AppConfig _staging({required bool screenshots}) => AppConfig.parse(
  appEnv: 'staging',
  apiBaseUrl: 'https://api.staging.afterme.invalid',
  publicBaseUrl: 'https://staging.afterme.invalid',
  screenshotMode: screenshots ? 'true' : 'false',
);

Future<FakeSecureScreenGateway> _pump(
  WidgetTester tester, {
  AppConfig? config,
}) async {
  final gateway = FakeSecureScreenGateway();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        secureScreenGatewayProvider.overrideWithValue(gateway),
        if (config != null) appConfigProvider.overrideWithValue(config),
      ],
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: SecureScreen(child: Text('content')),
      ),
    ),
  );
  return gateway;
}

void main() {
  group('SecureScreen and SCREENSHOT_MODE', () {
    testWidgets('staging with screenshot mode never touches the platform '
        'channel', (tester) async {
      final gateway = await _pump(tester, config: _staging(screenshots: true));
      await tester.pump();
      expect(gateway.calls, isEmpty);
      expect(gateway.secure, isFalse);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(gateway.calls, isEmpty, reason: 'nothing to clear either');
    });

    testWidgets('staging without it keeps FLAG_SECURE', (tester) async {
      final gateway = await _pump(tester, config: _staging(screenshots: false));
      expect(gateway.calls, [true]);
      expect(gateway.secure, isTrue);
    });

    testWidgets('with no configuration at all the window stays secure', (
      tester,
    ) async {
      final gateway = await _pump(tester);
      expect(gateway.calls, [true]);
    });

    test('the reference counting is unchanged when it is off', () async {
      final gateway = FakeSecureScreenGateway();
      final screens = SecureScreens(gateway);
      screens.acquire();
      screens.acquire();
      screens.release();
      screens.release();
      await Future<void>.value();
      expect(gateway.calls, [true, false]);
    });

    test('and counts holders without calling anything when it is on', () async {
      final gateway = FakeSecureScreenGateway();
      final screens = SecureScreens(gateway, screenshotMode: true);
      screens.acquire();
      expect(screens.holders, 1);
      screens.release();
      await Future<void>.value();
      expect(screens.holders, 0);
      expect(gateway.calls, isEmpty);
    });
  });

  group('the whole app in screenshot mode', () {
    testWidgets('shows the strip on every kind of screen and does not hold '
        'FLAG_SECURE on an instruction screen', (tester) async {
      final fakes = TestFakes();
      final container = await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedOut,
        config: _staging(screenshots: true),
      );
      // Welcome (signed out).
      expect(find.text('Screenshot mode'), findsOneWidget);
      expect(container.read(screenshotModeProvider), isTrue);
    });

    testWidgets('signed in: the strip is on Home and on the instructions tab, '
        'and the window was never made secure', (tester) async {
      final fakes = TestFakes();
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructions,
        config: _staging(screenshots: true),
      );
      expect(find.text('Screenshot mode'), findsOneWidget);
      expect(fakes.secureScreen.calls, isEmpty);
    });

    testWidgets('a normal build has no strip, and the instructions tab is '
        'secure', (tester) async {
      final fakes = TestFakes();
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructions,
        config: _staging(screenshots: false),
      );
      expect(find.text('Screenshot mode'), findsNothing);
      expect(fakes.secureScreen.calls, isNotEmpty);
      expect(fakes.secureScreen.secure, isTrue);
    });
  });
}
