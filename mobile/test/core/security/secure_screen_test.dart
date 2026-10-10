import 'package:afterme/core/security/secure_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_platform.dart';

void main() {
  group('SecureScreens (reference counted)', () {
    test(
      'the flag is set by the first screen and cleared after the last',
      () async {
        final gateway = FakeSecureScreenGateway();
        final screens = SecureScreens(gateway);
        screens.acquire();
        expect(gateway.calls, [true], reason: 'set at once');
        screens.acquire();
        expect(gateway.calls, [
          true,
        ], reason: 'a second screen sets nothing more');
        screens.release();
        await Future<void>.value();
        expect(gateway.secure, isTrue, reason: 'one screen still needs it');
        expect(screens.holders, 1);
        screens.release();
        expect(screens.holders, 0);
        await Future<void>.value();
        expect(gateway.calls, [true, false]);
      },
    );

    test(
      'a page replaced by another in the same frame never clears it',
      () async {
        final gateway = FakeSecureScreenGateway();
        final screens = SecureScreens(gateway);
        screens.acquire();
        // The old page lets go, then the new one takes hold, before anything else runs.
        screens.release();
        screens.acquire();
        await Future<void>.value();
        expect(gateway.calls, [true]);
        expect(gateway.secure, isTrue);
      },
    );

    test('letting go more often than holding is harmless', () async {
      final gateway = FakeSecureScreenGateway();
      final screens = SecureScreens(gateway);
      screens.release();
      await Future<void>.value();
      expect(screens.holders, 0);
      expect(gateway.calls, isEmpty);
      screens.acquire();
      expect(gateway.secure, isTrue);
    });
  });

  group('SecureScreen (widget)', () {
    Future<FakeSecureScreenGateway> pump(
      WidgetTester tester,
      Widget child,
    ) async {
      final gateway = FakeSecureScreenGateway();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [secureScreenGatewayProvider.overrideWithValue(gateway)],
          child: Directionality(textDirection: TextDirection.ltr, child: child),
        ),
      );
      return gateway;
    }

    testWidgets('is secure while it is in the tree and not after', (
      tester,
    ) async {
      final gateway = await pump(
        tester,
        const SecureScreen(child: Text('content')),
      );
      expect(gateway.calls, [true]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [secureScreenGatewayProvider.overrideWithValue(gateway)],
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: Text('gone'),
          ),
        ),
      );
      await tester.pump();
      expect(gateway.calls, [true, false]);
    });

    testWidgets('lets go while it is built but not shown (another tab, a '
        'covered page) and takes hold again when it is shown', (tester) async {
      final gateway = FakeSecureScreenGateway();
      Widget tree({required bool shown}) => ProviderScope(
        overrides: [secureScreenGatewayProvider.overrideWithValue(gateway)],
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: TickerMode(
            enabled: shown,
            child: const SecureScreen(child: Text('content')),
          ),
        ),
      );
      await tester.pumpWidget(tree(shown: true));
      expect(gateway.secure, isTrue);
      await tester.pumpWidget(tree(shown: false));
      await tester.pump();
      expect(gateway.secure, isFalse);
      expect(find.text('content'), findsOneWidget, reason: 'still built');
      await tester.pumpWidget(tree(shown: true));
      await tester.pump();
      expect(gateway.secure, isTrue);
      expect(gateway.calls, [true, false, true]);
    });

    testWidgets('nested screens hold it together', (tester) async {
      final gateway = await pump(
        tester,
        const SecureScreen(child: SecureScreen(child: Text('content'))),
      );
      expect(gateway.calls, [true]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [secureScreenGatewayProvider.overrideWithValue(gateway)],
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: SecureScreen(child: Text('outer only')),
          ),
        ),
      );
      await tester.pump();
      expect(gateway.secure, isTrue, reason: 'the outer one is still shown');
    });
  });

  group('PlatformSecureScreenGateway', () {
    const channel = MethodChannel('app.afterme/secure_screen');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    TestWidgetsFlutterBinding ensure() =>
        TestWidgetsFlutterBinding.ensureInitialized();

    test('sends the flag to the activity on its own channel', () async {
      ensure();
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      const gateway = PlatformSecureScreenGateway();
      await gateway.setSecure(enabled: true);
      await gateway.setSecure(enabled: false);
      expect([for (final c in calls) c.method], ['setSecure', 'setSecure']);
      expect(
        [for (final c in calls) c.arguments],
        [
          {'enabled': true},
          {'enabled': false},
        ],
      );
    });

    test('no platform implementation or a platform error is ignored', () async {
      ensure();
      await const PlatformSecureScreenGateway().setSecure(enabled: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'nope');
          });
      await const PlatformSecureScreenGateway().setSecure(enabled: false);
    });

    test('without overrides the real gateway is used', () {
      final container = ProviderContainer.test();
      expect(
        container.read(secureScreenGatewayProvider),
        isA<PlatformSecureScreenGateway>(),
      );
      expect(container.read(secureScreensProvider), isA<SecureScreens>());
    });
  });
}
