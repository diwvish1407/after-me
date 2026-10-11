import 'dart:convert';
import 'dart:io';

import 'package:afterme/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppEnv.parse', () {
    test('accepts every environment, case-insensitively', () {
      expect(AppEnv.parse('dev'), AppEnv.dev);
      expect(AppEnv.parse(' Staging '), AppEnv.staging);
      expect(AppEnv.parse('PROD'), AppEnv.prod);
    });

    test('rejects an empty or unknown value', () {
      expect(() => AppEnv.parse(''), throwsA(isA<AppConfigException>()));
      expect(() => AppEnv.parse('test'), throwsA(isA<AppConfigException>()));
    });
  });

  group('AppConfig.parse', () {
    test('dev allows the emulator host over http', () {
      final config = AppConfig.parse(
        appEnv: 'dev',
        apiBaseUrl: 'http://10.0.2.2:8000',
      );
      expect(config.env, AppEnv.dev);
      expect(config.isDev, isTrue);
      expect(config.apiBaseUrl.toString(), 'http://10.0.2.2:8000');
      expect(config.sentryDsn, isNull);
    });

    test('strips a trailing slash and keeps a path prefix', () {
      expect(
        AppConfig.parse(
          appEnv: 'prod',
          apiBaseUrl: 'https://api.afterme.invalid/',
          publicBaseUrl: 'https://afterme.invalid',
        ).apiBaseUrl.toString(),
        'https://api.afterme.invalid',
      );
      expect(
        AppConfig.parse(
          appEnv: 'prod',
          apiBaseUrl: 'https://example.invalid/api/',
          publicBaseUrl: 'https://example.invalid',
        ).apiBaseUrl.toString(),
        'https://example.invalid/api',
      );
    });

    test('staging and prod require https', () {
      for (final env in ['staging', 'prod']) {
        expect(
          () => AppConfig.parse(
            appEnv: env,
            apiBaseUrl: 'http://api.afterme.invalid',
          ),
          throwsA(isA<AppConfigException>()),
          reason: env,
        );
      }
    });

    test('staging and prod reject local addresses even over https', () {
      for (final host in ['localhost', '127.0.0.1', '10.0.2.2']) {
        expect(
          () => AppConfig.parse(appEnv: 'prod', apiBaseUrl: 'https://$host'),
          throwsA(isA<AppConfigException>()),
          reason: host,
        );
      }
    });

    test('rejects missing, relative, non-http and decorated URLs', () {
      for (final url in [
        '',
        '   ',
        '/v1',
        'api.afterme.invalid',
        'ftp://api.afterme.invalid',
        'https://api.afterme.invalid?x=1',
        'https://api.afterme.invalid#frag',
        'https://user:pass@api.afterme.invalid',
        'http://',
      ]) {
        expect(
          () => AppConfig.parse(appEnv: 'dev', apiBaseUrl: url),
          throwsA(isA<AppConfigException>()),
          reason: url,
        );
      }
    });

    test('validates the Sentry DSN', () {
      final config = AppConfig.parse(
        appEnv: 'prod',
        apiBaseUrl: 'https://api.afterme.invalid',
        publicBaseUrl: 'https://afterme.invalid',
        sentryDsn: 'https://key@o1.ingest.sentry.invalid/1',
      );
      expect(config.sentryDsn?.host, 'o1.ingest.sentry.invalid');
      expect(
        AppConfig.parse(
          appEnv: 'dev',
          apiBaseUrl: 'http://10.0.2.2:8000',
          sentryDsn: 'http://key@localhost:9000/1',
        ).sentryDsn,
        isNotNull,
      );
      expect(
        () => AppConfig.parse(
          appEnv: 'prod',
          apiBaseUrl: 'https://api.afterme.invalid',
          publicBaseUrl: 'https://afterme.invalid',
          sentryDsn: 'http://key@sentry.invalid/1',
        ),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => AppConfig.parse(
          appEnv: 'dev',
          apiBaseUrl: 'http://10.0.2.2:8000',
          sentryDsn: 'not a url',
        ),
        throwsA(isA<AppConfigException>()),
      );
    });

    test('PUBLIC_BASE_URL: defaults to the API origin in dev only', () {
      final dev = AppConfig.parse(
        appEnv: 'dev',
        apiBaseUrl: 'http://10.0.2.2:8000',
      );
      expect(dev.publicBaseUrl, dev.apiBaseUrl);
      expect(
        dev.publicUri('/legal/terms').toString(),
        'http://10.0.2.2:8000/legal/terms',
      );
      for (final env in ['staging', 'prod']) {
        expect(
          () => AppConfig.parse(
            appEnv: env,
            apiBaseUrl: 'https://api.afterme.invalid',
          ),
          throwsA(isA<AppConfigException>()),
          reason: '$env needs PUBLIC_BASE_URL',
        );
        expect(
          () => AppConfig.parse(
            appEnv: env,
            apiBaseUrl: 'https://api.afterme.invalid',
            publicBaseUrl: 'http://afterme.invalid',
          ),
          throwsA(isA<AppConfigException>()),
          reason: '$env needs https',
        );
        expect(
          () => AppConfig.parse(
            appEnv: env,
            apiBaseUrl: 'https://api.afterme.invalid',
            publicBaseUrl: 'https://localhost',
          ),
          throwsA(isA<AppConfigException>()),
          reason: '$env rejects local hosts',
        );
      }
      expect(
        AppConfig.parse(
          appEnv: 'prod',
          apiBaseUrl: 'https://api.afterme.invalid',
          publicBaseUrl: 'https://afterme.invalid/',
        ).publicUri('/legal/privacy').toString(),
        'https://afterme.invalid/legal/privacy',
      );
    });

    test('the Play Store link: the app\'s own page unless one is configured, '
        'and always https', () {
      final config = AppConfig.parse(
        appEnv: 'dev',
        apiBaseUrl: 'http://10.0.2.2:8000',
      );
      expect(config.playStoreUrl, AppConfig.defaultPlayStoreUrl);
      expect(
        AppConfig.defaultPlayStoreUrl.toString(),
        'https://play.google.com/store/apps/details?id=app.afterme',
      );
      expect(
        AppConfig.parse(
          appEnv: 'prod',
          apiBaseUrl: 'https://api.afterme.invalid',
          publicBaseUrl: 'https://afterme.invalid',
          playStoreUrl: ' https://play.google.com/store/apps/details?id=app.afterme.other ',
        ).playStoreUrl.queryParameters['id'],
        'app.afterme.other',
      );
      for (final bad in [
        'http://play.google.com/store/apps/details?id=app.afterme',
        'market://details?id=app.afterme',
        'play.google.com/store',
        'https://user:pw@play.google.com/store',
      ]) {
        expect(
          () => AppConfig.parse(
            appEnv: 'dev',
            apiBaseUrl: 'http://10.0.2.2:8000',
            playStoreUrl: bad,
          ),
          throwsA(isA<AppConfigException>()),
          reason: bad,
        );
      }
      // It takes part in equality.
      expect(
        config,
        isNot(
          AppConfig.parse(
            appEnv: 'dev',
            apiBaseUrl: 'http://10.0.2.2:8000',
            playStoreUrl: 'https://play.google.com/store/apps/details?id=x',
          ),
        ),
      );
    });

    test('the Firebase values: all empty means push is not configured, all set '
        'means it is', () {
      final none = AppConfig.parse(
        appEnv: 'dev',
        apiBaseUrl: 'http://10.0.2.2:8000',
      );
      expect(none.firebase, isNull);
      expect(
        AppConfig.parse(
          appEnv: 'dev',
          apiBaseUrl: 'http://10.0.2.2:8000',
          firebaseApiKey: '  ',
          firebaseAppId: '',
        ).firebase,
        isNull,
        reason: 'blank is empty',
      );
      final set = AppConfig.parse(
        appEnv: 'dev',
        apiBaseUrl: 'http://10.0.2.2:8000',
        firebaseApiKey: ' AIzaExample ',
        firebaseAppId: '1:123456789:android:abcdef',
        firebaseMessagingSenderId: '123456789',
        firebaseProjectId: 'afterme-dev',
      );
      expect(set.firebase, isNotNull);
      expect(set.firebase!.apiKey, 'AIzaExample');
      expect(set.firebase!.appId, '1:123456789:android:abcdef');
      expect(set.firebase!.messagingSenderId, '123456789');
      expect(set.firebase!.projectId, 'afterme-dev');
      // The values are identifiers of the deployment, not for logs.
      expect('${set.firebase}', isNot(contains('afterme-dev')));
      expect('$set', isNot(contains('afterme-dev')));
      expect(set, isNot(none));
      expect(set.hashCode, isNot(none.hashCode));
      expect(
        set,
        AppConfig.parse(
          appEnv: 'dev',
          apiBaseUrl: 'http://10.0.2.2:8000',
          firebaseApiKey: 'AIzaExample',
          firebaseAppId: '1:123456789:android:abcdef',
          firebaseMessagingSenderId: '123456789',
          firebaseProjectId: 'afterme-dev',
        ),
      );
    });

    test('some of the Firebase values without the others is refused, naming '
        'what is missing', () {
      const all = {
        'firebaseApiKey': 'k',
        'firebaseAppId': 'a',
        'firebaseMessagingSenderId': 's',
        'firebaseProjectId': 'p',
      };
      for (final omitted in all.keys) {
        final values = {...all}..remove(omitted);
        expect(
          () => AppConfig.parse(
            appEnv: 'dev',
            apiBaseUrl: 'http://10.0.2.2:8000',
            firebaseApiKey: values['firebaseApiKey'] ?? '',
            firebaseAppId: values['firebaseAppId'] ?? '',
            firebaseMessagingSenderId:
                values['firebaseMessagingSenderId'] ?? '',
            firebaseProjectId: values['firebaseProjectId'] ?? '',
          ),
          throwsA(
            isA<AppConfigException>().having(
              (e) => e.message,
              'message',
              contains(switch (omitted) {
                'firebaseApiKey' => 'FIREBASE_API_KEY',
                'firebaseAppId' => 'FIREBASE_APP_ID',
                'firebaseMessagingSenderId' => 'FIREBASE_MESSAGING_SENDER_ID',
                _ => 'FIREBASE_PROJECT_ID',
              }),
            ),
          ),
          reason: omitted,
        );
      }
      expect(
        () => AppConfig.parse(
          appEnv: 'dev',
          apiBaseUrl: 'http://10.0.2.2:8000',
          firebaseApiKey: 'k',
        ),
        throwsA(
          isA<AppConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('FIREBASE_APP_ID'), contains('are not set')),
          ),
        ),
      );
    });

    test('Firebase values with spaces are refused', () {
      expect(
        () => AppConfig.parse(
          appEnv: 'dev',
          apiBaseUrl: 'http://10.0.2.2:8000',
          firebaseApiKey: 'a b',
          firebaseAppId: 'a',
          firebaseMessagingSenderId: 's',
          firebaseProjectId: 'p',
        ),
        throwsA(isA<AppConfigException>()),
      );
    });

    test('fromEnvironment fails fast when no config was compiled in', () {
      // `flutter test` runs without --dart-define-from-file.
      expect(AppConfig.fromEnvironment, throwsA(isA<AppConfigException>()));
    });

    test('value semantics and a log-safe toString', () {
      final a = AppConfig.parse(
        appEnv: 'dev',
        apiBaseUrl: 'http://10.0.2.2:8000',
      );
      final b = AppConfig.parse(
        appEnv: 'dev',
        apiBaseUrl: 'http://10.0.2.2:8000/',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.toString(), contains('dev'));
      expect(
        const AppConfigException('boom').toString(),
        'AppConfigException: boom',
      );
    });
  });

  group('config/*.json', () {
    for (final env in AppEnv.values) {
      test('config/${env.name}.json is valid for its environment', () {
        final file = File('config/${env.name}.json');
        final json =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        expect(
          json.keys,
          containsAll([
            'APP_ENV',
            'API_BASE_URL',
            'PUBLIC_BASE_URL',
            'SENTRY_DSN',
            'PLAY_STORE_URL',
            'FIREBASE_API_KEY',
            'FIREBASE_APP_ID',
            'FIREBASE_MESSAGING_SENDER_ID',
            'FIREBASE_PROJECT_ID',
          ]),
        );
        final config = AppConfig.parse(
          appEnv: json['APP_ENV'] as String,
          apiBaseUrl: json['API_BASE_URL'] as String,
          publicBaseUrl: json['PUBLIC_BASE_URL'] as String,
          sentryDsn: json['SENTRY_DSN'] as String,
          playStoreUrl: json['PLAY_STORE_URL'] as String,
          firebaseApiKey: json['FIREBASE_API_KEY'] as String,
          firebaseAppId: json['FIREBASE_APP_ID'] as String,
          firebaseMessagingSenderId:
              json['FIREBASE_MESSAGING_SENDER_ID'] as String,
          firebaseProjectId: json['FIREBASE_PROJECT_ID'] as String,
        );
        expect(config.env, env);
        // The owner fills these in when the Firebase projects exist (DEPLOYMENT §4);
        // until then the app builds and push says it is not configured.
        if (json['FIREBASE_PROJECT_ID'] == '') {
          expect(config.firebase, isNull);
        }
        expect(config.playStoreUrl.scheme, 'https');
        expect(config.playStoreUrl.host, 'play.google.com');
        if (env != AppEnv.dev) {
          expect(config.apiBaseUrl.scheme, 'https');
          expect(config.publicBaseUrl.scheme, 'https');
          // Placeholder domain until product decision D1.
          expect(config.apiBaseUrl.host, endsWith('.invalid'));
        }
      });
    }
  });
}
