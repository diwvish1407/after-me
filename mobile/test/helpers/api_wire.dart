import 'package:afterme/core/api/api_client.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:dio/dio.dart';

import 'fake_http_adapter.dart';
import 'fakes.dart';
import 'test_app.dart';

/// The real API client (every interceptor) on a fake network, for repository tests:
/// nothing leaves the process.
class ApiWire {
  ApiWire(this.dio, this.adapter);

  final Dio dio;
  final FakeHttpAdapter adapter;

  /// The only request that reached the network.
  RecordedRequest get request => adapter.requests.single;

  Map<String, dynamic> get body => request.data! as Map<String, dynamic>;
}

Future<ApiWire> apiWire(FakeHandler handler) async {
  final adapter = FakeHttpAdapter(handler);
  final session = SessionStore(InMemorySecureStore());
  await session.saveSession(tokenResponse());
  final dio = createApiClient(
    config: devConfig,
    clientInfo: testClientInfo,
    sessionStore: session,
    onSessionEnded: () async {},
    adapter: adapter,
    retryDelay: (_) async {},
  );
  return ApiWire(dio, adapter);
}
