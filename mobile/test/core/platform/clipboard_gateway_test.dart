import 'dart:async';

import 'package:afterme/core/platform/clipboard_gateway.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one clipboard use in the app: the About screen's "Copy diagnostic text" button.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> handle(Future<Object?> Function(MethodCall call) handler) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, handler);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  test('copies the text to the system clipboard and says so', () async {
    final calls = <MethodCall>[];
    await handle((call) async {
      calls.add(call);
      return null;
    });

    final copied = await const PlatformClipboardGateway().copy('one\ntwo');
    expect(copied, isTrue);
    expect(calls.map((c) => c.method), ['Clipboard.setData']);
    expect((calls.single.arguments as Map)['text'], 'one\ntwo');
  });

  test('says false, and never throws, when the system refuses', () async {
    await handle((call) async {
      throw PlatformException(code: 'unavailable');
    });
    expect(await const PlatformClipboardGateway().copy('x'), isFalse);
  });

  test('says false for every other kind of failure too (M-4)', () async {
    final failures = <Object Function()>[
      () => StateError('channel closed'),
      () => const FormatException('odd reply'),
      () => ArgumentError('bad'),
      () => TimeoutException('slow'),
    ];
    for (final failure in failures) {
      await handle((call) async => throw failure());
      expect(
        await const PlatformClipboardGateway().copy('x'),
        isFalse,
        reason: '${failure()}',
      );
    }
  });

  test('never reads the clipboard', () async {
    final methods = <String>[];
    await handle((call) async {
      methods.add(call.method);
      return null;
    });
    await const PlatformClipboardGateway().copy('x');
    expect(methods, isNot(contains('Clipboard.getData')));
  });
}
