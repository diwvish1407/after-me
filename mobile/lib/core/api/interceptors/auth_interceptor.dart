import 'package:dio/dio.dart';

import '../../auth/session_store.dart';
import '../api_options.dart';
import '../failures/app_failure.dart';
import '../models/api_problem.dart';
import '../models/token_response.dart';

/// Called when the server (or a failed refresh) ends the session. Wired to
/// `AuthController.signOut`, which clears storage and moves to `signedOut`.
typedef SessionEndedCallback = Future<void> Function();

/// 401 problem codes the client reacts to (API_SPEC.md §1.1).
abstract final class AuthProblemCodes {
  static const tokenExpired = 'token_expired';
  static const sessionRevoked = 'session_revoked';
  static const unauthenticated = 'unauthenticated';
}

sealed class _RefreshResult {
  const _RefreshResult();
}

final class _Refreshed extends _RefreshResult {
  const _Refreshed(this.accessToken);

  final String accessToken;
}

final class _RefreshFailed extends _RefreshResult {
  const _RefreshFailed(this.error);

  final DioException error;
}

/// Attaches the in-memory access token and keeps the session alive.
///
/// * Every request that has not opted out ([apiOptions] `authenticated: false`)
///   gets `Authorization: Bearer <access token>`. After a cold start there is no
///   access token yet, so one is obtained with the stored refresh token first.
/// * A `401 token_expired` triggers a **single-flight** refresh: concurrent failures
///   share one `POST /v1/auth/refresh`, made on [refreshDio] (which has no auth
///   interceptor). The rotated refresh token is persisted **before** the original
///   request is retried, and each request is retried **at most once**.
/// * A rejected refresh (400/401/403/422), a missing refresh token, or a
///   `401 session_revoked` / `401 unauthenticated` on any authenticated request ends
///   the session ([onSessionEnded]).
/// * A refresh that fails for transient reasons (no connection, timeout, 5xx, 429)
///   does **not** end the session: the original request fails with that error and
///   the next request tries again. Signing someone out because of a network blip
///   would stop them checking in, which is the opposite of fail-safe.
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required this._dio,
    required this._refreshDio,
    required this._sessionStore,
    required this._onSessionEnded,
    this.refreshPath = '/v1/auth/refresh',
  });

  final Dio _dio;
  final Dio _refreshDio;
  final SessionStore _sessionStore;
  final SessionEndedCallback _onSessionEnded;
  final String refreshPath;

  Future<_RefreshResult>? _inFlightRefresh;

  static const _rejectedRefreshStatuses = {400, 401, 403, 422};

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // A retry re-enters here with the same options: forget an earlier refresh error.
    options.extra.remove(ApiExtra.refreshFailed);
    if (options.skipsAuth) {
      handler.next(options);
      return;
    }
    var token = _sessionStore.accessToken;
    if (token == null) {
      switch (await _refreshSingleFlight()) {
        case _Refreshed(:final accessToken):
          token = accessToken;
        case _RefreshFailed(:final error):
          // Let the error interceptors see it (a transient failure of a safe request
          // may be retried by RetryInterceptor). The refresh outcome was already handled
          // in _refresh, so mark the error to keep onError from handling it again.
          options.extra[ApiExtra.refreshFailed] = true;
          handler.reject(error.copyWith(requestOptions: options), true);
          return;
      }
    }
    options.headers[ApiHeaders.authorization] = 'Bearer $token';
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final response = err.response;
    if (options.skipsAuth ||
        options.refreshFailed ||
        response == null ||
        response.statusCode != 401) {
      handler.next(err);
      return;
    }
    final code = ApiProblem.tryParse(response.data, httpStatus: 401)?.code;
    switch (code) {
      case AuthProblemCodes.tokenExpired when !options.wasAuthRetried:
        await _refreshAndRetry(err, handler);
      case AuthProblemCodes.sessionRevoked || AuthProblemCodes.unauthenticated:
        await _endSession();
        handler.next(err);
      default:
        // Other codes, or a second token_expired on an already-retried request:
        // surface the error without refreshing again.
        handler.next(err);
    }
  }

  Future<void> _refreshAndRetry(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final current = _sessionStore.accessToken;
    final String token;
    if (current != null && current != _bearerToken(options)) {
      // Another request refreshed while this one was in flight: reuse its token.
      token = current;
    } else {
      switch (await _refreshSingleFlight()) {
        case _Refreshed(:final accessToken):
          token = accessToken;
        case _RefreshFailed(:final error):
          handler.next(error.copyWith(requestOptions: options));
          return;
      }
    }
    options.extra[ApiExtra.authRetried] = true;
    options.headers[ApiHeaders.authorization] = 'Bearer $token';
    try {
      handler.resolve(await _dio.fetch<dynamic>(options));
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }

  /// Joins the refresh that is already running, or starts one.
  Future<_RefreshResult> _refreshSingleFlight() => _inFlightRefresh ??=
      _refresh().whenComplete(() => _inFlightRefresh = null);

  Future<_RefreshResult> _refresh() async {
    final generation = _sessionStore.generation;
    final requestOptions = RequestOptions(path: refreshPath, method: 'POST');

    final String? refreshToken;
    try {
      refreshToken = await _sessionStore.readRefreshToken();
    } on Object catch (error) {
      return _endSessionWith(requestOptions, cause: error);
    }
    if (refreshToken == null || refreshToken.isEmpty) {
      return _endSessionWith(requestOptions);
    }

    final Response<Object?> response;
    try {
      response = await _refreshDio.post<Object?>(
        refreshPath,
        data: <String, Object?>{'refresh_token': refreshToken},
        options: apiOptions(authenticated: false),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (error.type == DioExceptionType.badResponse &&
          _rejectedRefreshStatuses.contains(status)) {
        await _endSession();
      }
      return _RefreshFailed(error);
    }

    try {
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw const FormatException('Refresh response is not a JSON object');
      }
      final tokens = RefreshResponse.fromJson(data);
      // Persist the rotated refresh token BEFORE anything uses the new access token.
      final saved = await _sessionStore.saveRefreshedTokens(
        tokens,
        expectedGeneration: generation,
      );
      if (!saved) {
        // The session ended while the refresh was in flight; keep it ended.
        return _RefreshFailed(_sessionEndedError(requestOptions));
      }
      return _Refreshed(tokens.accessToken);
    } on Object catch (error) {
      // A 2xx we cannot use, or a token we cannot store: the old refresh token has
      // been consumed, so the session cannot continue.
      return _endSessionWith(requestOptions, cause: error);
    }
  }

  Future<_RefreshResult> _endSessionWith(
    RequestOptions requestOptions, {
    Object? cause,
  }) async {
    await _endSession();
    return _RefreshFailed(_sessionEndedError(requestOptions, cause: cause));
  }

  DioException _sessionEndedError(
    RequestOptions requestOptions, {
    Object? cause,
  }) => DioException(
    requestOptions: requestOptions,
    error: const UnauthorizedFailure(code: AuthProblemCodes.unauthenticated),
    message: cause == null ? 'Session ended' : 'Session ended: $cause',
  );

  Future<void> _endSession() async {
    try {
      await _onSessionEnded();
    } on Object {
      // AuthController.signOut always moves to signedOut, even if storage fails.
    }
  }

  static String? _bearerToken(RequestOptions options) {
    for (final entry in options.headers.entries) {
      if (entry.key.toLowerCase() == ApiHeaders.authorization.toLowerCase()) {
        final value = '${entry.value}';
        return value.startsWith('Bearer ') ? value.substring(7) : value;
      }
    }
    return null;
  }
}
