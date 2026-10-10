import 'dart:math';

import 'package:dio/dio.dart';

import '../api_options.dart';
import '../failures/retry_after.dart';
import '../failures/transport_failure.dart';

/// Waits before a retry. Injectable so tests run without real delays.
typedef RetryDelay = Future<void> Function(Duration delay);

Future<void> _wait(Duration delay) => Future<void>.delayed(delay);

/// Retries transient failures of requests that are safe to repeat.
///
/// * Only `GET`/`HEAD` requests, or requests carrying an `Idempotency-Key`, are
///   retried. Anything else could repeat a user action.
/// * Only transport failures (see [isTransportFailure]) and `503` are retried.
///   Other statuses, including every 4xx, are returned immediately.
/// * At most [maxAttempts] sends in total, with exponential backoff and jitter. A
///   `Retry-After` longer than [maxDelay] stops retrying instead of blocking the UI.
class RetryInterceptor extends Interceptor {
  RetryInterceptor({
    required this._dio,
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 8),
    RetryDelay? delay,
    Random? random,
  }) : assert(maxAttempts >= 1, 'maxAttempts must be at least 1'),
       _delay = delay ?? _wait,
       _random = random ?? Random();

  final Dio _dio;
  final RetryDelay _delay;
  final Random _random;
  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;

  static const _safeMethods = {'GET', 'HEAD'};

  /// Whether [options] may be sent more than once.
  static bool isRetryableRequest(RequestOptions options) =>
      _safeMethods.contains(options.method.toUpperCase()) ||
      options.idempotencyKeyHeader != null;

  /// Whether [error] is transient.
  static bool isRetryableError(DioException error) =>
      isTransportFailure(error) ||
      (error.type == DioExceptionType.badResponse &&
          error.response?.statusCode == 503);

  /// Backoff before the retry that follows send number [attempt] (1-based):
  /// `baseDelay * 2^(attempt-1)`, capped at [maxDelay], with equal jitter
  /// (a random value between 50% and 100% of that).
  Duration backoffFor(int attempt) {
    final exponential = baseDelay * pow(2, attempt - 1).toInt();
    final capped = exponential > maxDelay ? maxDelay : exponential;
    final jitter = 0.5 + _random.nextDouble() * 0.5;
    return capped * jitter;
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final attempt = options.attempt;
    if (attempt >= maxAttempts ||
        !isRetryableRequest(options) ||
        !isRetryableError(err)) {
      handler.next(err);
      return;
    }

    var wait = backoffFor(attempt);
    final retryAfter = parseRetryAfter(
      err.response?.headers.value(ApiHeaders.retryAfter),
    );
    if (retryAfter != null) {
      if (retryAfter > maxDelay) {
        handler.next(err);
        return;
      }
      if (retryAfter > wait) {
        wait = retryAfter;
      }
    }

    await _delay(wait);
    options.extra[ApiExtra.attempt] = attempt + 1;
    try {
      // The retry goes through the whole interceptor chain again; the request keeps
      // its Idempotency-Key header, so the key is identical on every attempt.
      final response = await _dio.fetch<dynamic>(options);
      handler.resolve(response);
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }
}
