import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A snapshot of a request as it reached the network (headers are copied, because
/// Dio reuses the same [RequestOptions] object across retries).
class RecordedRequest {
  RecordedRequest(RequestOptions options)
    : method = options.method,
      path = options.path,
      uri = options.uri,
      headers = Map<String, dynamic>.of(options.headers),
      data = options.data;

  final String method;
  final String path;
  final Uri uri;
  final Map<String, dynamic> headers;
  final Object? data;

  String? header(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) {
        return '${entry.value}';
      }
    }
    return null;
  }

  String? get bearer {
    final value = header('Authorization');
    return value != null && value.startsWith('Bearer ')
        ? value.substring(7)
        : null;
  }
}

/// What the fake network returns for a request.
sealed class FakeReply {
  const FakeReply();

  /// A JSON response.
  const factory FakeReply.json(
    int status, [
    Object? body,
    Map<String, String> headers,
  ]) = JsonReply;

  /// An RFC 9457 problem response.
  factory FakeReply.problem(
    int status,
    String code, {
    Map<String, Object?> extra = const {},
    Map<String, String> headers = const {},
  }) => JsonReply(
    status,
    <String, Object?>{
      'type': 'https://afterme.invalid/problems/${code.replaceAll('_', '-')}',
      'title': code,
      'status': status,
      'code': code,
      'detail': 'detail for $code',
      'request_id': 'req-$code',
      ...extra,
    },
    headers,
    'application/problem+json',
  );

  /// The connection fails before any response (offline, reset, DNS).
  const factory FakeReply.networkError() = NetworkErrorReply;

  /// A response with a raw body and content type.
  const factory FakeReply.raw(int status, String body, String contentType) =
      RawReply;
}

final class JsonReply extends FakeReply {
  const JsonReply(
    this.status, [
    this.body,
    this.headers = const {},
    this.contentType = 'application/json',
  ]);

  final int status;
  final Object? body;
  final Map<String, String> headers;
  final String contentType;
}

final class NetworkErrorReply extends FakeReply {
  const NetworkErrorReply();
}

final class RawReply extends FakeReply {
  const RawReply(this.status, this.body, this.contentType);

  final int status;
  final String body;
  final String contentType;
}

typedef FakeHandler = FutureOr<FakeReply> Function(
  RecordedRequest request,
  int callIndex,
);

/// A scriptable [HttpClientAdapter]: no real network, every request recorded.
class FakeHttpAdapter implements HttpClientAdapter {
  FakeHttpAdapter(this._handler);

  final FakeHandler _handler;

  /// Every request that reached the network, in order.
  final List<RecordedRequest> requests = [];

  int _calls = 0;

  List<RecordedRequest> requestsTo(String path) =>
      requests.where((r) => r.path == path).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final recorded = RecordedRequest(options);
    requests.add(recorded);
    final reply = await _handler(recorded, _calls++);
    switch (reply) {
      case NetworkErrorReply():
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'fake network error',
        );
      case RawReply(:final status, :final body, :final contentType):
        return ResponseBody.fromString(
          body,
          status,
          headers: {
            Headers.contentTypeHeader: [contentType],
          },
        );
      case JsonReply(
        :final status,
        :final body,
        :final headers,
        :final contentType,
      ):
        return ResponseBody.fromString(
          body == null ? '' : jsonEncode(body),
          status,
          headers: {
            Headers.contentTypeHeader: [contentType],
            for (final entry in headers.entries) entry.key: [entry.value],
          },
        );
    }
  }

  @override
  void close({bool force = false}) {}
}
