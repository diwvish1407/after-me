@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:afterme/core/api/api_client.dart';
import 'package:afterme/core/api/client_info.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/api/models/token_response.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/design_system/error_view.dart';
import 'package:afterme/core/device/device_info_source.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/auth/data/auth_repository.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_http_adapter.dart';
import '../helpers/fake_platform.dart';
import '../helpers/fakes.dart';
import '../helpers/test_app.dart';

/// The golden files written by the backend (docs/contracts/phase2) are the single
/// source of truth for what is on the wire. The app must
///   * send request bodies that agree with the golden requests, and
///   * parse the golden responses (including problem+json) into its models.
///
/// The files are in the repository root; `flutter test` runs from `mobile/`.
final Directory _dir = Directory('../docs/contracts/phase2');

Map<String, dynamic> _json(String file) =>
    jsonDecode(File('${_dir.path}/$file').readAsStringSync())
        as Map<String, dynamic>;

class _Wire {
  _Wire(this.repository, this.adapter);

  final DioAuthRepository repository;
  final FakeHttpAdapter adapter;

  RecordedRequest get request => adapter.requests.single;

  Map<String, dynamic> get body => request.data! as Map<String, dynamic>;
}

Future<_Wire> _wire(FakeReply reply) async {
  final adapter = FakeHttpAdapter((_, _) => reply);
  final session = SessionStore(InMemorySecureStore());
  await session.saveSession(tokenResponse());
  final dio = createApiClient(
    config: devConfig,
    clientInfo: const ClientInfoForContract().info,
    sessionStore: session,
    onSessionEnded: () async {},
    adapter: adapter,
    retryDelay: (_) async {},
  );
  return _Wire(
    DioAuthRepository(
      dio: dio,
      clientInfo: const ClientInfoForContract().info,
      deviceInfo: FakeDeviceInfoSource(),
      sessionStore: session,
    ),
    adapter,
  );
}

/// The golden requests use app version 1.0.0+12 on Android 15 with locale en-IN.
class ClientInfoForContract {
  const ClientInfoForContract();

  ClientInfo get info => const ClientInfo(version: '1.0.0', buildNumber: '12');
}

/// Request keys the app does not send because they are optional (the profile country is
/// chosen in Settings, not at sign-up).
const _optionalKeys = {'country_code'};

void _expectAgrees(Map<String, dynamic> sent, Map<String, dynamic> golden) {
  for (final MapEntry(:key, :value) in sent.entries) {
    expect(golden, contains(key), reason: 'app sends unknown field "$key"');
    if (value is Map<String, dynamic>) {
      _expectAgrees(value, golden[key] as Map<String, dynamic>);
    } else {
      expect(value, golden[key], reason: 'field "$key"');
    }
  }
  for (final key in golden.keys.where((k) => !sent.containsKey(k))) {
    expect(_optionalKeys, contains(key), reason: 'app never sends "$key"');
  }
}

void main() {
  late Map<String, dynamic> index;

  setUpAll(() {
    expect(
      _dir.existsSync(),
      isTrue,
      reason: 'docs/contracts/phase2 is written by the backend tests',
    );
    index = _json('index.json');
  });

  test('the contract covers /v1 and declares every endpoint the app uses', () {
    expect(index['contract'], 'afterme-phase2');
    expect(index['base_path'], '/v1');
    final names = {
      for (final e in index['endpoints'] as List) (e as Map)['name'],
    };
    expect(
      names,
      containsAll([
        'register_start',
        'register_resend',
        'register_verify',
        'login',
        'refresh',
        'me',
        'sessions',
        'reauth',
        'password_forgot',
        'email_change_start',
        'email_change_verify',
        'profile_patch',
        'password_change',
        'session_revoke',
        'logout',
        'logout_all',
      ]),
    );
  });

  Map<String, dynamic> endpoint(String name) => (index['endpoints'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((e) => e['name'] == name);

  Future<_Wire> wireFor(String name, {int? statusOverride}) async {
    final e = endpoint(name);
    final response = e['response'] as String?;
    return _wire(
      FakeReply.json(
        statusOverride ?? e['status'] as int,
        response == null ? null : _json(response),
      ),
    );
  }

  void expectRoute(_Wire w, String name, {String? path}) {
    final e = endpoint(name);
    expect(w.request.method, e['method']);
    expect(w.request.path, path ?? e['path']);
  }

  group('requests agree with the golden files', () {
    test('register_start', () async {
      final w = await wireFor('register_start');
      final golden = _json('register_start.request.json');
      final result = await w.repository.registerStart(
        email: golden['email'] as String,
        password: golden['password'] as String,
        displayName: golden['display_name'] as String,
        timezone: golden['timezone'] as String,
        locale: golden['locale'] as String,
      );
      expectRoute(w, 'register_start');
      _expectAgrees(w.body, golden);
      expect(result.status, 'code_sent');
      expect(result.resendAfterSeconds, 60);
      expect(w.request.header('Authorization'), isNull, reason: 'public');
    });

    test('register_start with a country sends country_code', () async {
      final w = await wireFor('register_start');
      final golden = _json('register_start.request.json');
      await w.repository.registerStart(
        email: golden['email'] as String,
        password: golden['password'] as String,
        displayName: golden['display_name'] as String,
        timezone: golden['timezone'] as String,
        locale: golden['locale'] as String,
        countryCode: golden['country_code'] as String,
      );
      expect(w.body, golden);
    });

    test('register_verify sends the signup password and the device', () async {
      final w = await wireFor('register_verify');
      final golden = _json('register_verify.request.json');
      final tokens = await w.repository.registerVerify(
        email: golden['email'] as String,
        code: golden['code'] as String,
        password: golden['password'] as String,
      );
      expectRoute(w, 'register_verify');
      expect(w.body, golden, reason: 'including password and device');
      expect(w.request.header('Authorization'), isNull);
      final expected = _json('register_verify.response.json');
      expect(tokens.accessToken, expected['access_token']);
      expect(tokens.refreshToken, expected['refresh_token']);
      expect(tokens.sessionId, expected['session_id']);
      expect(tokens.deviceId, expected['device_id']);
      expect(tokens.user.email, (expected['user'] as Map)['email']);
      expect(tokens.user.tier, 'free');
      expect(
        tokens.accessTokenExpiresAt,
        DateTime.parse(expected['access_token_expires_at'] as String),
      );
    });

    test('register_resend', () async {
      final w = await wireFor('register_resend');
      final golden = _json('register_resend.request.json');
      final seconds = await w.repository.registerResend(
        email: golden['email'] as String,
      );
      expectRoute(w, 'register_resend');
      expect(w.body, golden);
      expect(seconds, 60);
    });

    test('login (no stored device id yet)', () async {
      final w = await wireFor('login');
      final golden = _json('login.request.json');
      final session = SessionStore(InMemorySecureStore());
      final repo = DioAuthRepository(
        dio: w.repository.dio,
        clientInfo: const ClientInfoForContract().info,
        deviceInfo: FakeDeviceInfoSource(),
        sessionStore: session,
      );
      final tokens = await repo.login(
        email: golden['email'] as String,
        password: golden['password'] as String,
      );
      expectRoute(w, 'login');
      expect(w.body, golden);
      expect(w.body['device'], isNot(contains('id')));
      expect(
        tokens.user.id,
        ((_json('login.response.json'))['user'] as Map)['id'],
      );
    });

    test('login reuses this device id when one is stored', () async {
      final w = await wireFor('login');
      final golden = _json('login.request.json');
      final session = SessionStore(
        InMemorySecureStore({SessionKeys.deviceId: 'device-xyz'}),
      );
      final repo = DioAuthRepository(
        dio: w.repository.dio,
        clientInfo: const ClientInfoForContract().info,
        deviceInfo: FakeDeviceInfoSource(),
        sessionStore: session,
      );
      await repo.login(
        email: golden['email'] as String,
        password: golden['password'] as String,
      );
      expect((w.body['device'] as Map)['id'], 'device-xyz');
    });

    test('password_forgot', () async {
      final w = await wireFor('password_forgot');
      final golden = _json('password_forgot.request.json');
      await w.repository.forgotPassword(email: golden['email'] as String);
      expectRoute(w, 'password_forgot');
      expect(w.body, golden);
      expect(w.request.header('Authorization'), isNull);
    });

    test('reauth', () async {
      final w = await wireFor('reauth');
      final golden = _json('reauth.request.json');
      await w.repository.reauth(password: golden['password'] as String);
      expectRoute(w, 'reauth');
      expect(w.body, golden);
      expect(w.request.bearer, isNotNull);
    });

    test('password_change', () async {
      final w = await wireFor('password_change');
      final golden = _json('password_change.request.json');
      await w.repository.changePassword(
        currentPassword: golden['current_password'] as String,
        newPassword: golden['new_password'] as String,
      );
      expectRoute(w, 'password_change');
      expect(w.body, golden);
    });

    test('email_change_start and verify', () async {
      var w = await wireFor('email_change_start');
      final start = _json('email_change_start.request.json');
      await w.repository.emailChangeStart(
        newEmail: start['new_email'] as String,
      );
      expectRoute(w, 'email_change_start');
      expect(w.body, start);

      w = await wireFor('email_change_verify');
      final verify = _json('email_change_verify.request.json');
      final me = await w.repository.emailChangeVerify(
        code: verify['code'] as String,
      );
      expectRoute(w, 'email_change_verify');
      expect(w.body, verify);
      expect(me.email, 'asha.rao@example.net');
      expect(me.profile.phoneE164, isNull);
    });

    test('profile_patch sends only the fields it was given', () async {
      final w = await wireFor('profile_patch');
      final golden = _json('profile_patch.request.json');
      final me = await w.repository.patchProfile(
        ProfilePatch(
          displayName: golden['display_name'] as String,
          phoneE164: golden['phone_e164'] as String,
          countryCode: golden['country_code'] as String,
          timezone: golden['timezone'] as String,
          locale: golden['locale'] as String,
        ),
      );
      expectRoute(w, 'profile_patch');
      expect(w.body, golden);
      final expected = _json('profile_patch.response.json');
      expect(me.profile.displayName, 'Asha R.');
      expect(me.profile.phoneE164, '+919876543210');
      expect(me.profile.timezone, 'Europe/London');
      expect(me.profile.locale, 'en-IN');
      expect(me.id, expected['id']);
    });

    test(
      'profile_patch can clear the phone and the country with null',
      () async {
        final w = await wireFor('profile_patch');
        await w.repository.patchProfile(
          const ProfilePatch(clearPhone: true, clearCountry: true),
        );
        expect(w.body, {'phone_e164': null, 'country_code': null});
      },
    );

    test(
      'no-body endpoints: logout, logout-all, revoke, me, sessions',
      () async {
        var w = await wireFor('logout');
        await w.repository.logout();
        expectRoute(w, 'logout');

        w = await wireFor('logout_all');
        await w.repository.logoutAll();
        expectRoute(w, 'logout_all');

        w = await wireFor('session_revoke');
        await w.repository.revokeSession(
          '00000000-0000-4000-8000-000000000001',
        );
        expectRoute(
          w,
          'session_revoke',
          path: '/v1/auth/sessions/00000000-0000-4000-8000-000000000001',
        );

        w = await wireFor('me');
        final me = await w.repository.me();
        expectRoute(w, 'me');
        final expected = _json('me.response.json');
        expect(me.id, expected['id']);
        expect(me.tier, 'free');
        expect(me.status, 'active');
        expect(me.profile.displayName, 'Asha Rao');
        expect(me.profile.countryCode, 'IN');
        expect(me.createdAt, DateTime.utc(2026, 10, 8, 9));

        w = await wireFor('sessions');
        final sessions = await w.repository.listSessions();
        expectRoute(w, 'sessions');
        expect(sessions, hasLength(2));
        expect(sessions.first.current, isTrue);
        expect(sessions.first.device?.platform, 'android');
        expect(sessions.first.device?.appVersion, '1.0.0+12');
        expect(sessions.last.current, isFalse);
        expect(
          sessions.first.lastUsedAt.isAfter(sessions.first.createdAt),
          isTrue,
        );
      },
    );

    test('a session id is URL-encoded into the path', () async {
      final w = await wireFor('session_revoke');
      await w.repository.revokeSession('a/b c');
      expect(w.request.path, '/v1/auth/sessions/a%2Fb%20c');
    });
  });

  group('refresh stays compatible with the Phase 1 client', () {
    test('request and response parse', () {
      final response = RefreshResponse.fromJson(_json('refresh.response.json'));
      expect(response.refreshToken, 'rt_example-refresh-token-03');
      expect(_json('refresh.request.json').keys, [
        'refresh_token',
      ], reason: 'the auth interceptor sends exactly this');
    });
  });

  group('problem+json files', () {
    final l10n = AppLocalizationsEn();

    Future<AppFailure> failureOf(
      String file,
      Future<void> Function(_Wire) call,
    ) async {
      final golden = _json(file);
      final w = await _wire(
        FakeReply.raw(
          golden['status'] as int,
          jsonEncode(golden),
          'application/problem+json',
        ),
      );
      try {
        await call(w);
      } on AppFailure catch (failure) {
        return failure;
      }
      fail('expected a failure');
    }

    test('every file parses as an ApiProblem with its code and request id', () {
      for (final problem in index['problems'] as List) {
        final file = (problem as Map)['response'] as String;
        final golden = _json(file);
        final parsed = ApiProblem.tryParse(
          golden,
          httpStatus: golden['status'] as int,
        );
        expect(parsed, isNotNull, reason: file);
        expect(parsed!.code, golden['code']);
        expect(parsed.requestId, golden['request_id']);
        expect(parsed.status, problem['status']);
      }
    });

    test(
      'invalid_code (400) -> ValidationFailure with the calm code message',
      () async {
        final failure = await failureOf(
          'problem_invalid_code.response.json',
          (w) => w.repository.emailChangeVerify(code: '000000'),
        );
        expect(failure, isA<ValidationFailure>());
        expect((failure as ValidationFailure).code, 'invalid_code');
        expect(failureMessage(l10n, failure), l10n.errorInvalidCode);
      },
    );

    test('invalid_credentials (401) is not a session loss', () async {
      final failure = await failureOf(
        'problem_invalid_credentials.response.json',
        (w) => w.repository.reauth(password: 'wrong'),
      );
      expect(failure, isA<UnauthorizedFailure>());
      expect((failure as UnauthorizedFailure).code, 'invalid_credentials');
      expect(failureMessage(l10n, failure), l10n.errorInvalidCredentials);
    });

    test('validation_failed (422) keeps the field errors', () async {
      final failure = await failureOf(
        'problem_validation_failed.response.json',
        (w) => w.repository.patchProfile(const ProfilePatch(phoneE164: 'x')),
      );
      expect(failure, isA<ValidationFailure>());
      final errors = (failure as ValidationFailure).fieldErrors;
      expect(errors.map((e) => e.field), ['phone_e164', 'timezone']);
      expect(errors.map((e) => e.code), ['invalid_phone', 'invalid_timezone']);
    });

    test('reauth_required (403) -> ForbiddenFailure', () async {
      final failure = await failureOf(
        'problem_reauth_required.response.json',
        (w) => w.repository.emailChangeStart(newEmail: 'x@example.com'),
      );
      expect(failure, isA<ForbiddenFailure>());
      expect((failure as ForbiddenFailure).code, 'reauth_required');
      expect(failureMessage(l10n, failure), l10n.errorReauthRequired);
    });

    test('email_unverified (403) from login -> ForbiddenFailure', () async {
      final request = _json('problem_email_unverified.request.json');
      final failure = await failureOf(
        'problem_email_unverified.response.json',
        (w) => w.repository.login(
          email: request['email'] as String,
          password: request['password'] as String,
        ),
      );
      expect(failure, isA<ForbiddenFailure>());
      expect((failure as ForbiddenFailure).code, 'email_unverified');
      expect(
        failure.requestId,
        _json('problem_email_unverified.response.json')['request_id'],
      );
      expect(failureMessage(l10n, failure), l10n.errorEmailUnverified);
    });

    test('rate_limited (429) -> RateLimitedFailure', () async {
      final failure = await failureOf(
        'problem_rate_limited.response.json',
        (w) => w.repository.forgotPassword(email: 'x@example.com'),
      );
      expect(failure, isA<RateLimitedFailure>());
      expect(failure.isTransient, isTrue);
    });

    test(
      'session_revoked and unauthenticated (401) -> UnauthorizedFailure',
      () async {
        for (final file in [
          'problem_session_revoked.response.json',
          'problem_unauthenticated.response.json',
        ]) {
          final failure = await failureOf(file, (w) => w.repository.me());
          expect(failure, isA<UnauthorizedFailure>(), reason: file);
          expect(failureMessage(l10n, failure), l10n.errorSessionExpired);
        }
      },
    );

    test('the server detail text is never what the user reads', () async {
      const sentinel = 'SERVER-ONLY DETAIL TEXT';
      for (final problem in index['problems'] as List) {
        final golden = _json((problem as Map)['response'] as String);
        final parsed = ApiProblem.tryParse({
          ...golden,
          'detail': sentinel,
        }, httpStatus: golden['status'] as int)!;
        final failure = switch (parsed.status) {
          400 => ValidationFailure(code: parsed.code, problem: parsed),
          401 => UnauthorizedFailure(code: parsed.code, problem: parsed),
          403 => ForbiddenFailure(code: parsed.code, problem: parsed),
          422 => ValidationFailure(code: parsed.code, problem: parsed),
          _ => RateLimitedFailure(problem: parsed),
        };
        expect(failureMessage(l10n, failure), isNot(contains(sentinel)));
      }
    });
  });

  test('a malformed success body becomes an UnknownFailure', () async {
    final w = await _wire(const FakeReply.json(200, ['not', 'an', 'object']));
    await expectLater(w.repository.me(), throwsA(isA<UnknownFailure>()));
    final bad = await _wire(const FakeReply.json(200, {'id': 1}));
    await expectLater(bad.repository.me(), throwsA(isA<UnknownFailure>()));
  });

  test('the device descriptor is what the golden files use', () async {
    final d = await DeviceDescriptors.describe(
      const ClientInfoForContract().info,
      FakeDeviceInfoSource(),
    );
    expect(d.toJson(), _json('login.request.json')['device']);
  });
}
