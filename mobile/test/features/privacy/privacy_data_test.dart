import 'dart:convert';
import 'dart:typed_data';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/failures/failure_mapper.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/features/privacy/data/dio_privacy_repository.dart';
import 'package:afterme/features/privacy/data/privacy_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/api_wire.dart';
import '../../helpers/fake_http_adapter.dart';

/// `POST /v1/me/export` and `DELETE /v1/me` over the real API client on a fake network.
void main() {
  group('export', () {
    test('returns the file\'s bytes untouched', () async {
      // Whitespace, key order and non-ASCII text must reach the file as they are.
      const text =
          '{\n  "format_version": 1,\n  "instructions": '
          '[{"title": "Clés du café ☕", "body": "x"}]\n}\n';
      final wire = await apiWire(
        (_, _) => const FakeReply.raw(200, text, 'application/json'),
      );
      final bytes = await DioPrivacyRepository(dio: wire.dio).exportData();
      expect(utf8.decode(bytes), text);
      expect(bytes, isA<Uint8List>());
      expect(wire.request.method, 'POST');
      expect(wire.request.path, '/v1/me/export');
      expect(wire.request.data, isNull);
    });

    test('is never repeated by the client after a lost connection', () async {
      final wire = await apiWire((_, _) => const FakeReply.networkError());
      await expectLater(
        DioPrivacyRepository(dio: wire.dio).exportData(),
        throwsA(isA<NetworkFailure>()),
      );
      expect(wire.adapter.requests, hasLength(1));
    });

    test('is never repeated after a 503 either (it spends the password '
        'confirmation)', () async {
      final wire = await apiWire(
        (_, _) => FakeReply.problem(503, 'service_unavailable'),
      );
      await expectLater(
        DioPrivacyRepository(dio: wire.dio).exportData(),
        throwsA(isA<ServerFailure>()),
      );
      expect(wire.adapter.requests, hasLength(1));
    });

    test('an error body that arrives as bytes is still a problem the app '
        'understands (403 reauth_required, 429 with Retry-After)', () async {
      var wire = await apiWire(
        (_, _) => FakeReply.problem(403, 'reauth_required'),
      );
      Object? caught;
      try {
        await DioPrivacyRepository(dio: wire.dio).exportData();
      } on Object catch (error) {
        caught = error;
      }
      expect(caught, isA<ForbiddenFailure>());
      expect((caught! as ForbiddenFailure).code, 'reauth_required');
      expect((caught as ForbiddenFailure).requestId, 'req-reauth_required');

      wire = await apiWire(
        (_, _) => FakeReply.problem(
          429,
          'rate_limited',
          headers: const {'Retry-After': '1800'},
        ),
      );
      try {
        await DioPrivacyRepository(dio: wire.dio).exportData();
      } on Object catch (error) {
        caught = error;
      }
      expect(caught, isA<RateLimitedFailure>());
      expect(
        (caught as RateLimitedFailure).retryAfter,
        const Duration(minutes: 30),
      );
    });

    test('a page from a proxy is not offered for saving', () async {
      final wire = await apiWire(
        (_, _) => const FakeReply.raw(200, '<html>Sign in</html>', 'text/html'),
      );
      await expectLater(
        DioPrivacyRepository(dio: wire.dio).exportData(),
        throwsA(isA<UnknownFailure>()),
      );
    });

    test('an empty answer is not a file', () async {
      final wire = await apiWire(
        (_, _) => const FakeReply.raw(200, '', 'application/json'),
      );
      await expectLater(
        DioPrivacyRepository(dio: wire.dio).exportData(),
        throwsA(isA<UnknownFailure>()),
      );
    });

    test('a file larger than this phone takes into memory is stopped while it '
        'arrives', () async {
      final big = '{"x":"${'a' * 5000}"}';
      final wire = await apiWire(
        (_, _) => FakeReply.raw(200, big, 'application/json'),
      );
      await expectLater(
        DioPrivacyRepository(dio: wire.dio, maxBytes: 1000).exportData(),
        throwsA(isA<ExportTooLargeException>()),
      );
      // Exactly at the limit is still a file.
      final small = '{"x":"${'a' * 20}"}';
      final fits = await apiWire(
        (_, _) => FakeReply.raw(200, small, 'application/json'),
      );
      expect(
        (await DioPrivacyRepository(
          dio: fits.dio,
          maxBytes: small.length,
        ).exportData()).length,
        small.length,
      );
    });

    test('the limit is 32 MiB', () {
      expect(maxExportBytes, 32 * 1024 * 1024);
    });
  });

  group('deletion', () {
    test('sends {"confirm": "DELETE"} once, with no idempotency key, and '
        'reads the purge date', () async {
      final wire = await apiWire(
        (_, _) => const FakeReply.json(202, {
          'status': 'pending_deletion',
          'purge_after': '2026-11-07T09:02:40Z',
        }),
      );
      final deletion = await DioPrivacyRepository(dio: wire.dio)
          .deleteAccount();
      expect(wire.request.method, 'DELETE');
      expect(wire.request.path, '/v1/me');
      expect(wire.body, {'confirm': 'DELETE'});
      expect(wire.request.header('Idempotency-Key'), isNull);
      expect(deletion.purgeAfter, DateTime.utc(2026, 11, 7, 9, 2, 40));
    });

    test('a 202 whose body cannot be read is still a closed account', () async {
      for (final reply in <FakeReply>[
        const FakeReply.json(202),
        const FakeReply.json(202, {'status': 'pending_deletion'}),
        const FakeReply.json(202, {'purge_after': 'tomorrow-ish'}),
        const FakeReply.raw(202, 'accepted', 'text/plain'),
      ]) {
        final wire = await apiWire((_, _) => reply);
        final deletion = await DioPrivacyRepository(dio: wire.dio)
            .deleteAccount();
        expect(deletion.purgeAfter, isNull);
      }
    });

    test('is not repeated by the client after a lost connection', () async {
      final wire = await apiWire((_, _) => const FakeReply.networkError());
      await expectLater(
        DioPrivacyRepository(dio: wire.dio).deleteAccount(),
        throwsA(isA<NetworkFailure>()),
      );
      expect(wire.adapter.requests, hasLength(1));
    });

    test(
      'maps the refusals: 403 reauth_required, 422 on `confirm`, 429',
      () async {
        var wire = await apiWire(
          (_, _) => FakeReply.problem(403, 'reauth_required'),
        );
        await expectLater(
          DioPrivacyRepository(dio: wire.dio).deleteAccount(),
          throwsA(
            isA<ForbiddenFailure>().having(
              (f) => f.code,
              'code',
              'reauth_required',
            ),
          ),
        );
        wire = await apiWire(
          (_, _) => FakeReply.problem(
            422,
            'validation_failed',
            extra: {
              'errors': [
                {'field': 'confirm', 'code': 'invalid_choice'},
              ],
            },
          ),
        );
        await expectLater(
          DioPrivacyRepository(dio: wire.dio).deleteAccount(),
          throwsA(
            isA<ValidationFailure>().having(
              (f) => f.fieldErrors.single.field,
              'field',
              'confirm',
            ),
          ),
        );
        wire = await apiWire((_, _) => FakeReply.problem(429, 'rate_limited'));
        await expectLater(
          DioPrivacyRepository(dio: wire.dio).deleteAccount(),
          throwsA(isA<RateLimitedFailure>()),
        );
      },
    );
  });

  group('ApiProblem.tryParse reads bytes', () {
    test('a problem document as bytes', () {
      final bytes = utf8.encode(
        jsonEncode({'code': 'reauth_required', 'request_id': 'r1'}),
      );
      final problem = ApiProblem.tryParse(bytes, httpStatus: 403);
      expect(problem!.code, 'reauth_required');
      expect(problem.requestId, 'r1');
      expect(problem.status, 403);
    });

    test('bytes that are not a problem are none, never a crash', () {
      expect(
        ApiProblem.tryParse(utf8.encode('<html>'), httpStatus: 502),
        isNull,
      );
      expect(
        ApiProblem.tryParse(<int>[0xff, 0xfe, 0x00], httpStatus: 500),
        isNull,
      );
      expect(ApiProblem.tryParse(<int>[], httpStatus: 500), isNull);
      expect(
        mapErrorResponse(
          Response<Object?>(
            requestOptions: RequestOptions(),
            statusCode: 502,
            data: utf8.encode('bad gateway'),
          ),
        ),
        isA<ServerFailure>(),
      );
    });
  });
}
