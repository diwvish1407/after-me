import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../api_options.dart';

/// Generates idempotency keys. Injectable for deterministic tests.
typedef IdempotencyKeyGenerator = String Function();

String _uuidV4() => const Uuid().v4();

/// Adds an `Idempotency-Key` to requests marked idempotent (see [apiOptions]).
///
/// The key is created **once per request** (or taken from the caller, who creates one
/// per user intent) and stored on the request, so every retry of that request sends
/// the same key and the server can replay the original result (ARCHITECTURE.md §5.3).
class IdempotencyInterceptor extends Interceptor {
  IdempotencyInterceptor({IdempotencyKeyGenerator? generateKey})
    : _generateKey = generateKey ?? _uuidV4;

  final IdempotencyKeyGenerator _generateKey;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.isIdempotent && options.idempotencyKeyHeader == null) {
      final key = switch (options.extra[ApiExtra.idempotencyKey]) {
        final String provided when provided.isNotEmpty => provided,
        _ => _generateKey(),
      };
      options.extra[ApiExtra.idempotencyKey] = key;
      options.headers[ApiHeaders.idempotencyKey] = key;
    }
    handler.next(options);
  }
}
