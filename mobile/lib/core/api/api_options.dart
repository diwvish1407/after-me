import 'package:dio/dio.dart';

/// Keys stored in [RequestOptions.extra] by the API client.
abstract final class ApiExtra {
  /// The request needs an `Idempotency-Key` (API_SPEC.md §1). Set with
  /// [apiOptions] `idempotent: true`.
  static const idempotent = 'afterme.idempotent';

  /// A caller-provided idempotency key (one per user intent, e.g. a pending
  /// check-in restored after process death). When absent a UUID v4 is generated.
  static const idempotencyKey = 'afterme.idempotencyKey';

  /// The request is public: no `Authorization` header and no refresh on 401.
  static const skipAuth = 'afterme.skipAuth';

  /// Internal: the request was already retried once after a token refresh.
  static const authRetried = 'afterme.authRetried';

  /// Internal: the error came from the token refresh made before the request was
  /// sent. The refresh outcome has already been handled, so the auth interceptor
  /// must not react to it a second time.
  static const refreshFailed = 'afterme.refreshFailed';

  /// Internal: how many times the request has been sent (1 = first attempt).
  static const attempt = 'afterme.attempt';
}

/// Header names used by the API client.
abstract final class ApiHeaders {
  static const authorization = 'Authorization';
  static const idempotencyKey = 'Idempotency-Key';
  static const client = 'X-AfterMe-Client';
  static const retryAfter = 'Retry-After';
}

/// Builds [Options] for an API call.
///
/// * [idempotent]: attach an `Idempotency-Key` (required on `POST /checkins` and
///   `POST /incidents/{id}/safe`); such requests may also be retried.
/// * [idempotencyKey]: reuse a key created earlier for the same user intent.
/// * [authenticated]: false for public endpoints (login, register, refresh).
Options apiOptions({
  bool idempotent = false,
  String? idempotencyKey,
  bool authenticated = true,
  Options? base,
}) {
  final options = base ?? Options();
  return options.copyWith(
    extra: <String, dynamic>{
      ...?options.extra,
      if (idempotent || idempotencyKey != null) ApiExtra.idempotent: true,
      ApiExtra.idempotencyKey: ?idempotencyKey,
      if (!authenticated) ApiExtra.skipAuth: true,
    },
  );
}

extension AfterMeRequestOptions on RequestOptions {
  bool get isIdempotent => extra[ApiExtra.idempotent] == true;

  bool get skipsAuth => extra[ApiExtra.skipAuth] == true;

  bool get wasAuthRetried => extra[ApiExtra.authRetried] == true;

  bool get refreshFailed => extra[ApiExtra.refreshFailed] == true;

  /// 1 for the first send, 2 for the first retry, and so on.
  int get attempt => switch (extra[ApiExtra.attempt]) {
    final int value => value,
    _ => 1,
  };

  /// The `Idempotency-Key` header, looked up case-insensitively.
  String? get idempotencyKeyHeader {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == ApiHeaders.idempotencyKey.toLowerCase()) {
        final value = entry.value;
        return value is String ? value : value?.toString();
      }
    }
    return null;
  }
}
