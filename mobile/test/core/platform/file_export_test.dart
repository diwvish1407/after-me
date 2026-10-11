import 'package:afterme/core/platform/file_export.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.afterme/export');

  void answer(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  final bytes = Uint8List.fromList([123, 125]);

  test(
    'hands the bytes, the suggested name and the type to the activity',
    () async {
      MethodCall? seen;
      answer((call) async {
        seen = call;
        return 'saved';
      });
      final result = await const PlatformFileExportGateway().save(
        bytes: bytes,
        suggestedName: 'afterme-export.json',
      );
      expect(result, FileExportResult.saved);
      expect(seen!.method, 'saveFile');
      final args = seen!.arguments as Map;
      expect(args['bytes'], bytes);
      expect(args['name'], 'afterme-export.json');
      expect(args['mimeType'], 'application/json');
    },
  );

  test('"saved" is only what the system answered "saved"', () async {
    answer((_) async => 'saved');
    expect(
      await const PlatformFileExportGateway().save(
        bytes: bytes,
        suggestedName: 'x.json',
      ),
      FileExportResult.saved,
    );
    answer((_) async => 'cancelled');
    expect(
      await const PlatformFileExportGateway().save(
        bytes: bytes,
        suggestedName: 'x.json',
      ),
      FileExportResult.cancelled,
    );
  });

  test('any other answer is a failure, never a confirmation', () async {
    for (final reply in <Object?>[null, 'ok', true, 7]) {
      answer((_) async => reply);
      await expectLater(
        const PlatformFileExportGateway().save(
          bytes: bytes,
          suggestedName: 'x.json',
        ),
        throwsA(
          isA<FileExportException>().having(
            (e) => e.error,
            'error',
            FileExportError.failed,
          ),
        ),
        reason: '$reply',
      );
    }
  });

  test(
    'no document provider is "unavailable", a failed write is "failed"',
    () async {
      answer((_) async => throw PlatformException(code: 'unavailable'));
      await expectLater(
        const PlatformFileExportGateway().save(
          bytes: bytes,
          suggestedName: 'x.json',
        ),
        throwsA(
          isA<FileExportException>().having(
            (e) => e.error,
            'error',
            FileExportError.unavailable,
          ),
        ),
      );
      answer((_) async => throw PlatformException(code: 'failed'));
      await expectLater(
        const PlatformFileExportGateway().save(
          bytes: bytes,
          suggestedName: 'x.json',
        ),
        throwsA(
          isA<FileExportException>().having(
            (e) => e.error,
            'error',
            FileExportError.failed,
          ),
        ),
      );
      answer((_) async => throw PlatformException(code: 'busy'));
      await expectLater(
        const PlatformFileExportGateway().save(
          bytes: bytes,
          suggestedName: 'x.json',
        ),
        throwsA(isA<FileExportException>()),
      );
    },
  );

  test(
    'without a platform implementation it is unavailable, not a crash',
    () async {
      await expectLater(
        const PlatformFileExportGateway().save(
          bytes: bytes,
          suggestedName: 'x.json',
        ),
        throwsA(
          isA<FileExportException>().having(
            (e) => e.error,
            'error',
            FileExportError.unavailable,
          ),
        ),
      );
      expect(
        const FileExportException(FileExportError.failed).toString(),
        contains('failed'),
      );
    },
  );

  test('without overrides the real gateway is used', () {
    final container = ProviderContainer.test();
    expect(
      container.read(fileExportGatewayProvider),
      isA<PlatformFileExportGateway>(),
    );
  });
}
