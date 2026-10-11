import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Tells the app when the server refuses this version (`426`) and when it accepts it
/// again (a `2xx`), whichever repository made the request.
///
/// It sits **last** in the chain, so it sees the final outcome of a request: after the
/// token refresh, the retries and every other interceptor have had their say, and a 426
/// from the refresh call itself (which reaches the original request as its failure)
/// counts too. It only observes: the response or the error continues unchanged, so every
/// caller still gets the `UpgradeRequiredFailure` it would have got.
///
/// Only the status 426 raises the gate. A 401, 403, 404, 409, 422, 429 or 5xx, or a
/// failure without a response (offline), never does.
class UpgradeGateInterceptor extends Interceptor {
  UpgradeGateInterceptor({
    required this.onUpgradeRequired,
    required this.onAccepted,
  });

  /// Called for a response with status 426.
  final VoidCallback onUpgradeRequired;

  /// Called for a successful (2xx) response.
  final VoidCallback onAccepted;

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) {
      onAccepted();
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.response?.statusCode == 426) {
      onUpgradeRequired();
    }
    handler.next(err);
  }
}
