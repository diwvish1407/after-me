import 'package:dio/dio.dart';

import '../api_options.dart';
import '../client_info.dart';

/// Adds `X-AfterMe-Client: android/<version>+<build>` to every request so the API can
/// answer `426 upgrade_required` for unsupported versions (API_SPEC.md §1).
class ClientInfoInterceptor extends Interceptor {
  ClientInfoInterceptor(this._clientInfo);

  final ClientInfo _clientInfo;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.headers[ApiHeaders.client] = _clientInfo.headerValue;
    handler.next(options);
  }
}
