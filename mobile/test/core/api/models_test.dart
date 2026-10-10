import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/api/models/token_response.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:json_annotation/json_annotation.dart';

void main() {
  group('TokenResponse', () {
    test('parses the register/verify and login body (API_SPEC §2.2)', () {
      final tokens = TokenResponse.fromJson({
        'access_token': 'eyJ…',
        'access_token_expires_at': '2026-10-08T10:15:00Z',
        'refresh_token': 'rt_9f…',
        'session_id': 's-1',
        'device_id': 'd-1',
        'user': {'id': 'u-1', 'email': 'diwakar@example.com', 'tier': 'free'},
      });
      expect(tokens.accessToken, 'eyJ…');
      expect(tokens.accessTokenExpiresAt, DateTime.utc(2026, 10, 8, 10, 15));
      expect(tokens.accessTokenExpiresAt.isUtc, isTrue);
      expect(tokens.refreshToken, 'rt_9f…');
      expect(tokens.sessionId, 's-1');
      expect(tokens.deviceId, 'd-1');
      expect(
        tokens.user,
        const TokenUser(id: 'u-1', email: 'diwakar@example.com', tier: 'free'),
      );
      expect(TokenResponse.fromJson(tokens.toJson()), tokens);
    });

    test('rejects a body with a missing field, naming the field', () {
      expect(
        () => TokenResponse.fromJson({
          'access_token': 'a',
          'access_token_expires_at': '2026-10-08T10:15:00Z',
          'session_id': 's',
          'device_id': 'd',
          'user': {'id': 'u', 'email': 'e', 'tier': 'free'},
        }),
        throwsA(
          isA<CheckedFromJsonException>().having(
            (e) => e.key,
            'key',
            'refresh_token',
          ),
        ),
      );
    });
  });

  group('RefreshResponse', () {
    test('parses the refresh body (API_SPEC §2.3)', () {
      final tokens = RefreshResponse.fromJson({
        'access_token': 'a2',
        'access_token_expires_at': '2026-10-08T10:30:00Z',
        'refresh_token': 'r2',
      });
      expect(tokens.accessToken, 'a2');
      expect(tokens.refreshToken, 'r2');
      expect(RefreshResponse.fromJson(tokens.toJson()), tokens);
    });
  });

  group('ApiProblem.tryParse', () {
    const body = {
      'type': 'https://afterme.invalid/problems/safe-required',
      'title': "Confirm you're safe",
      'status': 409,
      'code': 'safe_required',
      'detail': 'Your contacts have been notified.',
      'request_id': '01J',
      'incident_id': '6c1e',
      'unknown_member': 'ignored',
    };

    test('parses a decoded map with extensions', () {
      final problem = ApiProblem.tryParse(body, httpStatus: 409)!;
      expect(problem.status, 409);
      expect(problem.code, 'safe_required');
      expect(problem.requestId, '01J');
      expect(problem.incidentId, '6c1e');
      expect(problem.errors, isEmpty);
    });

    test('parses a JSON string', () {
      final problem = ApiProblem.tryParse(
        '{"status":403,"code":"plan_limit_reached","limit":1,"current":1,"resource":"contacts"}',
        httpStatus: 403,
      )!;
      expect(problem.limit, 1);
      expect(problem.current, 1);
      expect(problem.resource, 'contacts');
    });

    test('uses the HTTP status when the body has none', () {
      expect(ApiProblem.tryParse({'code': 'x'}, httpStatus: 418)!.status, 418);
    });

    test('parses list extensions', () {
      final problem = ApiProblem.tryParse({
        'status': 409,
        'code': 'stage_in_use',
        'instruction_ids': ['i1'],
        'requirements': ['no_stages'],
      }, httpStatus: 409)!;
      expect(problem.instructionIds, ['i1']);
      expect(problem.requirements, ['no_stages']);
      expect(ApiProblem.fromJson(problem.toJson()), problem);
    });

    test('returns null for anything that is not a problem document', () {
      expect(ApiProblem.tryParse(null, httpStatus: 500), isNull);
      expect(ApiProblem.tryParse('', httpStatus: 500), isNull);
      expect(ApiProblem.tryParse('<html>', httpStatus: 500), isNull);
      expect(ApiProblem.tryParse('[1,2]', httpStatus: 500), isNull);
      expect(ApiProblem.tryParse(42, httpStatus: 500), isNull);
      expect(
        ApiProblem.tryParse({'errors': 'not a list'}, httpStatus: 422),
        isNull,
      );
    });
  });
}
