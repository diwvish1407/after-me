import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:afterme/core/config/app_config.dart';
import 'package:afterme/core/config/misconfigured_build_app.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// SECURITY.md §11 NETWORK, Phase 9 review M-01: Android's network security config does
/// not govern `dart:io` (the API client's HttpClient), so the rule "no cleartext outside
/// dev" and "a build is the flavor its configuration says" is the app's own: AppConfig,
/// the flavor pairing at start-up and the `#flutter.io.allow_http` zone.
AppConfig _config(String env, {String? api, String? public}) => AppConfig.parse(
  appEnv: env,
  apiBaseUrl:
      api ??
      switch (env) {
        'dev' => 'http://10.0.2.2:8000',
        'staging' => 'https://api.staging.afterme.invalid',
        _ => 'https://api.afterme.invalid',
      },
  publicBaseUrl:
      public ??
      switch (env) {
        'dev' => '',
        'staging' => 'https://staging.afterme.invalid',
        _ => 'https://afterme.invalid',
      },
);

void main() {
  group('isDevLookingHost', () {
    test('recognises loopback, private-network and bare names', () {
      for (final host in [
        'localhost',
        'LOCALHOST',
        'app.localhost',
        '127.0.0.1',
        '127.8.9.10',
        '10.0.2.2',
        '10.1.2.3',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.1.20',
        '169.254.10.10',
        '0.0.0.0',
        '::1',
        '::',
        'fd12:3456::1',
        'fe80::1',
        'backend',
        'laptop.local',
        'db.internal',
        'router.lan',
      ]) {
        expect(AppConfig.isDevLookingHost(host), isTrue, reason: host);
      }
    });

    test('does not mistake a deployed host for one', () {
      for (final host in [
        'api.afterme.invalid',
        'afterme.invalid',
        'api.example.com',
        '172.15.0.1',
        '172.32.0.1',
        '11.0.0.1',
        '192.169.0.1',
        '8.8.8.8',
        '2001:db8::1',
        'localhost.example.com',
      ]) {
        expect(AppConfig.isDevLookingHost(host), isFalse, reason: host);
      }
      expect(AppConfig.isDevLookingHost(''), isFalse);
    });
  });

  group('the base URL and the environment must agree', () {
    test('a non-dev config with http:// fails, for both URLs', () {
      for (final env in ['staging', 'prod']) {
        expect(
          () => _config(env, api: 'http://api.afterme.invalid'),
          throwsA(isA<AppConfigException>()),
          reason: '$env API_BASE_URL',
        );
        expect(
          () => _config(env, public: 'http://afterme.invalid'),
          throwsA(isA<AppConfigException>()),
          reason: '$env PUBLIC_BASE_URL',
        );
        // Not even to the emulator host or loopback, which the zone hook would allow.
        expect(
          () => _config(env, api: 'http://10.0.2.2:8000'),
          throwsA(isA<AppConfigException>()),
        );
        expect(
          () => _config(env, api: 'http://127.0.0.1:8000'),
          throwsA(isA<AppConfigException>()),
        );
      }
    });

    test(
      'staging and prod refuse a development-looking host over https too',
      () {
        for (final env in ['staging', 'prod']) {
          for (final host in [
            'localhost',
            '10.0.2.2',
            '192.168.1.20',
            '172.20.0.5',
            'laptop.local',
            'backend',
          ]) {
            expect(
              () => _config(env, api: 'https://$host'),
              throwsA(isA<AppConfigException>()),
              reason: '$env https://$host',
            );
          }
        }
      },
    );

    test('dev takes a development-looking host only (the reverse)', () {
      for (final api in [
        'http://10.0.2.2:8000',
        'http://localhost:8000',
        'http://127.0.0.1:8000',
        'https://192.168.1.20:8443',
        'https://laptop.local',
      ]) {
        expect(_config('dev', api: api).isDev, isTrue, reason: api);
      }
      for (final api in [
        'https://api.afterme.invalid',
        'https://api.example.com',
        'http://api.example.com',
      ]) {
        expect(
          () => _config('dev', api: api),
          throwsA(isA<AppConfigException>()),
          reason: api,
        );
      }
      expect(
        () => _config('dev', public: 'https://afterme.invalid'),
        throwsA(isA<AppConfigException>()),
        reason: 'the public origin follows the same rule',
      );
    });

    test('dev cleartext is for the hosts of the dev network security config '
        'only', () {
      expect(AppConfig.devCleartextHosts, {
        'localhost',
        '127.0.0.1',
        '10.0.2.2',
        '::1',
      });
      // A private-network address is a dev host, but plain http to it is not allowed
      // (the dev flavor's network security config would not allow it either).
      expect(
        () => _config('dev', api: 'http://192.168.1.20:8000'),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => _config('dev', api: 'http://laptop.local:8000'),
        throwsA(isA<AppConfigException>()),
      );
    });

    test(
      'the dev flavor\'s network security config names exactly those hosts',
      () {
        final xml = File(
          'android/app/src/dev/res/xml/network_security_config.xml',
        ).readAsStringSync();
        final domains = {
          for (final m in RegExp(
            r'<domain[^>]*>([^<]+)</domain>',
          ).allMatches(xml))
            m.group(1)!.trim(),
        };
        expect(domains, AppConfig.devCleartextHosts.difference({'::1'}));
        final main = File(
          'android/app/src/main/res/xml/network_security_config.xml',
        ).readAsStringSync();
        expect(main, contains('cleartextTrafficPermitted="false"'));
        expect(main, isNot(contains('cleartextTrafficPermitted="true"')));
      },
    );
  });

  group('the flavor (application id) must be the one APP_ENV names', () {
    test('envOfPackage reads the flavor suffix, not the base id', () {
      expect(AppConfig.envOfPackage('app.afterme'), AppEnv.prod);
      expect(AppConfig.envOfPackage('app.afterme.dev'), AppEnv.dev);
      expect(AppConfig.envOfPackage('app.afterme.staging'), AppEnv.staging);
      // The base id is provisional (D1): another one must pair the same way.
      expect(AppConfig.envOfPackage('com.example.safety'), AppEnv.prod);
      expect(AppConfig.envOfPackage('com.example.safety.dev'), AppEnv.dev);
      expect(AppConfig.envOfPackage(' APP.AFTERME.DEV '), AppEnv.dev);
    });

    test('every environment passes with its own flavor and no other', () {
      const ids = {
        AppEnv.dev: 'app.afterme.dev',
        AppEnv.staging: 'app.afterme.staging',
        AppEnv.prod: 'app.afterme',
      };
      for (final env in AppEnv.values) {
        final config = _config(env.name);
        for (final entry in ids.entries) {
          if (entry.key == env) {
            expect(() => config.requirePackage(entry.value), returnsNormally);
          } else {
            expect(
              () => config.requirePackage(entry.value),
              throwsA(
                isA<AppConfigException>().having(
                  (e) => e.message,
                  'message',
                  allOf(contains(env.name), contains(entry.value)),
                ),
              ),
              reason: '${env.name} config in ${entry.value}',
            );
          }
        }
      }
    });

    test('an unknown application id fails closed', () {
      expect(
        () => _config('prod').requirePackage(''),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => _config('prod').requirePackage('   '),
        throwsA(isA<AppConfigException>()),
      );
    });

    test('config/<env>.json and the Gradle flavors pair up', () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      for (final env in AppEnv.values) {
        final block = RegExp(
          'create\\("${env.name}"\\)\\s*\\{(.*?)\\n        \\}',
          dotAll: true,
        ).firstMatch(gradle);
        expect(block, isNotNull, reason: 'flavor ${env.name}');
        final suffix = RegExp(r'applicationIdSuffix\s*=\s*"([^"]*)"')
            .firstMatch(block!.group(1)!)
            ?.group(1);
        final id = 'app.afterme${suffix ?? ''}';
        expect(AppConfig.envOfPackage(id), env, reason: id);
        final json = jsonDecode(
          File('config/${env.name}.json').readAsStringSync(),
        ) as Map<String, dynamic>;
        expect(AppEnv.parse(json['APP_ENV'] as String), env);
        expect(
          () => _config(env.name).requirePackage(id),
          returnsNormally,
          reason: id,
        );
      }
    });
  });

  group('the zone main() runs the app in', () {
    test('allows plain http in dev and in no other environment', () {
      expect(AppConfig.allowHttpZoneKey, #flutter.io.allow_http);
      expect(_config('dev').ioZoneValues, {#flutter.io.allow_http: true});
      expect(_config('staging').ioZoneValues, {#flutter.io.allow_http: false});
      expect(_config('prod').ioZoneValues, {#flutter.io.allow_http: false});
    });

    test('is what the engine\'s connection hook reads', () async {
      // dart:ui's hook reads `Zone.current[#flutter.io.allow_http]` at the moment a
      // connection is opened, so what counts is the zone of the code that makes the
      // request, including after an await and in a timer.
      final seen = <Object?>[];
      final done = Completer<void>();
      runZoned(() {
        seen.add(Zone.current[#flutter.io.allow_http]);
        Timer(Duration.zero, () async {
          seen.add(Zone.current[#flutter.io.allow_http]);
          await Future<void>.delayed(Duration.zero);
          seen.add(Zone.current[#flutter.io.allow_http]);
          done.complete();
        });
      }, zoneValues: _config('prod').ioZoneValues);
      await done.future;
      expect(seen, [false, false, false]);
      expect(Zone.current[#flutter.io.allow_http], isNull);
    });
  });

  group('MisconfiguredBuildApp', () {
    testWidgets('says plainly that this build was stopped', (tester) async {
      await tester.pumpWidget(
        const MisconfiguredBuildApp(
          message:
              'APP_ENV is dev but this is the prod flavor ("app.afterme").',
        ),
      );
      expect(
        find.text('This build of AfterMe is not set up correctly'),
        findsOneWidget,
      );
      expect(
        find.textContaining('has not contacted any server'),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('misconfigured-detail'))).data,
        contains('APP_ENV is dev'),
      );
    });
  });
}
