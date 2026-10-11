import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/api/models/token_response.dart';
import 'package:afterme/features/auth/data/auth_repository.dart';
import 'package:afterme/features/auth/data/models/account_models.dart';

/// An in-memory [AuthRepository] for tests: realistic enough to walk through sign-up,
/// sign-in, re-authentication, password and email changes, and scriptable failures.
///
/// Secrets in this file are test fixtures only.
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({
    this.email = 'diwakar@example.com',
    this.password = 'correct horse battery',
    this.displayName = 'Diwakar',
  }) {
    me_ = _buildMe();
  }

  /// The account that exists on the "server".
  String email;
  String password;
  String displayName;
  String timezone = 'Asia/Kolkata';
  String? phone;
  String? country;
  bool verified = true;

  /// The code the fake accepts for sign-up and email change.
  String validCode = '482913';

  late MeResponse me_;

  /// Names of the calls received, in order.
  final List<String> calls = [];

  /// The most recent arguments per call (never contains secrets other than test ones).
  final Map<String, Map<String, Object?>> lastArgs = {};

  /// Failures to throw, per method name, consumed in order.
  final Map<String, List<Object>> _failures = {};

  /// A signup in progress.
  String? pendingEmail;
  String? pendingPassword;
  int codesSent = 0;

  /// The sessions returned by [listSessions].
  List<SessionItem> sessions = [
    SessionItem(
      id: 'session-current',
      kind: 'app',
      createdAt: DateTime.utc(2026, 10, 1, 9),
      lastUsedAt: DateTime.utc(2026, 10, 8, 14),
      current: true,
      device: const SessionDevice(platform: 'android', appVersion: '0.1.0+7'),
    ),
    SessionItem(
      id: 'session-other',
      kind: 'app',
      createdAt: DateTime.utc(2026, 9, 20, 9),
      lastUsedAt: DateTime.utc(2026, 10, 7, 20, 30),
      current: false,
      device: const SessionDevice(platform: 'android', appVersion: '0.1.0+5'),
    ),
  ];

  /// Whether the session was "reauthenticated" (enables email change start).
  bool reauthenticated = false;

  /// The test clock (set by `TestFakes`): the instant of the last successful re-auth,
  /// for the routes that need the password to be **fresh** (the export and the account
  /// deletion accept it for 60 seconds only).
  DateTime Function()? clock;
  DateTime? lastReauthAt;

  /// How many passwords were accepted (a confirmation is spent once, even when the test
  /// clock has not moved between two of them).
  int reauthCount = 0;

  int _reauthFailures = 0;

  MeResponse _buildMe() => MeResponse(
    id: 'user-1',
    email: email,
    tier: 'free',
    status: 'active',
    createdAt: DateTime.utc(2026, 10, 1, 9),
    profile: Profile(
      displayName: displayName,
      timezone: timezone,
      locale: 'en',
      phoneE164: phone,
      countryCode: country,
    ),
  );

  void fail(String method, Object failure, {int times = 1}) {
    _failures.putIfAbsent(method, () => []).addAll(List.filled(times, failure));
  }

  Future<void> _enter(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    calls.add(method);
    lastArgs[method] = args;
    final queue = _failures[method];
    if (queue != null && queue.isNotEmpty) {
      throw queue.removeAt(0);
    }
  }

  static ApiProblem _problem(int status, String code) =>
      ApiProblem(status: status, code: code);

  static UnauthorizedFailure invalidCredentials() => UnauthorizedFailure(
    code: 'invalid_credentials',
    problem: _problem(401, 'invalid_credentials'),
  );

  static ValidationFailure invalidCode() => ValidationFailure(
    code: 'invalid_code',
    problem: _problem(400, 'invalid_code'),
  );

  TokenResponse _tokens() => TokenResponse(
    accessToken: 'access-token',
    accessTokenExpiresAt: DateTime.utc(2026, 10, 8, 10, 15),
    refreshToken: 'refresh-token',
    sessionId: 'session-current',
    deviceId: 'device-1',
    user: TokenUser(id: 'user-1', email: email, tier: 'free'),
  );

  @override
  Future<RegisterStartResult> registerStart({
    required String email,
    required String password,
    required String displayName,
    required String timezone,
    required String locale,
    String? countryCode,
  }) async {
    await _enter('registerStart', {
      'email': email,
      'displayName': displayName,
      'timezone': timezone,
      'locale': locale,
      'countryCode': countryCode,
      'passwordLength': password.length,
    });
    pendingEmail = email;
    pendingPassword = password;
    codesSent++;
    return const RegisterStartResult(
      status: 'code_sent',
      resendAfterSeconds: 60,
    );
  }

  @override
  Future<TokenResponse> registerVerify({
    required String email,
    required String code,
    required String password,
  }) async {
    await _enter('registerVerify', {'email': email, 'code': code});
    if (email != pendingEmail ||
        password != pendingPassword ||
        code != validCode) {
      throw invalidCode();
    }
    this.email = email;
    this.password = password;
    me_ = _buildMe();
    return _tokens();
  }

  @override
  Future<int> registerResend({required String email}) async {
    await _enter('registerResend', {'email': email});
    codesSent++;
    return 60;
  }

  @override
  Future<TokenResponse> login({
    required String email,
    required String password,
  }) async {
    await _enter('login', {'email': email});
    if (email.trim().toLowerCase() != this.email.toLowerCase() ||
        password != this.password) {
      throw invalidCredentials();
    }
    if (!verified) {
      pendingEmail = email;
      pendingPassword = password;
      codesSent++;
      throw ForbiddenFailure(
        code: 'email_unverified',
        problem: _problem(403, 'email_unverified'),
      );
    }
    return _tokens();
  }

  @override
  Future<void> logout() => _enter('logout');

  @override
  Future<void> logoutAll() => _enter('logoutAll');

  @override
  Future<void> forgotPassword({required String email}) =>
      _enter('forgotPassword', {'email': email});

  @override
  Future<void> reauth({required String password}) async {
    await _enter('reauth');
    if (password != this.password) {
      _reauthFailures++;
      if (_reauthFailures >= 5) {
        throw RateLimitedFailure(
          retryAfter: const Duration(minutes: 10),
          problem: _problem(429, 'rate_limited'),
        );
      }
      throw invalidCredentials();
    }
    reauthenticated = true;
    lastReauthAt = clock?.call();
    reauthCount++;
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _enter('changePassword', {'newLength': newPassword.length});
    if (currentPassword != password) {
      throw invalidCredentials();
    }
    password = newPassword;
    sessions = [
      for (final s in sessions)
        if (s.current) s,
    ];
  }

  @override
  Future<void> emailChangeStart({required String newEmail}) async {
    await _enter('emailChangeStart', {'newEmail': newEmail});
    if (!reauthenticated) {
      throw ForbiddenFailure(
        code: 'reauth_required',
        problem: _problem(403, 'reauth_required'),
      );
    }
  }

  @override
  Future<MeResponse> emailChangeVerify({required String code}) async {
    await _enter('emailChangeVerify', {'code': code});
    if (code != validCode) {
      throw invalidCode();
    }
    email = (lastArgs['emailChangeStart']?['newEmail'] ?? email) as String;
    me_ = _buildMe();
    return me_;
  }

  @override
  Future<List<SessionItem>> listSessions() async {
    await _enter('listSessions');
    return List.of(sessions);
  }

  @override
  Future<void> revokeSession(String id) async {
    await _enter('revokeSession', {'id': id});
    sessions = [
      for (final s in sessions)
        if (s.id != id) s,
    ];
  }

  @override
  Future<MeResponse> me() async {
    await _enter('me');
    return me_;
  }

  @override
  Future<MeResponse> patchProfile(ProfilePatch patch) async {
    await _enter('patchProfile', patch.toJson());
    final json = patch.toJson();
    if (json.containsKey('display_name')) {
      displayName = json['display_name']! as String;
    }
    if (json.containsKey('phone_e164')) {
      phone = json['phone_e164'] as String?;
    }
    if (json.containsKey('country_code')) {
      country = json['country_code'] as String?;
    }
    if (json.containsKey('timezone')) {
      timezone = json['timezone']! as String;
    }
    me_ = _buildMe();
    return me_;
  }
}
