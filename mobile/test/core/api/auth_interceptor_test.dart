import 'dart:async';
import 'dart:math';

import 'package:afterme/core/api/api_client.dart';
import 'package:afterme/core/api/api_options.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/failures/failure_mapper.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_http_adapter.dart';
import '../../helpers/fakes.dart';
import '../../helpers/test_app.dart';

const _refreshPath = '/v1/auth/refresh';

/// Builds the real API client over a fake network.
class _Harness {
  _Harness(
    FakeHandler handler, {
    String? accessToken = 'access-1',
    String? refreshToken = 'refresh-1',
  }) : adapter = FakeHttpAdapter(handler) {
    secure = InMemorySecureStore({
      SessionKeys.refreshToken: ?refreshToken,
      SessionKeys.sessionId: 'session-1',
      SessionKeys.deviceId: 'device-1',
    });
    session = SessionStore(secure);
    if (accessToken != null) {
      // Simulate a session that already holds an access token in memory.
      unawaited(
        session.saveSession(
          tokenResponse(access: accessToken, refresh: refreshToken ?? 'r'),
        ),
      );
    }
    dio = createApiClient(
      config: devConfig,
      clientInfo: testClientInfo,
      sessionStore: session,
      onSessionEnded: () async {
        sessionEndedCalls++;
        await session.clear();
      },
      adapter: adapter,
      retryDelay: (_) async {},
      random: Random(1),
    );
  }

  final FakeHttpAdapter adapter;
  late final InMemorySecureStore secure;
  late final SessionStore session;
  late final Dio dio;
  int sessionEndedCalls = 0;

  Future<void> ready() => Future<void>.delayed(Duration.zero);

  int get refreshCalls => adapter.requestsTo(_refreshPath).length;
}

FakeReply _refreshOk({
  String access = 'access-2',
  String refresh = 'refresh-2',
}) => FakeReply.json(200, {
  'access_token': access,
  'access_token_expires_at': '2026-10-08T10:30:00Z',
  'refresh_token': refresh,
});

Future<AppFailure> _failureOf(Future<Object?> call) async {
  try {
    await call;
  } on DioException catch (error) {
    return mapDioException(error);
  }
  fail('expected the request to fail');
}

void main() {
  test('attaches the bearer token, and none to public requests', () async {
    final h = _Harness((request, _) => const FakeReply.json(200, {'ok': true}));
    await h.ready();

    await h.dio.get<Object?>('/v1/me');
    await h.dio.post<Object?>(
      '/v1/auth/login',
      data: {'email': 'x'},
      options: apiOptions(authenticated: false),
    );

    expect(h.adapter.requests[0].bearer, 'access-1');
    expect(h.adapter.requests[1].header('Authorization'), isNull);
  });

  test('5 concurrent 401 token_expired share one in-flight refresh and all '
      'succeed with the new token', () async {
    final releaseRefresh = Completer<void>();
    final h = _Harness((request, _) async {
      if (request.path == _refreshPath) {
        // Held until the test releases it, so every failure has to join it.
        await releaseRefresh.future;
        return _refreshOk();
      }
      if (request.bearer == 'access-1') {
        return FakeReply.problem(401, 'token_expired');
      }
      return FakeReply.json(200, {
        'path': request.path,
        'token': request.bearer,
      });
    });
    await h.ready();

    var finished = false;
    final all = Future.wait([
      for (var i = 0; i < 5; i++)
        h.dio.get<Map<String, dynamic>>('/v1/things/$i'),
    ]);
    unawaited(all.then((_) => finished = true));
    await pumpEventQueue(times: 50);

    // All five have failed and are waiting on the same refresh.
    expect(h.refreshCalls, 1);
    for (var i = 0; i < 5; i++) {
      expect(h.adapter.requestsTo('/v1/things/$i'), hasLength(1));
    }
    expect(finished, isFalse);

    releaseRefresh.complete();
    final responses = await all;

    expect(h.refreshCalls, 1);
    expect(responses.map((r) => r.statusCode), everyElement(200));
    expect(responses.map((r) => r.data!['token']), everyElement('access-2'));
    expect(
      responses.map((r) => r.data!['path']),
      containsAll([for (var i = 0; i < 5; i++) '/v1/things/$i']),
    );
    // Every request was sent exactly twice: once expired, once retried.
    for (var i = 0; i < 5; i++) {
      expect(h.adapter.requestsTo('/v1/things/$i'), hasLength(2));
    }
    expect(h.session.accessToken, 'access-2');
    expect(h.sessionEndedCalls, 0);
  });

  test(
    'the refresh call carries the stored refresh token and no bearer token',
    () async {
      final h = _Harness((request, _) {
        if (request.path == _refreshPath) {
          return _refreshOk();
        }
        return request.bearer == 'access-1'
            ? FakeReply.problem(401, 'token_expired')
            : const FakeReply.json(200);
      });
      await h.ready();

      await h.dio.get<Object?>('/v1/home');

      final refresh = h.adapter.requestsTo(_refreshPath).single;
      expect(refresh.method, 'POST');
      expect(refresh.data, {'refresh_token': 'refresh-1'});
      expect(refresh.header('Authorization'), isNull);
      expect(refresh.header('X-AfterMe-Client'), 'android/0.1.0+7');
    },
  );

  test(
    'the rotated refresh token is persisted before the retry is sent',
    () async {
      late final _Harness h;
      final persistedAtRetry = <String?>[];
      h = _Harness((request, _) {
        if (request.path == _refreshPath) {
          return _refreshOk();
        }
        if (request.bearer == 'access-2') {
          persistedAtRetry.add(h.secure.values[SessionKeys.refreshToken]);
          return const FakeReply.json(200);
        }
        return FakeReply.problem(401, 'token_expired');
      });
      await h.ready();

      await h.dio.get<Object?>('/v1/home');

      expect(persistedAtRetry, ['refresh-2']);
    },
  );

  test('a rejected refresh clears the session and signs out', () async {
    final adapter = FakeHttpAdapter((request, _) {
      if (request.path == _refreshPath) {
        return FakeReply.problem(401, 'session_revoked');
      }
      return FakeReply.problem(401, 'token_expired');
    });
    final secure = InMemorySecureStore({
      SessionKeys.refreshToken: 'refresh-1',
      SessionKeys.sessionId: 'session-1',
      SessionKeys.deviceId: 'device-1',
    });
    final container = ProviderContainer.test(
      overrides: [
        ...testOverrides(secureStore: secure),
        apiHttpAdapterProvider.overrideWithValue(adapter),
      ],
    );
    final auth = container.read(authControllerProvider.notifier);
    await auth.restored;
    expect(container.read(authControllerProvider), AuthStatus.signedIn);
    await container
        .read(sessionStoreProvider)
        .saveSession(tokenResponse(access: 'access-1'));

    final failure = await _failureOf(
      container.read(apiClientProvider).get<Object?>('/v1/home'),
    );

    expect(failure, isA<UnauthorizedFailure>());
    expect((failure as UnauthorizedFailure).code, 'session_revoked');
    expect(adapter.requestsTo(_refreshPath), hasLength(1));
    expect(adapter.requestsTo('/v1/home'), hasLength(1), reason: 'no retry');
    expect(container.read(authControllerProvider), AuthStatus.signedOut);
    expect(container.read(sessionStoreProvider).accessToken, isNull);
    expect(secure.values, isEmpty);
  });

  test('a 401 with another code does not refresh', () async {
    final h = _Harness((request, _) {
      if (request.path == _refreshPath) {
        return _refreshOk();
      }
      return FakeReply.problem(401, 'invalid_credentials');
    });
    await h.ready();

    final failure = await _failureOf(h.dio.get<Object?>('/v1/home'));

    expect(failure, isA<UnauthorizedFailure>());
    expect(h.refreshCalls, 0);
    expect(h.sessionEndedCalls, 0);
    expect(h.adapter.requestsTo('/v1/home'), hasLength(1));
  });

  for (final code in ['session_revoked', 'unauthenticated']) {
    test('a 401 $code ends the session without refreshing', () async {
      final h = _Harness((request, _) {
        if (request.path == _refreshPath) {
          return _refreshOk();
        }
        return FakeReply.problem(401, code);
      });
      await h.ready();

      final failure = await _failureOf(h.dio.get<Object?>('/v1/home'));

      expect((failure as UnauthorizedFailure).code, code);
      expect(h.refreshCalls, 0);
      expect(h.sessionEndedCalls, 1);
      expect(h.secure.values, isEmpty);
    });
  }

  test(
    'a 401 without a problem body neither refreshes nor signs out',
    () async {
      final h = _Harness(
        (request, _) =>
            const FakeReply.raw(401, '<html>nope</html>', 'text/html'),
      );
      await h.ready();

      final failure = await _failureOf(h.dio.get<Object?>('/v1/home'));

      expect(failure, isA<UnauthorizedFailure>());
      expect(h.refreshCalls, 0);
      expect(h.sessionEndedCalls, 0);
    },
  );

  test('a retried request is not refreshed twice', () async {
    final h = _Harness((request, _) {
      if (request.path == _refreshPath) {
        return _refreshOk();
      }
      return FakeReply.problem(401, 'token_expired');
    });
    await h.ready();

    final failure = await _failureOf(h.dio.get<Object?>('/v1/home'));

    expect((failure as UnauthorizedFailure).code, 'token_expired');
    expect(h.refreshCalls, 1);
    expect(h.adapter.requestsTo('/v1/home').map((r) => r.bearer), [
      'access-1',
      'access-2',
    ]);
    expect(h.sessionEndedCalls, 0);
  });

  test('a 401 on a public request never refreshes or signs out', () async {
    final h = _Harness((request, _) => FakeReply.problem(401, 'token_expired'));
    await h.ready();

    await _failureOf(
      h.dio.post<Object?>(
        '/v1/auth/login',
        data: {'email': 'x'},
        options: apiOptions(authenticated: false),
      ),
    );

    expect(h.refreshCalls, 0);
    expect(h.sessionEndedCalls, 0);
  });

  test('a request after another one refreshed reuses the new token', () async {
    // The first request refreshes; a second request that was already in flight
    // with the old token gets a 401 afterwards and must not refresh again.
    final secondSent = Completer<void>();
    final releaseSecond = Completer<void>();
    final h = _Harness((request, _) async {
      if (request.path == _refreshPath) {
        return _refreshOk();
      }
      if (request.path == '/v1/second' && request.bearer == 'access-1') {
        secondSent.complete();
        await releaseSecond.future;
        return FakeReply.problem(401, 'token_expired');
      }
      if (request.bearer == 'access-1') {
        return FakeReply.problem(401, 'token_expired');
      }
      return const FakeReply.json(200);
    });
    await h.ready();

    final second = h.dio.get<Object?>('/v1/second');
    await secondSent.future;
    await h.dio.get<Object?>('/v1/first');
    releaseSecond.complete();
    final response = await second;

    expect(response.statusCode, 200);
    expect(h.refreshCalls, 1);
  });

  group('cold start (no access token in memory)', () {
    test('concurrent requests share one refresh before being sent', () async {
      final h = _Harness((request, _) {
        if (request.path == _refreshPath) {
          return _refreshOk();
        }
        return FakeReply.json(200, {'token': request.bearer});
      }, accessToken: null);

      final responses = await Future.wait([
        for (var i = 0; i < 3; i++) h.dio.get<Map<String, dynamic>>('/v1/x/$i'),
      ]);

      expect(h.refreshCalls, 1);
      expect(responses.map((r) => r.data!['token']), everyElement('access-2'));
      expect(
        h.adapter.requests.where(
          (r) => r.bearer == null && r.path != _refreshPath,
        ),
        isEmpty,
      );
      expect(h.secure.values[SessionKeys.refreshToken], 'refresh-2');
    });

    for (final code in ['session_revoked', 'token_expired']) {
      test('a refresh rejected with 401 $code is handled once: one refresh, '
          'one sign-out', () async {
        final h = _Harness((request, _) {
          if (request.path == _refreshPath) {
            return FakeReply.problem(401, code);
          }
          return const FakeReply.json(200);
        }, accessToken: null);

        final failure = await _failureOf(h.dio.get<Object?>('/v1/home'));

        expect(failure, isA<UnauthorizedFailure>());
        expect(h.refreshCalls, 1);
        expect(h.sessionEndedCalls, 1);
        expect(h.adapter.requestsTo('/v1/home'), isEmpty);
        expect(h.secure.values, isEmpty);
      });
    }

    test(
      'without a refresh token the request is not sent and the session ends',
      () async {
        final h = _Harness(
          (request, _) => const FakeReply.json(200),
          accessToken: null,
          refreshToken: null,
        );

        final failure = await _failureOf(h.dio.get<Object?>('/v1/home'));

        expect((failure as UnauthorizedFailure).code, 'unauthenticated');
        expect(h.adapter.requests, isEmpty);
        expect(h.sessionEndedCalls, 1);
      },
    );
  });

  test('unreadable secure storage during refresh ends the session', () async {
    final adapter = FakeHttpAdapter((_, _) => const FakeReply.json(200));
    final session = SessionStore(ThrowingSecureStore());
    var ended = 0;
    final dio = createApiClient(
      config: devConfig,
      clientInfo: testClientInfo,
      sessionStore: session,
      onSessionEnded: () async {
        ended++;
        throw StateError('storage still broken');
      },
      adapter: adapter,
    );

    final failure = await _failureOf(dio.get<Object?>('/v1/home'));

    expect((failure as UnauthorizedFailure).code, 'unauthenticated');
    expect(ended, 1);
    expect(adapter.requests, isEmpty);
  });

  group('refresh response status decides sign-out or keep', () {
    for (final status in [400, 401, 403, 422]) {
      test(
        'a $status from the refresh ends the session without a retry',
        () async {
          final h = _Harness((request, _) {
            if (request.path == _refreshPath) {
              return FakeReply.problem(
                status,
                status == 401 ? 'session_revoked' : 'rejected',
              );
            }
            return FakeReply.problem(401, 'token_expired');
          });
          await h.ready();

          await _failureOf(h.dio.post<Object?>('/v1/things', data: {}));

          expect(h.refreshCalls, 1);
          expect(h.sessionEndedCalls, 1);
          expect(h.secure.values, isEmpty);
          expect(h.session.accessToken, isNull);
          expect(h.adapter.requestsTo('/v1/things'), hasLength(1));
        },
      );
    }

    test(
      'a 429 from the refresh keeps the session (RateLimitedFailure)',
      () async {
        final h = _Harness((request, _) {
          if (request.path == _refreshPath) {
            return FakeReply.problem(
              429,
              'rate_limited',
              headers: {'Retry-After': '30'},
            );
          }
          return FakeReply.problem(401, 'token_expired');
        });
        await h.ready();

        final failure = await _failureOf(
          h.dio.post<Object?>('/v1/things', data: {}),
        );

        expect(failure, isA<RateLimitedFailure>());
        expect(
          (failure as RateLimitedFailure).retryAfter,
          const Duration(seconds: 30),
        );
        expect(h.sessionEndedCalls, 0);
        expect(h.secure.values[SessionKeys.refreshToken], 'refresh-1');
        expect(h.session.accessToken, 'access-1');
        expect(h.adapter.requestsTo('/v1/things'), hasLength(1));
      },
    );

    test('a 503 from the refresh keeps the session (ServerFailure)', () async {
      final h = _Harness((request, _) {
        if (request.path == _refreshPath) {
          return FakeReply.problem(503, 'service_unavailable');
        }
        return FakeReply.problem(401, 'token_expired');
      });
      await h.ready();

      final failure = await _failureOf(
        h.dio.post<Object?>('/v1/things', data: {}),
      );

      expect(failure, isA<ServerFailure>());
      expect(h.sessionEndedCalls, 0);
      expect(h.secure.values[SessionKeys.refreshToken], 'refresh-1');
      expect(h.adapter.requestsTo('/v1/things'), hasLength(1));
    });
  });

  group('transient refresh failures keep the session', () {
    test(
      'a network error during refresh fails the request with NetworkFailure',
      () async {
        final h = _Harness((request, _) {
          if (request.path == _refreshPath) {
            return const FakeReply.networkError();
          }
          return FakeReply.problem(401, 'token_expired');
        });
        await h.ready();

        // POST without an idempotency key: never retried.
        final failure = await _failureOf(
          h.dio.post<Object?>('/v1/things', data: {}),
        );

        expect(failure, isA<NetworkFailure>());
        expect(h.refreshCalls, 1);
        expect(h.sessionEndedCalls, 0);
        expect(h.secure.values[SessionKeys.refreshToken], 'refresh-1');
      },
    );

    test(
      'a safe request retries the refresh within the attempt limit',
      () async {
        final h = _Harness((request, _) {
          if (request.path == _refreshPath) {
            return const FakeReply.networkError();
          }
          return FakeReply.problem(401, 'token_expired');
        });
        await h.ready();

        final failure = await _failureOf(h.dio.get<Object?>('/v1/home'));

        expect(failure, isA<NetworkFailure>());
        expect(h.refreshCalls, 3);
        expect(h.sessionEndedCalls, 0);
      },
    );

    test('a 5xx during refresh keeps the session', () async {
      final h = _Harness((request, _) {
        if (request.path == _refreshPath) {
          return FakeReply.problem(500, 'internal_error');
        }
        return FakeReply.problem(401, 'token_expired');
      });
      await h.ready();

      final failure = await _failureOf(h.dio.post<Object?>('/v1/things'));

      expect(failure, isA<ServerFailure>());
      expect(h.sessionEndedCalls, 0);
      expect(h.secure.values[SessionKeys.refreshToken], 'refresh-1');
    });
  });

  test('an unusable 2xx refresh response ends the session', () async {
    final h = _Harness((request, _) {
      if (request.path == _refreshPath) {
        return const FakeReply.json(200, {'unexpected': true});
      }
      return FakeReply.problem(401, 'token_expired');
    });
    await h.ready();

    final failure = await _failureOf(h.dio.post<Object?>('/v1/things'));

    expect((failure as UnauthorizedFailure).code, 'unauthenticated');
    expect(h.sessionEndedCalls, 1);
    expect(h.secure.values, isEmpty);
  });

  test(
    'a refresh that completes after sign-out never resurrects the session',
    () async {
      final refreshStarted = Completer<void>();
      final releaseRefresh = Completer<void>();
      final h = _Harness((request, _) async {
        if (request.path == _refreshPath) {
          refreshStarted.complete();
          await releaseRefresh.future;
          return _refreshOk();
        }
        return FakeReply.problem(401, 'token_expired');
      });
      await h.ready();

      final call = _failureOf(h.dio.post<Object?>('/v1/things'));
      await refreshStarted.future;
      await h.session.clear(); // The user signs out meanwhile.
      releaseRefresh.complete();
      final failure = await call;

      expect(failure, isA<UnauthorizedFailure>());
      expect(h.session.accessToken, isNull);
      expect(h.secure.values, isEmpty);
    },
  );
}
