import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_16kb.dart';

/// A minimal little-endian ELF file with one program header per entry of [segments]
/// (type, alignment).
Uint8List _elf({required bool is64, required List<(int, int)> segments}) {
  final headerSize = is64 ? 64 : 52;
  final phentsize = is64 ? 56 : 32;
  final bytes = Uint8List(headerSize + phentsize * segments.length);
  final view = ByteData.sublistView(bytes);
  const le = Endian.little;
  bytes
    ..[0] = 0x7F
    ..[1] = 0x45
    ..[2] = 0x4C
    ..[3] = 0x46
    ..[4] = is64 ? 2 : 1
    ..[5] = 1;
  if (is64) {
    view
      ..setUint64(32, headerSize, le)
      ..setUint16(54, phentsize, le)
      ..setUint16(56, segments.length, le);
  } else {
    view
      ..setUint32(28, headerSize, le)
      ..setUint16(42, phentsize, le)
      ..setUint16(44, segments.length, le);
  }
  for (var i = 0; i < segments.length; i++) {
    final base = headerSize + i * phentsize;
    final (type, align) = segments[i];
    view.setUint32(base, type, le);
    if (is64) {
      view.setUint64(base + 48, align, le);
    } else {
      view.setUint32(base + 28, align, le);
    }
  }
  return bytes;
}

const _load = 1;
const _dynamic = 2;

void main() {
  group('readElf', () {
    test('a 64-bit library aligned to 16 KB passes', () {
      final report = readElf(
        _elf(
          is64: true,
          segments: [(_load, 0x4000), (_dynamic, 8), (_load, 0x10000)],
        ),
      );
      expect(report.is64, isTrue);
      expect(
        report.loadSegments,
        hasLength(2),
        reason: 'only LOAD segments count',
      );
      expect(report.misaligned, isEmpty);
      expect(report.minAlign, 0x4000);
    });

    test('a 4 KB LOAD segment is misaligned', () {
      final report = readElf(
        _elf(is64: true, segments: [(_load, 0x4000), (_load, 0x1000)]),
      );
      expect(report.misaligned.single.index, 1);
      expect(report.minAlign, 0x1000);
    });

    test('an alignment that is not a power of two is misaligned', () {
      expect(
        readElf(_elf(is64: true, segments: [(_load, 0x5000)])).misaligned,
        hasLength(1),
      );
    });

    test('32-bit headers are read too', () {
      final report = readElf(_elf(is64: false, segments: [(_load, 0x1000)]));
      expect(report.is64, isFalse);
      expect(report.minAlign, 0x1000);
    });

    test('not an ELF file is an error, not a pass', () {
      expect(() => readElf(Uint8List(64)), throwsFormatException);
      final big = _elf(is64: true, segments: [(_load, 0x4000)])..[5] = 2;
      expect(() => readElf(big), throwsFormatException);
    });

    test('program headers past the end of the file are an error', () {
      final bytes = _elf(is64: true, segments: [(_load, 0x4000)]);
      ByteData.sublistView(bytes).setUint16(56, 50, Endian.little);
      expect(() => readElf(bytes), throwsFormatException);
    });
  });

  test('the ABI is read from APK and bundle paths', () {
    expect(abiOf('lib/arm64-v8a/libflutter.so'), 'arm64-v8a');
    expect(abiOf('base/lib/x86_64/libapp.so'), 'x86_64');
    expect(abiOf('libstray.so'), isNull);
  });

  group('checkLibraries', () {
    test(
      'a misaligned 64-bit library fails; a 32-bit one is only reported',
      () {
        final verdicts = checkLibraries({
          'base/lib/arm64-v8a/libgood.so': _elf(
            is64: true,
            segments: [(_load, 0x4000)],
          ),
          'base/lib/arm64-v8a/libbad.so': _elf(
            is64: true,
            segments: [(_load, 0x1000)],
          ),
          'base/lib/armeabi-v7a/libold.so': _elf(
            is64: false,
            segments: [(_load, 0x1000)],
          ),
        });
        final byName = {for (final v in verdicts) v.entry.split('/').last: v};
        expect(byName['libgood.so']!.ok, isTrue);
        expect(byName['libbad.so']!.ok, isFalse);
        expect(byName['libbad.so']!.describe(), contains('MISALIGNED'));
        expect(byName['libold.so']!.enforced, isFalse);
        expect(byName['libold.so']!.ok, isTrue);
        expect(byName['libold.so']!.describe(), contains('32-bit'));
      },
    );
  });

  group('the command, on a real zip', () {
    late Directory dir;
    setUp(
      () => dir = Directory.systemTemp.createTempSync('afterme-16kb-test-'),
    );
    tearDown(() => dir.deleteSync(recursive: true));

    Future<ProcessResult> check(Map<String, Uint8List> libs) async {
      for (final MapEntry(key: path, value: bytes) in libs.entries) {
        File('${dir.path}/tree/$path')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes);
      }
      final zip = await Process.run('zip', [
        '-q',
        '-r',
        '${dir.path}/app.aab',
        '.',
      ], workingDirectory: '${dir.path}/tree');
      expect(zip.exitCode, 0, reason: '${zip.stderr}');
      return Process.run('dart', [
        'run',
        'tool/check_16kb.dart',
        '${dir.path}/app.aab',
      ]);
    }

    test('aligned: exit 0', () async {
      final result = await check({
        'base/lib/arm64-v8a/libflutter.so': _elf(
          is64: true,
          segments: [(_load, 0x10000)],
        ),
      });
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect('${result.stdout}', contains('OK: 1 64-bit native library'));
    });

    test('misaligned: exit 1, loudly, naming the library', () async {
      final result = await check({
        'base/lib/arm64-v8a/libflutter.so': _elf(
          is64: true,
          segments: [(_load, 0x10000)],
        ),
        'base/lib/x86_64/libplugin.so': _elf(
          is64: true,
          segments: [(_load, 0x1000)],
        ),
      });
      expect(result.exitCode, 1);
      expect('${result.stderr}', contains('16 KB PAGE-SIZE CHECK FAILED'));
      expect('${result.stderr}', contains('base/lib/x86_64/libplugin.so'));
    });

    test(
      'no native library at all: exit 2 (a broken build, not a pass)',
      () async {
        File('${dir.path}/tree/base/manifest/AndroidManifest.xml')
          ..createSync(recursive: true)
          ..writeAsStringSync('<manifest/>');
        final result = await check({});
        expect(result.exitCode, 2);
        expect('${result.stderr}', contains('no native library'));
      },
    );
  });
}
