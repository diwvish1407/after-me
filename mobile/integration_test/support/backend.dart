import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

/// One message the dev backend's console email provider wrote (`GET /test/mail`).
class MailMessage {
  const MailMessage({
    required this.template,
    required this.to,
    required this.subject,
    required this.text,
    required this.writtenAt,
  });

  factory MailMessage.fromJson(Map<String, dynamic> json) => MailMessage(
    template: json['template'] as String? ?? '',
    to: json['to'] as String? ?? '',
    subject: json['subject'] as String? ?? '',
    text: json['text'] as String? ?? '',
    writtenAt: DateTime.parse(json['written_at'] as String),
  );

  final String template;
  final String to;
  final String subject;
  final String text;
  final DateTime writtenAt;
}

/// `GET /test/clock`: the server's time (the database clock plus the test offset).
class ClockState {
  const ClockState({required this.serverTime, required this.offsetSeconds});

  factory ClockState.fromJson(Map<String, dynamic> json) => ClockState(
    serverTime: DateTime.parse(json['server_time'] as String).toUtc(),
    offsetSeconds: json['offset_seconds'] as int,
  );

  final DateTime serverTime;
  final int offsetSeconds;
}

/// A session the tests own, separate from the app's, for reading server state with
/// `GET /v1/home` and friends. The app never sees these tokens.
class ProbeSession {
  ProbeSession({required this.accessToken, required this.refreshToken});

  String accessToken;
  String refreshToken;

  Map<String, String> get headers => {'Authorization': 'Bearer $accessToken'};
}

/// The backend answered something the test did not expect.
class BackendFailure implements Exception {
  BackendFailure(this.message);

  final String message;

  @override
  String toString() => 'BackendFailure: $message';
}

/// Everything the integration tests do to the backend **without** going through the app:
/// the test-support endpoints (`/test/*`, API_SPEC §17), the public web pages a trusted
/// contact uses (`/c/*`, §13.1), and a signed-in probe session for reading what the
/// server holds. It has its own [Dio]; the app's API client is never used here.
///
/// The tests run inside the app's process on the emulator, so [baseUrl] is the same
/// `http://10.0.2.2:8000` the app itself talks to (cleartext is allowed for that host in
/// the dev flavor's network security config).
class Backend {
  Backend({required this.baseUrl, required this._testToken})
    : _dio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 30),
          responseType: ResponseType.plain,
          followRedirects: false,
          // Every status is an answer the tests look at themselves.
          validateStatus: (_) => true,
        ),
      );

  /// From `--dart-define`: `API_BASE_URL` (the same value the app was built with) and
  /// `TEST_TOKEN` (the backend's `AFTERME_TEST_SUPPORT_TOKEN`).
  factory Backend.fromEnvironment() {
    const base = String.fromEnvironment('API_BASE_URL');
    const token = String.fromEnvironment('TEST_TOKEN');
    if (base.isEmpty) {
      throw StateError(
        'API_BASE_URL is not set. Run with --dart-define-from-file=config/dev.json.',
      );
    }
    if (token.isEmpty) {
      throw StateError(
        'TEST_TOKEN is not set. Run with --dart-define=TEST_TOKEN=<the '
        "backend's AFTERME_TEST_SUPPORT_TOKEN> (tool/integration.sh does this).",
      );
    }
    return Backend(baseUrl: base, testToken: token);
  }

  final String baseUrl;
  final String _testToken;
  final Dio _dio;

  static const csrfCookieName = '__Host-afterme_csrf';

  Map<String, String> get _testHeaders => {'X-Test-Token': _testToken};

  Future<Response<String>> _get(
    String path, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
  }) => _dio.get<String>(
    path,
    queryParameters: query,
    options: Options(headers: headers),
  );

  Future<Response<String>> _postJson(
    String path, {
    Object? body,
    Map<String, String>? headers,
  }) => _dio.post<String>(
    path,
    data: body ?? const <String, Object?>{},
    options: Options(headers: headers, contentType: Headers.jsonContentType),
  );

  Future<Response<String>> _postForm(
    String path, {
    required Map<String, String> fields,
    Map<String, String>? headers,
  }) => _dio.post<String>(
    path,
    data: fields,
    options: Options(
      headers: headers,
      contentType: Headers.formUrlEncodedContentType,
    ),
  );

  void _expect(Response<String> response, int status, String what) {
    if (response.statusCode != status) {
      final body = response.data ?? '';
      throw BackendFailure(
        '$what: expected HTTP $status, got ${response.statusCode}. '
        'Body: ${body.length > 400 ? '${body.substring(0, 400)}...' : body}',
      );
    }
  }

  Map<String, dynamic> _json(Response<String> response) =>
      jsonDecode(response.data ?? '{}') as Map<String, dynamic>;

  // --- test clock (API_SPEC §17) ----------------------------------------------------

  Future<ClockState> clock() async {
    final response = await _get('/test/clock', headers: _testHeaders);
    _expect(response, 200, 'GET /test/clock');
    return ClockState.fromJson(_json(response));
  }

  /// Moves the clock of the API **and** the worker forward by [seconds].
  Future<ClockState> advanceSeconds(int seconds) async {
    final response = await _postJson(
      '/test/clock/advance',
      body: {'seconds': seconds < 1 ? 1 : seconds},
      headers: _testHeaders,
    );
    _expect(response, 200, 'POST /test/clock/advance');
    return ClockState.fromJson(_json(response));
  }

  /// Moves the clock to [target] plus [after] (at least one second forward).
  Future<ClockState> advanceTo(
    DateTime target, {
    Duration after = Duration.zero,
  }) async {
    final now = (await clock()).serverTime;
    final seconds = target.add(after).difference(now).inSeconds + 1;
    return advanceSeconds(seconds);
  }

  // --- mail (API_SPEC §17) ------------------------------------------------------------

  /// The newest messages the console provider wrote, newest first.
  Future<List<MailMessage>> mail({
    String? to,
    String? template,
    int limit = 20,
  }) async {
    final response = await _get(
      '/test/mail',
      query: {'to': ?to, 'template': ?template, 'limit': limit},
      headers: _testHeaders,
    );
    _expect(response, 200, 'GET /test/mail');
    return [
      for (final item in _json(response)['messages'] as List<dynamic>)
        MailMessage.fromJson(item as Map<String, dynamic>),
    ];
  }

  /// Polls until at least [count] messages of [template] for [to] exist; fails after
  /// [timeout] with what the mail directory did hold for that address.
  Future<List<MailMessage>> waitForMail({
    required String to,
    required String template,
    int count = 1,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final found = await mail(to: to, template: template);
      if (found.length >= count) {
        return found;
      }
      if (DateTime.now().isAfter(deadline)) {
        final any = await mail(to: to, limit: 10);
        throw BackendFailure(
          'No "$template" mail for $to after ${timeout.inSeconds}s '
          '(want $count, have ${found.length}). Templates sent to that '
          'address: ${any.map((m) => m.template).toList()}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  /// The six-digit sign-up code mailed to [email].
  Future<String> signupCode(String email) async {
    final messages = await waitForMail(to: email, template: 'signup_code');
    final match = RegExp(r'\b(\d{6})\b').firstMatch(messages.first.text);
    if (match == null) {
      throw BackendFailure('The signup_code mail holds no 6-digit code.');
    }
    return match.group(1)!;
  }

  /// The `ci_...` token of the newest invitation mailed to [contactEmail].
  Future<String> invitationToken(String contactEmail) async {
    final messages = await waitForMail(
      to: contactEmail,
      template: 'contact_invitation',
    );
    final match = RegExp(r'/c/open#(ci_[A-Za-z0-9_-]+)')
        .firstMatch(messages.first.text);
    if (match == null) {
      throw BackendFailure('The invitation mail holds no accept link.');
    }
    return match.group(1)!;
  }

  // --- the contact's side: public pages (API_SPEC §13.1) --------------------------

  /// What a trusted contact does in a browser: open the link's landing page (CSRF
  /// cookie and field), exchange the token for the invitation page, press Accept.
  /// Every step is checked, so a change in the pages fails here and not later.
  Future<void> acceptInvitation(String token) async {
    final landing = await _get('/c/open');
    _expect(landing, 200, 'GET /c/open');
    final cookie = _csrfCookie(landing);
    final csrf = _csrfField(landing.data ?? '');

    final invitation = await _postForm(
      '/c/session',
      fields: {'token': token, 'csrf': csrf},
      headers: {'Cookie': '$csrfCookieName=$cookie'},
    );
    _expect(invitation, 200, 'POST /c/session');
    if (!(invitation.data ?? '').contains('would like you to be a trusted')) {
      throw BackendFailure('POST /c/session did not show the invitation page.');
    }
    final pageCsrf = _csrfField(invitation.data ?? '');

    final accepted = await _postForm(
      '/c/invite/accept',
      fields: {'token': token, 'csrf': pageCsrf},
      headers: {'Cookie': '$csrfCookieName=$cookie'},
    );
    _expect(accepted, 200, 'POST /c/invite/accept');
    if (!(accepted.data ?? '').contains('Thank you')) {
      throw BackendFailure('POST /c/invite/accept did not show the thank-you.');
    }
  }

  String _csrfCookie(Response<String> response) {
    final cookies = response.headers['set-cookie'] ?? const <String>[];
    for (final cookie in cookies) {
      if (cookie.startsWith('$csrfCookieName=')) {
        return cookie.substring(csrfCookieName.length + 1).split(';').first;
      }
    }
    throw BackendFailure('GET /c/open set no $csrfCookieName cookie.');
  }

  String _csrfField(String html) {
    final match = RegExp(r'name="csrf" value="([^"]+)"').firstMatch(html);
    if (match == null) {
      throw BackendFailure('The page holds no csrf field.');
    }
    return match.group(1)!;
  }

  // --- a probe session: what the server holds ---------------------------------------

  Map<String, Object?> _loginBody(String email, String password) => {
    'email': email,
    'password': password,
    // The server validates the shape: major.minor.patch with an optional build.
    'device': {
      'platform': 'android',
      'app_version': '0.0.1+1',
      'os_version': 'integration',
      'locale': 'en',
    },
  };

  Future<ProbeSession> login(String email, String password) async {
    final response = await _postJson(
      '/v1/auth/login',
      body: _loginBody(email, password),
    );
    _expect(response, 200, 'POST /v1/auth/login (probe)');
    final body = _json(response);
    return ProbeSession(
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String,
    );
  }

  /// The status code of a login attempt (the probe's own, never the app's).
  Future<int> loginStatus(String email, String password) async {
    final response = await _postJson(
      '/v1/auth/login',
      body: _loginBody(email, password),
    );
    return response.statusCode ?? 0;
  }

  /// A signed-in GET that renews the probe's access token when the test clock outran
  /// its 15 minutes (the server clock moves by days; the token expires with it).
  Future<Map<String, dynamic>> getJson(
    ProbeSession session,
    String path,
  ) async {
    var response = await _get(path, headers: session.headers);
    if (response.statusCode == 401) {
      final refreshed = await _postJson(
        '/v1/auth/refresh',
        body: {'refresh_token': session.refreshToken},
      );
      _expect(refreshed, 200, 'POST /v1/auth/refresh (probe)');
      final body = _json(refreshed);
      session
        ..accessToken = body['access_token'] as String
        ..refreshToken = body['refresh_token'] as String;
      response = await _get(path, headers: session.headers);
    }
    _expect(response, 200, 'GET $path (probe)');
    return _json(response);
  }

  Future<Map<String, dynamic>> home(ProbeSession session) =>
      getJson(session, '/v1/home');

  /// The open incident from the server's own Home aggregate, or null.
  Future<Map<String, dynamic>?> incident(ProbeSession session) async {
    final value = (await home(session))['incident'];
    return value is Map<String, dynamic> ? value : null;
  }

  Future<List<Map<String, dynamic>>> checkins(ProbeSession session) async {
    final body = await getJson(session, '/v1/checkins');
    return [
      for (final item in body['items'] as List<dynamic>)
        item as Map<String, dynamic>,
    ];
  }

  /// A short, secret-free description of the server's state for failure messages.
  Future<String> describe(ProbeSession? session) async {
    final parts = <String>[];
    try {
      final clock = await this.clock();
      parts.add(
        'server_time=${clock.serverTime.toIso8601String()} '
        'offset=${clock.offsetSeconds}s',
      );
    } on Object catch (error) {
      parts.add('clock unreadable: $error');
    }
    if (session != null) {
      try {
        final home = await this.home(session);
        final checkin = home['checkin'] as Map<String, dynamic>?;
        final incident = home['incident'] as Map<String, dynamic>?;
        parts
          ..add(
            'home.checkin: status=${checkin?['status']} '
            'next_due_at=${checkin?['next_due_at']} '
            'last_checkin_at=${checkin?['last_checkin_at']}',
          )
          ..add(
            incident == null
                ? 'home.incident: none'
                : 'home.incident: status=${incident['status']} '
                      'requires=${incident['requires']} '
                      'contacts_messaged=${incident['contacts_messaged']} '
                      'grace_ends_at=${incident['grace_ends_at']}',
          );
      } on Object catch (error) {
        parts.add('home unreadable: $error');
      }
    }
    return parts.join('\n  ');
  }

  void close() => _dio.close(force: true);
}
