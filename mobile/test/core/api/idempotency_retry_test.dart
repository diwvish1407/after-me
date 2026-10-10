import 'dart:async';
import 'dart:io' show HttpException, SocketException;
import 'dart:math';

import 'package:afterme/core/api/api_client.dart';
import 'package:afterme/core/api/api_options.dart';
import 'package:afterme/core/api/client_info.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/failures/failure_mapper.dart';
import 'package:afterme/core/api/interceptors/retry_interceptor.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../helpers/fake_http_adapter.dart';
import '../../helpers/fakes.dart';
import '../../helpers/test_app.dart';

class _Client {
  _Client(FakeHandler handler) : adapter = FakeHttpAdapter(handler) {
    final session = SessionStore(InMemorySecureStore());
    unawaited(session.saveSession(tokenResponse()));
    dio = createApiClient(
      config: devConfig,
      clientInfo: testClientInfo,
      sessionStore: session,
      onSessionEnded: () async {},
      adapter: adapter,
      generateIdempotencyKey: () => 'key-${++keysGenerated}',
      retryDelay: (delay) async => delays.add(delay),
      random: Random(7),
    );
  }

  final FakeHttpAdapter adapter;
  late final Dio dio;
  int keysGenerated = 0;
  final List<Duration> delays = [];
}

/// A [Random] whose doubles are fixed, to test the backoff arithmetic exactly.
class _FixedRandom implements Random {
  _FixedRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  int nextInt(int max) => throw UnimplementedError();
}

Future<AppFailure> _failureOf(Future<Object?> call) async {
  try {
    await call;
  } on DioException catch (error) {
    return mapDioException(error);
  }
  fail('expected the request to fail');
}

void main() {
  group('ClientInfoInterceptor', () {
    test('sends X-AfterMe-Client on every request', () async {
      final c = _Client((_, _) => const FakeReply.json(200));
      await c.dio.get<Object?>('/v1/me');
      await c.dio.post<Object?>(
        '/v1/auth/login',
        options: apiOptions(authenticated: false),
      );
      expect(
        c.adapter.requests.map((r) => r.header('X-AfterMe-Client')),
        everyElement('android/0.1.0+7'),
      );
    });

    test('ClientInfo strips the flavor suffix to the semver core', () {
      final info = ClientInfo.fromPackageInfo(
        PackageInfo(
          appName: 'AfterMe Dev',
          packageName: 'app.afterme.dev',
          version: '1.2.3-dev',
          buildNumber: '45',
        ),
      );
      expect(info.headerValue, 'android/1.2.3+45');
      expect(ClientInfo.semverCore('nonsense'), '0.0.0');
      expect(
        const ClientInfo(version: '1.0.0', buildNumber: '').headerValue,
        'android/1.0.0',
      );
      expect(info, const ClientInfo(version: '1.2.3', buildNumber: '45'));
      expect(
        info.hashCode,
        const ClientInfo(version: '1.2.3', buildNumber: '45').hashCode,
      );
    });
  });

  group('IdempotencyInterceptor', () {
    test('adds no key unless the request is marked idempotent', () async {
      final c = _Client((_, _) => const FakeReply.json(200));
      await c.dio.post<Object?>('/v1/contacts', data: {});
      expect(c.adapter.requests.single.header('Idempotency-Key'), isNull);
      expect(c.keysGenerated, 0);
    });

    test('adds one UUID v4 key to a marked request by default', () async {
      final adapter = FakeHttpAdapter((_, _) => const FakeReply.json(200));
      final session = SessionStore(InMemorySecureStore());
      await session.saveSession(tokenResponse());
      final dio = createApiClient(
        config: devConfig,
        clientInfo: testClientInfo,
        sessionStore: session,
        onSessionEnded: () async {},
        adapter: adapter,
      );
      await dio.post<Object?>(
        '/v1/checkins',
        options: apiOptions(idempotent: true),
      );
      expect(
        adapter.requests.single.header('Idempotency-Key'),
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('the key is generated once and reused on every retry', () async {
      final c = _Client(
        (_, call) => call < 2
            ? const FakeReply.networkError()
            : const FakeReply.json(200, {'ok': true}),
      );

      final response = await c.dio.post<Object?>(
        '/v1/checkins',
        options: apiOptions(idempotent: true),
      );

      expect(response.statusCode, 200);
      expect(c.adapter.requests, hasLength(3));
      expect(
        c.adapter.requests.map((r) => r.header('Idempotency-Key')),
        everyElement('key-1'),
      );
      expect(c.keysGenerated, 1);
    });

    test('the key is stable across 401 token_expired -> refresh -> retry (and a 503)', () async {
      var newTokenAttempts = 0;
      final c = _Client((request, _) {
        if (request.path == '/v1/auth/refresh') {
          return const FakeReply.json(200, {
            'access_token': 'access-2',
            'access_token_expires_at': '2026-10-08T10:30:00Z',
            'refresh_token': 'refresh-2',
          });
        }
        if (request.bearer == 'access-1') {
          return FakeReply.problem(401, 'token_expired');
        }
        // The first attempt with the new token hits a 503, the next succeeds.
        return ++newTokenAttempts == 1
            ? FakeReply.problem(503, 'service_unavailable')
            : const FakeReply.json(200, {'ok': true});
      });
      await Future<void>.delayed(Duration.zero);

      final response = await c.dio.post<Object?>(
        '/v1/checkins',
        options: apiOptions(idempotent: true),
      );

      expect(response.statusCode, 200);
      final sent = c.adapter.requestsTo('/v1/checkins');
      expect(sent.map((r) => r.bearer), ['access-1', 'access-2', 'access-2']);
      expect(
        sent.map((r) => r.header('Idempotency-Key')),
        everyElement('key-1'),
      );
      expect(c.keysGenerated, 1);
      expect(c.adapter.requestsTo('/v1/auth/refresh'), hasLength(1));
    });

    test('a caller-provided key (one per user intent) is used as is', () async {
      final c = _Client((_, _) => const FakeReply.json(200));
      await c.dio.post<Object?>(
        '/v1/checkins',
        options: apiOptions(idempotencyKey: 'pending-checkin-key'),
      );
      expect(
        c.adapter.requests.single.header('Idempotency-Key'),
        'pending-checkin-key',
      );
      expect(c.keysGenerated, 0);
    });

    test('an explicit header is left untouched', () async {
      final c = _Client((_, _) => const FakeReply.json(200));
      await c.dio.post<Object?>(
        '/v1/checkins',
        options: apiOptions(
          idempotent: true,
          base: Options(headers: {'idempotency-key': 'explicit'}),
        ),
      );
      expect(c.adapter.requests.single.header('Idempotency-Key'), 'explicit');
      expect(c.keysGenerated, 0);
    });
  });

  group('RetryInterceptor', () {
    test('retries a GET after network errors and succeeds', () async {
      final c = _Client(
        (_, call) => call < 2
            ? const FakeReply.networkError()
            : const FakeReply.json(200, {'ok': true}),
      );
      final response = await c.dio.get<Object?>('/v1/home');
      expect(response.statusCode, 200);
      expect(c.adapter.requests, hasLength(3));
      expect(c.delays, hasLength(2));
    });

    test('honours max attempts on persistent 503', () async {
      final c = _Client(
        (_, _) => FakeReply.problem(503, 'service_unavailable'),
      );
      final failure = await _failureOf(c.dio.get<Object?>('/v1/home'));
      expect(failure, isA<ServerFailure>());
      expect((failure as ServerFailure).statusCode, 503);
      expect(c.adapter.requests, hasLength(3));
    });

    test('does not retry a POST without an idempotency key', () async {
      final c = _Client((_, _) => const FakeReply.networkError());
      final failure = await _failureOf(
        c.dio.post<Object?>('/v1/contacts', data: {}),
      );
      expect(failure, isA<NetworkFailure>());
      expect(c.adapter.requests, hasLength(1));
    });

    test('retries a keyed POST on 503', () async {
      final c = _Client(
        (_, call) => call == 0
            ? FakeReply.problem(503, 'service_unavailable')
            : const FakeReply.json(200),
      );
      final response = await c.dio.post<Object?>(
        '/v1/checkins',
        options: apiOptions(idempotent: true),
      );
      expect(response.statusCode, 200);
      expect(c.adapter.requests, hasLength(2));
    });

    for (final status in [400, 404, 409, 422, 429]) {
      test('never retries a $status', () async {
        final c = _Client((_, _) => FakeReply.problem(status, 'x'));
        await _failureOf(c.dio.get<Object?>('/v1/home'));
        expect(c.adapter.requests, hasLength(1));
      });
    }

    test('does not retry a 500 (only 503 is retryable)', () async {
      final c = _Client((_, _) => FakeReply.problem(500, 'internal_error'));
      await _failureOf(c.dio.get<Object?>('/v1/home'));
      expect(c.adapter.requests, hasLength(1));
    });

    test('a short Retry-After on 503 extends the backoff', () async {
      final c = _Client(
        (_, call) => call == 0
            ? FakeReply.problem(
                503,
                'service_unavailable',
                headers: {'Retry-After': '3'},
              )
            : const FakeReply.json(200),
      );
      await c.dio.get<Object?>('/v1/home');
      expect(c.delays, [const Duration(seconds: 3)]);
    });

    test('a Retry-After beyond the maximum delay stops retrying', () async {
      final c = _Client(
        (_, _) => FakeReply.problem(
          503,
          'service_unavailable',
          headers: {'Retry-After': '120'},
        ),
      );
      await _failureOf(c.dio.get<Object?>('/v1/home'));
      expect(c.adapter.requests, hasLength(1));
      expect(c.delays, isEmpty);
    });

    test('backoff doubles per attempt and is capped (no jitter reduction)', () {
      final retry = RetryInterceptor(
        dio: Dio(),
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(seconds: 10),
        random: _FixedRandom(1),
      );
      expect(
        [
          for (var attempt = 1; attempt <= 4; attempt++)
            retry.backoffFor(attempt),
        ],
        [
          const Duration(milliseconds: 100),
          const Duration(milliseconds: 200),
          const Duration(milliseconds: 400),
          const Duration(milliseconds: 800),
        ],
      );
      final capped = RetryInterceptor(
        dio: Dio(),
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(milliseconds: 350),
        random: _FixedRandom(1),
      );
      expect(capped.backoffFor(2), const Duration(milliseconds: 200));
      expect(capped.backoffFor(3), const Duration(milliseconds: 350));
      expect(capped.backoffFor(10), const Duration(milliseconds: 350));
    });

    test('jitter scales each delay between 50% and 100%', () {
      RetryInterceptor withJitter(double value) => RetryInterceptor(
        dio: Dio(),
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(milliseconds: 350),
        random: _FixedRandom(value),
      );
      final lowest = withJitter(0);
      expect(lowest.backoffFor(1), const Duration(milliseconds: 50));
      expect(lowest.backoffFor(2), const Duration(milliseconds: 100));
      expect(lowest.backoffFor(3), const Duration(microseconds: 175000));
      expect(lowest.backoffFor(8), const Duration(microseconds: 175000));
      expect(withJitter(0.5).backoffFor(2), const Duration(milliseconds: 150));

      final seeded = RetryInterceptor(
        dio: Dio(),
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(seconds: 10),
        random: Random(11),
      );
      final samples = {for (var i = 0; i < 20; i++) seeded.backoffFor(2)};
      expect(samples.length, greaterThan(1), reason: 'jitter is applied');
      for (final sample in samples) {
        expect(sample.inMicroseconds, inInclusiveRange(100000, 200000));
      }
    });

    test('maxAttempts 1 disables retries', () async {
      final adapter = FakeHttpAdapter((_, _) => const FakeReply.networkError());
      final dio = Dio(BaseOptions(baseUrl: 'http://10.0.2.2:8000'))
        ..httpClientAdapter = adapter;
      dio.interceptors.add(
        RetryInterceptor(dio: dio, maxAttempts: 1, delay: (_) async {}),
      );
      await _failureOf(dio.get<Object?>('/v1/home'));
      expect(adapter.requests, hasLength(1));
    });

    test('classifies retryable requests and errors', () {
      final get = RequestOptions(path: '/x');
      final head = RequestOptions(path: '/x', method: 'HEAD');
      final post = RequestOptions(path: '/x', method: 'POST');
      final keyed = RequestOptions(
        path: '/x',
        method: 'POST',
        headers: {'Idempotency-Key': 'k'},
      );
      expect(RetryInterceptor.isRetryableRequest(get), isTrue);
      expect(RetryInterceptor.isRetryableRequest(head), isTrue);
      expect(RetryInterceptor.isRetryableRequest(post), isFalse);
      expect(RetryInterceptor.isRetryableRequest(keyed), isTrue);

      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.connectionError,
      ]) {
        expect(
          RetryInterceptor.isRetryableError(
            DioException(requestOptions: get, type: type),
          ),
          isTrue,
          reason: '$type',
        );
      }
      for (final cause in <Object>[
        const SocketException('Connection reset by peer'),
        const HttpException('Connection closed while receiving data'),
      ]) {
        final reset = DioException(
          requestOptions: get,
          type: DioExceptionType.unknown,
          error: cause,
        );
        expect(
          RetryInterceptor.isRetryableError(reset),
          isTrue,
          reason: '$cause',
        );
        // Retried exactly when the user is told it was a network problem.
        expect(mapDioException(reset), isA<NetworkFailure>());
      }
      expect(
        RetryInterceptor.isRetryableError(
          DioException(
            requestOptions: get,
            type: DioExceptionType.unknown,
            error: const FormatException('bad'),
          ),
        ),
        isFalse,
      );
      expect(
        RetryInterceptor.isRetryableError(
          DioException(requestOptions: get, type: DioExceptionType.cancel),
        ),
        isFalse,
      );
      expect(
        RetryInterceptor.isRetryableError(
          DioException(
            requestOptions: get,
            type: DioExceptionType.badCertificate,
          ),
        ),
        isFalse,
      );
    });
  });

  group('apiOptions', () {
    test('marks extras', () {
      final options = apiOptions(idempotent: true, authenticated: false);
      expect(options.extra, {
        ApiExtra.idempotent: true,
        ApiExtra.skipAuth: true,
      });
      expect(apiOptions().extra, isEmpty);
      final request = RequestOptions(path: '/x', extra: {ApiExtra.attempt: 2});
      expect(request.attempt, 2);
      expect(RequestOptions(path: '/x').attempt, 1);
    });
  });
}
