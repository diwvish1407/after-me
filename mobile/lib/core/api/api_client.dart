import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../auth/session_ended_notice.dart';
import '../auth/session_store.dart';
import '../config/app_config.dart';
import 'client_info.dart';
import 'interceptors/auth_interceptor.dart';
import 'interceptors/client_info_interceptor.dart';
import 'interceptors/idempotency_interceptor.dart';
import 'interceptors/retry_interceptor.dart';

/// Timeouts for API calls. Generous enough for slow mobile networks, short enough
/// that a check-in quickly falls back to "Not received yet — retrying".
abstract final class ApiTimeouts {
  static const connect = Duration(seconds: 10);
  static const send = Duration(seconds: 15);
  static const receive = Duration(seconds: 20);
}

/// A bare Dio for the API: base URL, JSON in and out, timeouts. No interceptors.
Dio createBaseDio(AppConfig config, {HttpClientAdapter? adapter}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: config.apiBaseUrl.toString(),
      connectTimeout: ApiTimeouts.connect,
      sendTimeout: ApiTimeouts.send,
      receiveTimeout: ApiTimeouts.receive,
      contentType: Headers.jsonContentType,
      responseType: ResponseType.json,
      headers: <String, Object>{
        Headers.acceptHeader: 'application/json, application/problem+json',
      },
    ),
  );
  if (adapter != null) {
    dio.httpClientAdapter = adapter;
  }
  return dio;
}

/// Builds the API client used by every feature (ARCHITECTURE.md §5.3).
///
/// Interceptor order (requests run top to bottom, errors in the same order):
/// 1. [ClientInfoInterceptor]: `X-AfterMe-Client`.
/// 2. [IdempotencyInterceptor]: one `Idempotency-Key` per request, kept on retries.
/// 3. [AuthInterceptor]: bearer token, single-flight refresh on `token_expired`.
/// 4. [RetryInterceptor]: backoff retries of safe/keyed requests.
///
/// The token refresh uses a separate Dio with only the client-info interceptor, so a
/// refresh can never recurse into the auth interceptor.
Dio createApiClient({
  required AppConfig config,
  required ClientInfo clientInfo,
  required SessionStore sessionStore,
  required SessionEndedCallback onSessionEnded,
  HttpClientAdapter? adapter,
  IdempotencyKeyGenerator? generateIdempotencyKey,
  RetryDelay? retryDelay,
  Random? random,
}) {
  final refreshDio = createBaseDio(config, adapter: adapter)
    ..interceptors.add(ClientInfoInterceptor(clientInfo));
  final dio = createBaseDio(config, adapter: adapter);
  dio.interceptors.addAll([
    ClientInfoInterceptor(clientInfo),
    IdempotencyInterceptor(generateKey: generateIdempotencyKey),
    AuthInterceptor(
      dio: dio,
      refreshDio: refreshDio,
      sessionStore: sessionStore,
      onSessionEnded: onSessionEnded,
    ),
    RetryInterceptor(dio: dio, delay: retryDelay, random: random),
  ]);
  return dio;
}

/// Transport override for the API client. Null in the app (Dio's platform
/// adapter); tests inject a fake adapter so no real network is used.
final apiHttpAdapterProvider = Provider<HttpClientAdapter?>((ref) => null);

/// The app-wide API client.
final apiClientProvider = Provider<Dio>((ref) {
  final dio = createApiClient(
    config: ref.watch(appConfigProvider),
    clientInfo: ref.watch(clientInfoProvider),
    sessionStore: ref.watch(sessionStoreProvider),
    onSessionEnded: () {
      // The server ended it (or the refresh could not continue): tell the person.
      ref.read(sessionEndedNoticeProvider.notifier).raise();
      return ref.read(authControllerProvider.notifier).signOut();
    },
    adapter: ref.watch(apiHttpAdapterProvider),
  );
  ref.onDispose(dio.close);
  return dio;
});
