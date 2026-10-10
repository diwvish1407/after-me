import 'dart:io' show HttpException, SocketException;

import 'package:dio/dio.dart';

const _transportTypes = {
  DioExceptionType.connectionTimeout,
  DioExceptionType.sendTimeout,
  DioExceptionType.receiveTimeout,
  DioExceptionType.connectionError,
};

/// Whether [error] is a transient transport failure: no usable response because the
/// network dropped, timed out or reset the connection.
///
/// Dio reports a reset while the body is being sent or read as
/// [DioExceptionType.unknown] wrapping a [SocketException] or [HttpException], so the
/// type alone is not enough. Both the retry policy and the failure mapper use this one
/// definition, so a failure is retried exactly when the user is told it was a network
/// problem. A bad certificate is not transient and is deliberately excluded.
bool isTransportFailure(DioException error) {
  if (_transportTypes.contains(error.type)) {
    return true;
  }
  final cause = error.error;
  return error.type == DioExceptionType.unknown &&
      (cause is SocketException || cause is HttpException);
}
