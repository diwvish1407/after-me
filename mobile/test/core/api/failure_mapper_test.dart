import 'dart:convert';
import 'dart:io';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/failures/failure_mapper.dart';
import 'package:afterme/core/api/failures/retry_after.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

final _request = RequestOptions(path: '/v1/x');

DioException _response(
  int status, {
  Object? body,
  Map<String, List<String>> headers = const {},
}) => DioException(
  requestOptions: _request,
  type: DioExceptionType.badResponse,
  response: Response<Object?>(
    requestOptions: _request,
    statusCode: status,
    data: body,
    headers: Headers.fromMap(headers),
  ),
);

Map<String, Object?> _problem(
  int status,
  String code, [
  Map<String, Object?> extra = const {},
]) => {
  'type': 'https://afterme.invalid/problems/$code',
  'title': 'T',
  'status': status,
  'code': code,
  'detail': 'D',
  'request_id': 'req-1',
  ...extra,
};

void main() {
  group('transport errors', () {
    for (final type in [
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.connectionError,
      DioExceptionType.badCertificate,
    ]) {
      test('$type → NetworkFailure', () {
        final failure = mapDioException(
          DioException(requestOptions: _request, type: type),
        );
        expect(failure, isA<NetworkFailure>());
        expect(failure.isTransient, isTrue);
      });
    }

    test('cancel and transform timeout → UnknownFailure', () {
      for (final type in [
        DioExceptionType.cancel,
        DioExceptionType.transformTimeout,
      ]) {
        expect(
          mapDioException(DioException(requestOptions: _request, type: type)),
          isA<UnknownFailure>(),
        );
      }
    });

    test('unknown with a socket or HTTP exception → NetworkFailure', () {
      expect(
        mapDioException(
          DioException(
            requestOptions: _request,
            error: const SocketException('down'),
          ),
        ),
        isA<NetworkFailure>(),
      );
      expect(
        mapDioException(
          DioException(
            requestOptions: _request,
            error: const HttpException('closed'),
          ),
        ),
        isA<NetworkFailure>(),
      );
      expect(
        mapDioException(
          DioException(requestOptions: _request, error: StateError('x')),
        ),
        isA<UnknownFailure>(),
      );
    });

    test('bad response without a response → UnknownFailure', () {
      expect(
        mapDioException(
          DioException(
            requestOptions: _request,
            type: DioExceptionType.badResponse,
          ),
        ),
        isA<UnknownFailure>(),
      );
    });

    test('a ready-made AppFailure inside the exception is returned as is', () {
      const inner = UnauthorizedFailure(code: 'unauthenticated');
      expect(
        mapDioException(DioException(requestOptions: _request, error: inner)),
        same(inner),
      );
    });
  });

  group('HTTP statuses', () {
    test('400 invalid_code → ValidationFailure', () {
      final failure = mapDioException(
        _response(400, body: _problem(400, 'invalid_code')),
      );
      expect(failure, isA<ValidationFailure>());
      expect((failure as ValidationFailure).code, 'invalid_code');
      expect(failure.requestId, 'req-1');
    });

    test('401 → UnauthorizedFailure(code)', () {
      final failure = mapDioException(
        _response(401, body: _problem(401, 'token_expired')),
      );
      expect((failure as UnauthorizedFailure).code, 'token_expired');
    });

    test('403 → ForbiddenFailure(code)', () {
      final failure = mapDioException(
        _response(403, body: _problem(403, 'reauth_required')),
      );
      expect((failure as ForbiddenFailure).code, 'reauth_required');
    });

    test('404 → NotFoundFailure', () {
      expect(
        mapDioException(_response(404, body: _problem(404, 'not_found'))),
        isA<NotFoundFailure>(),
      );
    });

    test('409 → ConflictFailure with problem extensions', () {
      final failure = mapDioException(
        _response(
          409,
          body: _problem(409, 'safe_required', {'incident_id': 'inc-1'}),
        ),
      );
      expect((failure as ConflictFailure).code, 'safe_required');
      expect(failure.problem?.incidentId, 'inc-1');
    });

    test('412 and 428 → ConflictFailure', () {
      expect(
        (mapDioException(
          _response(412, body: _problem(412, 'precondition_failed')),
        ) as ConflictFailure).code,
        'precondition_failed',
      );
      expect(
        mapDioException(
          _response(428, body: _problem(428, 'precondition_required')),
        ),
        isA<ConflictFailure>(),
      );
    });

    test('409 activation_requirements_unmet → the list of what is missing', () {
      final failure = mapDioException(
        _response(
          409,
          body: _problem(409, 'activation_requirements_unmet', {
            'requirements': ['no_contacts', 'no_stages'],
          }),
        ),
      );
      expect(failure, isA<ActivationRequirementsFailure>());
      failure as ActivationRequirementsFailure;
      expect(failure.code, 'activation_requirements_unmet');
      expect(failure.requirements, ['no_contacts', 'no_stages']);
      expect(failure.requestId, 'req-1');

      final bare = mapDioException(
        _response(409, body: _problem(409, 'activation_requirements_unmet')),
      );
      expect((bare as ActivationRequirementsFailure).requirements, isEmpty);
    });

    test('413 → ValidationFailure', () {
      expect(
        (mapDioException(
          _response(413, body: _problem(413, 'payload_too_large')),
        ) as ValidationFailure).code,
        'payload_too_large',
      );
    });

    test('422 → ValidationFailure with field errors', () {
      final failure = mapDioException(
        _response(
          422,
          body: _problem(422, 'validation_failed', {
            'errors': [
              {
                'field': 'stages[1].offset_minutes',
                'code': 'too_small',
                'message': 'Too small',
              },
              {'field': 'email', 'code': 'invalid'},
            ],
          }),
        ),
      );
      final validation = failure as ValidationFailure;
      expect(validation.code, 'validation_failed');
      expect(validation.fieldErrors.map((e) => e.field), [
        'stages[1].offset_minutes',
        'email',
      ]);
      expect(validation.fieldErrors.first.code, 'too_small');
      expect(validation.fieldErrors.last.message, isNull);
    });

    test('426 → UpgradeRequiredFailure', () {
      expect(
        mapDioException(
          _response(426, body: _problem(426, 'upgrade_required')),
        ),
        isA<UpgradeRequiredFailure>(),
      );
    });

    test('429 → RateLimitedFailure with Retry-After seconds', () {
      final failure = mapDioException(
        _response(
          429,
          body: _problem(429, 'rate_limited'),
          headers: {
            'retry-after': ['600'],
          },
        ),
      );
      expect(
        (failure as RateLimitedFailure).retryAfter,
        const Duration(minutes: 10),
      );
      expect(failure.isTransient, isTrue);
    });

    test('429 → RateLimitedFailure with an HTTP-date Retry-After', () {
      final now = DateTime.utc(2026, 10, 14, 14, 30);
      final failure = mapDioException(
        _response(
          429,
          body: _problem(429, 'rate_limited'),
          headers: {
            'retry-after': [
              HttpDate.format(now.add(const Duration(seconds: 90))),
            ],
          },
        ),
        now: () => now,
      );
      expect(
        (failure as RateLimitedFailure).retryAfter,
        const Duration(seconds: 90),
      );
    });

    test('429 without Retry-After → retryAfter null', () {
      final failure = mapDioException(
        _response(429, body: _problem(429, 'rate_limited')),
      );
      expect((failure as RateLimitedFailure).retryAfter, isNull);
    });

    for (final status in [500, 502, 503]) {
      test('$status → ServerFailure', () {
        final failure = mapDioException(_response(status));
        expect((failure as ServerFailure).statusCode, status);
        expect(failure.problem, isNull);
      });
    }

    test('an unexpected status → UnknownFailure', () {
      final failure = mapDioException(_response(418, body: 'teapot'));
      expect((failure as UnknownFailure).statusCode, 418);
    });

    test('a non-problem body still maps by status', () {
      final failure = mapDioException(
        _response(403, body: '<html>Forbidden</html>'),
      );
      expect(failure, isA<ForbiddenFailure>());
      expect(failure.problem, isNull);
      expect(failure.requestId, isNull);
    });
  });

  group('Phase 7 problems (export, deletion, activity)', () {
    test('403 reauth_required of the export or the deletion', () {
      final failure = mapDioException(
        _response(403, body: _problem(403, 'reauth_required')),
      );
      expect(failure, isA<ForbiddenFailure>());
      expect((failure as ForbiddenFailure).code, 'reauth_required');
      expect(failure.isTransient, isFalse);
      expect(failure.requestId, 'req-1');
    });

    test('the same problem arrives as bytes when the request asked for bytes '
        '(the export)', () {
      final bytes = utf8.encode(jsonEncode(_problem(403, 'reauth_required')));
      final failure = mapDioException(_response(403, body: bytes));
      expect(failure, isA<ForbiddenFailure>());
      expect((failure as ForbiddenFailure).code, 'reauth_required');
      expect(failure.requestId, 'req-1');
      expect(
        mapDioException(
          _response(
            426,
            body: utf8.encode(jsonEncode(_problem(426, 'upgrade_required'))),
          ),
        ),
        isA<UpgradeRequiredFailure>(),
      );
    });

    test('429 on the export carries how long to wait', () {
      final failure = mapDioException(
        _response(
          429,
          body: utf8.encode(jsonEncode(_problem(429, 'rate_limited'))),
          headers: {
            'retry-after': ['2400'],
          },
        ),
      );
      expect(
        (failure as RateLimitedFailure).retryAfter,
        const Duration(minutes: 40),
      );
    });

    test('422 on `confirm` of the deletion keeps the field and its code', () {
      final failure = mapDioException(
        _response(
          422,
          body: _problem(422, 'validation_failed', {
            'errors': [
              {
                'field': 'confirm',
                'code': 'invalid_choice',
                'message': "Input should be 'DELETE'",
              },
            ],
          }),
        ),
      );
      final validation = failure as ValidationFailure;
      expect(validation.fieldErrors.single.field, 'confirm');
      expect(validation.fieldErrors.single.code, 'invalid_choice');
    });

    test('422 on `cursor` of the activity feed keeps the field', () {
      final failure = mapDioException(
        _response(
          422,
          body: _problem(422, 'validation_failed', {
            'errors': [
              {'field': 'cursor', 'code': 'invalid'},
            ],
          }),
        ),
      );
      expect((failure as ValidationFailure).fieldErrors.single.field, 'cursor');
    });

    test('401 after a deletion is an UnauthorizedFailure like any other', () {
      final failure = mapDioException(
        _response(401, body: _problem(401, 'session_revoked')),
      );
      expect((failure as UnauthorizedFailure).code, 'session_revoked');
    });
  });

  group('toAppFailure', () {
    test('passes failures through, maps Dio errors, wraps anything else', () {
      const failure = NotFoundFailure();
      expect(toAppFailure(failure), same(failure));
      expect(toAppFailure(_response(404)), isA<NotFoundFailure>());
      final unknown = toAppFailure(const FormatException('bad'));
      expect(unknown, isA<UnknownFailure>());
      expect((unknown as UnknownFailure).cause, isA<FormatException>());
      expect(unknown.toString(), contains('UnknownFailure'));
    });
  });

  group('parseRetryAfter', () {
    final now = DateTime.utc(2026, 10, 14, 12);

    test('delay-seconds', () {
      expect(parseRetryAfter('0'), Duration.zero);
      expect(parseRetryAfter(' 30 '), const Duration(seconds: 30));
      expect(parseRetryAfter('-5'), isNull);
    });

    test('HTTP-date in the future, past and malformed', () {
      expect(
        parseRetryAfter(
          HttpDate.format(now.add(const Duration(minutes: 2))),
          now: now,
        ),
        const Duration(minutes: 2),
      );
      expect(
        parseRetryAfter(
          HttpDate.format(now.subtract(const Duration(minutes: 2))),
          now: now,
        ),
        Duration.zero,
      );
      expect(parseRetryAfter('Someday, maybe'), isNull);
    });

    test('absent or blank', () {
      expect(parseRetryAfter(null), isNull);
      expect(parseRetryAfter('  '), isNull);
    });
  });
}
