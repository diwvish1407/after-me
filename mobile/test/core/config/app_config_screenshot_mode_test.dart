import 'dart:io';

import 'package:afterme/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// `SCREENSHOT_MODE` makes the window capturable for store screenshots, so it must be
/// impossible to get into a production build: refused by the configuration itself (the
/// same fail-closed path as every other bad value), by the application id, and by the
/// release script (`test/tool/build_release_screenshot_mode_test.dart`).
AppConfig _parse(String env, {String? screenshotMode}) {
  final url = switch (env) {
    'dev' => 'http://10.0.2.2:8000',
    'staging' => 'https://api.staging.afterme.invalid',
    _ => 'https://api.afterme.invalid',
  };
  final publicUrl = switch (env) {
    'dev' => 'http://10.0.2.2:8000',
    'staging' => 'https://staging.afterme.invalid',
    _ => 'https://afterme.invalid',
  };
  return AppConfig.parse(
    appEnv: env,
    apiBaseUrl: url,
    publicBaseUrl: publicUrl,
    screenshotMode: screenshotMode ?? '',
  );
}

void main() {
  group('SCREENSHOT_MODE', () {
    test('is off by default and when it says false, in every environment', () {
      for (final env in ['dev', 'staging', 'prod']) {
        expect(_parse(env).screenshotMode, isFalse, reason: env);
        expect(
          _parse(env, screenshotMode: 'false').screenshotMode,
          isFalse,
          reason: env,
        );
        expect(
          _parse(env, screenshotMode: ' False ').screenshotMode,
          isFalse,
          reason: env,
        );
      }
    });

    test('can be turned on in dev and staging', () {
      expect(_parse('dev', screenshotMode: 'true').screenshotMode, isTrue);
      expect(_parse('staging', screenshotMode: 'true').screenshotMode, isTrue);
      expect(_parse('staging', screenshotMode: 'TRUE').screenshotMode, isTrue);
    });

    test('is refused with APP_ENV prod', () {
      expect(
        () => _parse('prod', screenshotMode: 'true'),
        throwsA(
          isA<AppConfigException>().having(
            (e) => e.message,
            'message',
            contains('SCREENSHOT_MODE'),
          ),
        ),
      );
      expect(
        () => _parse('prod', screenshotMode: 'TRUE'),
        throwsA(isA<AppConfigException>()),
      );
    });

    test('a value that is not true or false is refused, never read as on or '
        'off', () {
      for (final env in ['dev', 'staging', 'prod']) {
        for (final value in ['yes', '1', 'on', 'tru', 'truee', 'falsee']) {
          expect(
            () => _parse(env, screenshotMode: value),
            throwsA(isA<AppConfigException>()),
            reason: '$env / $value',
          );
        }
      }
    });

    test('the production application id refuses it even for a staging '
        'configuration', () {
      final config = _parse('staging', screenshotMode: 'true');
      expect(
        () => config.requirePackage('app.afterme'),
        throwsA(isA<AppConfigException>()),
      );
      // Its own flavor is fine.
      config.requirePackage('app.afterme.staging');
      // And a normal staging build is not affected by the new rule.
      _parse('staging').requirePackage('app.afterme.staging');
    });

    test('is part of the configuration\'s identity', () {
      expect(
        _parse('staging', screenshotMode: 'true') == _parse('staging'),
        isFalse,
      );
    });
  });

  group('the files in config/', () {
    // The tests run from mobile/.
    String read(String name) => File('config/$name.json').readAsStringSync();

    test('dev and staging name the key, set to "false"', () {
      for (final name in ['dev', 'staging']) {
        expect(
          read(name),
          contains('"SCREENSHOT_MODE": "false"'),
          reason: name,
        );
      }
    });

    test('prod does not carry the key at all', () {
      expect(read('prod'), isNot(contains('SCREENSHOT_MODE')));
    });
  });
}
