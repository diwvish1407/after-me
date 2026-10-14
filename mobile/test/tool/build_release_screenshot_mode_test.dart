import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `tool/build_release.sh` refuses a release whose configuration turns SCREENSHOT_MODE on
/// (it makes the window capturable). The script is run in a scratch copy of the tree with
/// stub `flutter` and `dart` commands, so a refusal is proved by the script stopping
/// before the build, and the control case by it reaching the stubbed build.
void main() {
  late Directory root;
  late String stubLog;

  const baseConfig = '''
{
  "APP_ENV": "prod",
  "API_BASE_URL": "https://api.afterme.invalid",
  "PUBLIC_BASE_URL": "https://afterme.invalid",
  "SENTRY_DSN": ""%EXTRA%
}
''';

  setUp(() {
    root = Directory.systemTemp.createTempSync('afterme-release-');
    Directory('${root.path}/tool').createSync();
    Directory('${root.path}/config').createSync();
    Directory('${root.path}/bin').createSync();
    File('tool/build_release.sh')
        .copySync('${root.path}/tool/build_release.sh');
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

  ProcessResult run(String config) {
    File('${root.path}/config/prod.json').writeAsStringSync(config);
    return Process.runSync(
      'bash',
      ['${root.path}/tool/build_release.sh', '--apk', '--allow-debug-signing'],
      environment: {'PATH': '${root.path}/bin:${Platform.environment['PATH']}'},
    );
  }

  String stubCalls() =>
      File(stubLog).existsSync() ? File(stubLog).readAsStringSync() : '';

  test('control: a normal prod configuration reaches the build', () {
    final result = run(baseConfig.replaceAll('%EXTRA%', ''));
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(stubCalls(), contains('flutter build apk --flavor prod'));
  });

  test('the key set to false is accepted', () {
    final result = run(
      baseConfig.replaceAll('%EXTRA%', ',\n  "SCREENSHOT_MODE": "false"'),
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(stubCalls(), contains('flutter build'));
  });

  for (final value in ['"true"', 'true', '"TRUE"', '"yes"', '"1"', '""']) {
    test('SCREENSHOT_MODE: $value is refused before anything is built', () {
      final result = run(
        baseConfig.replaceAll('%EXTRA%', ',\n  "SCREENSHOT_MODE": $value'),
      );
      expect(result.exitCode, isNot(0));
      expect('${result.stderr}', contains('SCREENSHOT_MODE'));
      expect(stubCalls(), isEmpty, reason: 'the build must never start');
    });
  }

  test('a second mention is refused too', () {
    final result = run(
      baseConfig.replaceAll(
        '%EXTRA%',
        ',\n  "SCREENSHOT_MODE": "false",\n  "SCREENSHOT_MODE": "true"',
      ),
    );
    expect(result.exitCode, isNot(0));
    expect(stubCalls(), isEmpty);
  });
}
