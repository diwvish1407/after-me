import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// tool/build_release.sh: the version flags of a Play upload (`--build-number`,
/// `--build-name`) and the order of the checks after the build (the merged manifest,
/// then the 16 KB page size). The script runs in a scratch copy of the tree with stub
/// `flutter` and `dart` commands that only record how they were called.
void main() {
  late Directory root;
  late String stubLog;

  setUp(() {
    root = Directory.systemTemp.createTempSync('afterme-release-version-');
    Directory('${root.path}/tool').createSync();
    Directory('${root.path}/config').createSync();
    Directory('${root.path}/bin').createSync();
    File('tool/build_release.sh')
        .copySync('${root.path}/tool/build_release.sh');
    File('${root.path}/config/prod.json').writeAsStringSync('''
{
  "APP_ENV": "prod",
  "API_BASE_URL": "https://api.afterme.invalid",
  "PUBLIC_BASE_URL": "https://afterme.invalid"
}
''');
    stubLog = '${root.path}/stub.log';
    for (final name in ['flutter', 'dart']) {
      final stub = File('${root.path}/bin/$name')
        ..writeAsStringSync(
          '#!/usr/bin/env bash\necho "$name \$*" >> "$stubLog"\n',
        );
      Process.runSync('chmod', ['+x', stub.path]);
    }
  });

  tearDown(() => root.deleteSync(recursive: true));

  ProcessResult run(
    List<String> args, {
    String shell = 'bash',
  }) => Process.runSync(
    shell,
    ['${root.path}/tool/build_release.sh', '--allow-debug-signing', ...args],
    environment: {'PATH': '${root.path}/bin:${Platform.environment['PATH']}'},
  );

  List<String> calls() =>
      File(stubLog).existsSync() ? File(stubLog).readAsLinesSync() : const [];

  test('by default: the App Bundle, the pubspec version, then both checks in '
      'order', () {
    final result = run([]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final log = calls();
    expect(log, hasLength(3));
    expect(
      log[0],
      startsWith('flutter build appbundle --flavor prod --release'),
    );
    expect(log[0], isNot(contains('--build-number')));
    expect(log[0], isNot(contains('--build-name')));
    expect(log[1], 'dart run tool/check_manifest_permissions.dart');
    expect(
      log[2],
      'dart run tool/check_16kb.dart '
      'build/app/outputs/bundle/prodRelease/app-prod-release.aab',
    );
  });

  test(
    '--build-number and --build-name reach flutter build (both spellings)',
    () {
      for (final args in [
        ['--build-number', '42', '--build-name', '1.0.1'],
        ['--build-number=42', '--build-name=1.0.1'],
      ]) {
        File(stubLog).writeAsStringSync('');
        final result = run(args);
        expect(result.exitCode, 0, reason: '$args: ${result.stderr}');
        final build = calls().first;
        expect(build, contains('--build-number=42'), reason: '$args');
        expect(build, contains('--build-name=1.0.1'), reason: '$args');
        expect('${result.stdout}', contains('version: 1.0.1 (build 42)'));
      }
    },
  );

  test('the APK target checks the APK for 16 KB alignment', () {
    final result = run(['--apk', '--build-number', '7']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(calls().first, startsWith('flutter build apk'));
    expect(
      calls().last,
      'dart run tool/check_16kb.dart '
      'build/app/outputs/flutter-apk/app-prod-release.apk',
    );
  });

  for (final bad in ['0', '-3', 'abc', '07', '2100000001', '1.5', '']) {
    test('a build number "$bad" is refused before anything is built', () {
      final result = run(['--build-number=$bad']);
      if (bad.isEmpty) {
        // An empty value means "not given": the pubspec's is used.
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return;
      }
      expect(result.exitCode, isNot(0));
      expect('${result.stderr}', contains('--build-number must be'));
      expect(calls(), isEmpty);
    });
  }

  for (final bad in ['1.0', 'v1.0.0', '1.0.0-beta', 'one']) {
    test('a build name "$bad" is refused', () {
      final result = run(['--build-name', bad]);
      expect(result.exitCode, isNot(0));
      expect('${result.stderr}', contains('--build-name must look like'));
      expect(calls(), isEmpty);
    });
  }

  test('a flag without its value is refused', () {
    final result = run(['--build-number']);
    expect(result.exitCode, isNot(0));
    expect('${result.stderr}', contains('--build-number needs a value'));
  });

  test("macOS's bash 3.2 runs it too (empty arrays under set -u)", () {
    if (!File('/bin/bash').existsSync()) {
      return;
    }
    final result = run([], shell: '/bin/bash');
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(calls().first, startsWith('flutter build appbundle'));
  });

  test('pubspec.yaml is at 1.0.0 with a build number', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      matches(RegExp(r'^version: 1\.0\.0\+[1-9][0-9]*$', multiLine: true)),
    );
  });
}
