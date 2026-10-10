import 'package:dio/dio.dart';

import '../api_options.dart';
import '../models/api_problem.dart';
import 'app_failure.dart';
import 'retry_after.dart';
import 'transport_failure.dart';

/// Maps a [DioException] to an [AppFailure]. This is the single place where
/// transport errors and problem+json responses become app failures.
///
/// [now] is used to resolve an HTTP-date `Retry-After`; tests inject a fixed clock.
AppFailure mapDioException(DioException error, {DateTime Function()? now}) {
  // The API client itself may fail a request with a ready-made failure (for example
  // after ending a session whose refresh was rejected).
  final cause = error.error;
  if (cause is AppFailure) {
    return cause;
  }
  switch (error.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
    case DioExceptionType.badCertificate:
      return NetworkFailure(cause: error.error ?? error.type);
    case DioExceptionType.cancel:
    case DioExceptionType.transformTimeout:
      return UnknownFailure(cause: error.type);
    case DioExceptionType.unknown:
      if (isTransportFailure(error)) {
        return NetworkFailure(cause: cause);
      }
      return UnknownFailure(cause: cause ?? error.type);
    case DioExceptionType.badResponse:
      final response = error.response;
      if (response == null) {
        return UnknownFailure(cause: error.type);
      }
      return mapErrorResponse(response, now: now);
  }
}

/// Maps a non-2xx [response] to an [AppFailure] using its status and problem code.
AppFailure mapErrorResponse(
  Response<dynamic> response, {
  DateTime Function()? now,
}) {
  final status = response.statusCode ?? 0;
  final problem = ApiProblem.tryParse(response.data, httpStatus: status);
  final code = problem?.code;
  return switch (status) {
    400 || 413 => ValidationFailure(code: code, problem: problem),
    401 => UnauthorizedFailure(code: code, problem: problem),
    403 when code == 'plan_limit_reached' => PlanLimitFailure(
      limit: problem?.limit,
      current: problem?.current,
      resource: problem?.resource,
      problem: problem,
    ),
    403 => ForbiddenFailure(code: code, problem: problem),
    404 => NotFoundFailure(problem: problem),
    409 when code == 'contact_duplicate' => ContactDuplicateFailure(
      problem: problem,
    ),
    409 when code == 'invalid_state' => InvalidStateFailure(problem: problem),
    409 when code == 'activation_requirements_unmet' =>
      ActivationRequirementsFailure(
        requirements: problem?.requirements ?? const <String>[],
        problem: problem,
      ),
    409 || 412 || 428 => ConflictFailure(code: code, problem: problem),
    422 when code == 'cannot_be_own_email' => CannotBeOwnEmailFailure(
      fieldErrors: problem?.errors ?? const [],
      problem: problem,
    ),
    422 => ValidationFailure(
      code: code,
      fieldErrors: problem?.errors ?? const [],
      problem: problem,
    ),
    426 => UpgradeRequiredFailure(problem: problem),
    429 => RateLimitedFailure(
      retryAfter: parseRetryAfter(
        response.headers.value(ApiHeaders.retryAfter),
        now: now?.call(),
      ),
      problem: problem,
    ),
    >= 500 && < 600 => ServerFailure(statusCode: status, problem: problem),
    _ => UnknownFailure(statusCode: status, problem: problem),
  };
}

/// Converts any error thrown by an API call into an [AppFailure].
AppFailure toAppFailure(Object error, {DateTime Function()? now}) =>
    switch (error) {
      AppFailure() => error,
      DioException() => mapDioException(error, now: now),
      _ => UnknownFailure(cause: error),
    };
