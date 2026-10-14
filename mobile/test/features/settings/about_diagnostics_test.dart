import 'package:afterme/app/router.dart';
import 'package:afterme/core/config/app_config.dart';
import 'package:afterme/features/settings/presentation/about_screen.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/test_app.dart';

/// About: what a tester quotes in a bug report, the one explicit "Copy diagnostic text"
/// action, and the legal links that come from the configured public address.
final _l10n = AppLocalizationsEn();

AppConfig _staging() => AppConfig.parse(
  appEnv: 'staging',
  apiBaseUrl: 'https://api.staging.afterme.invalid',
  publicBaseUrl: 'https://staging.afterme.invalid',
);

void main() {
  group('diagnosticLines', () {
    test('are the version, build number, environment and API host, and '
        'nothing else', () {
      final lines = diagnosticLines(
        _l10n,
        info: testClientInfo,
        config: _staging(),
      );
      expect(lines, [
        'Version: 0.1.0',
        'Build number: 7',
        'Environment: staging',
        'Server: api.staging.afterme.invalid',
      ]);
    });

    test(
      'a development server shows its port, and never a scheme or a path',
      () {
        final lines = diagnosticLines(
          _l10n,
          info: testClientInfo,
          config: devConfig,
        );
        expect(lines.last, 'Server: 10.0.2.2:8000');
        expect(lines.join('\n'), isNot(contains('http')));
        expect(lines.join('\n'), isNot(contains('/v1')));
      },
    );
  });

  group('the About screen', () {
    testWidgets('shows the four lines, and the copy button puts exactly those '
        'lines on the clipboard, confirmed with a snackbar', (tester) async {
      final fakes = TestFakes();
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsAbout);
      for (final line in [
        'Version: 0.1.0',
        'Build number: 7',
        'Environment: dev',
        'Server: 10.0.2.2:8000',
      ]) {
        expect(find.text(line), findsOneWidget, reason: line);
      }
      expect(
        fakes.clipboard.copied,
        isEmpty,
        reason: 'nothing is copied alone',
      );

      await tester.ensureVisible(find.text('Copy diagnostic text'));
      await tester.pump();
      await tester.tap(find.text('Copy diagnostic text'));
      await tester.pump();
      expect(fakes.clipboard.copied, [
        'Version: 0.1.0\nBuild number: 7\nEnvironment: dev\nServer: 10.0.2.2:8000',
      ]);
      expect(
        snackText(tester),
        'Copied. You can paste it into your bug report.',
      );
    });

    testWidgets('a clipboard that refuses is said, not claimed', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.clipboard.refuse = true;
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsAbout);
      await tester.ensureVisible(find.text('Copy diagnostic text'));
      await tester.pump();
      await tester.tap(find.text('Copy diagnostic text'));
      await tester.pump();
      expect(fakes.clipboard.copied, isEmpty);
      expect(snackText(tester), startsWith("We couldn't copy that"));
    });

    testWidgets('a clipboard that fails with something other than a '
        'PlatformException (M-4) is said too, with no uncaught error', (
      tester,
    ) async {
      final fakes = TestFakes()..realClipboard = true;
      // The production gateway on a channel whose handler throws something that is not
      // a PlatformException.
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsAbout);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              throw StateError('channel closed');
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.ensureVisible(find.text('Copy diagnostic text'));
      await tester.pump();
      await tester.tap(find.text('Copy diagnostic text'));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(snackText(tester), startsWith("We couldn't copy that"));
    });

    testWidgets('never shows a token, an account id or an email', (
      tester,
    ) async {
      final fakes = TestFakes();
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsAbout);
      final shown = [
        for (final e in find.byType(Text).evaluate())
          (e.widget as Text).data ?? '',
      ].join('\n');
      // The test session's account is user-1 (`TestFakes` seeds the session).
      for (final secret in ['user-1', 'access-', 'refresh-', '@']) {
        expect(shown, isNot(contains(secret)), reason: secret);
      }
    });

    testWidgets('the legal links open the configured public address', (
      tester,
    ) async {
      final fakes = TestFakes();
      await pumpAboutWith(tester, fakes, _staging());
      await tester.tap(find.text('Terms of Service'));
      await tester.pump();
      await tester.tap(find.text('Privacy Policy'));
      await tester.pump();
      expect(fakes.urls.opened, [
        Uri.parse('https://staging.afterme.invalid/legal/terms'),
        Uri.parse('https://staging.afterme.invalid/legal/privacy'),
      ]);
    });
  });
}

Future<void> pumpAboutWith(
  WidgetTester tester,
  TestFakes fakes,
  AppConfig config,
) => openApp(
  tester,
  fakes: fakes,
  route: AppRoutes.settingsAbout,
  config: config,
);
