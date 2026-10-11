import 'dart:convert';

import 'package:freezed_annotation/freezed_annotation.dart';

part 'api_problem.freezed.dart';
part 'api_problem.g.dart';

/// One field error in a `422 validation_failed` problem (API_SPEC.md §1.1).
@freezed
abstract class ApiFieldError with _$ApiFieldError {
  const factory ApiFieldError({
    required String field,
    required String code,
    String? message,
  }) = _ApiFieldError;

  factory ApiFieldError.fromJson(Map<String, dynamic> json) =>
      _$ApiFieldErrorFromJson(json);
}

/// An RFC 9457 `application/problem+json` body (API_SPEC.md §1.1).
///
/// Only the documented extension members are modelled; unknown members are ignored.
@freezed
abstract class ApiProblem with _$ApiProblem {
  const factory ApiProblem({
    required int status,
    String? type,
    String? title,
    String? code,
    String? detail,
    String? requestId,
    @Default(<ApiFieldError>[]) List<ApiFieldError> errors,
    String? incidentId,
    List<String>? instructionIds,
    List<String>? requirements,
    int? limit,
    int? current,
    String? resource,
  }) = _ApiProblem;

  factory ApiProblem.fromJson(Map<String, dynamic> json) =>
      _$ApiProblemFromJson(json);

  /// Parses a response body into a problem, or returns null when the body is not a
  /// problem document (for example an HTML error page from a proxy).
  ///
  /// [data] may be an already-decoded map, a JSON string or the raw bytes of one (a
  /// request made with `ResponseType.bytes`, such as the data export, delivers its error
  /// bodies undecoded). When the body has no `status`, [httpStatus] is used.
  static ApiProblem? tryParse(Object? data, {required int httpStatus}) {
    Object? decoded = data;
    if (decoded is List<int>) {
      decoded = utf8.decode(decoded, allowMalformed: true);
    }
    if (decoded is String) {
      if (decoded.trim().isEmpty) {
        return null;
      }
      try {
        decoded = jsonDecode(decoded);
      } on FormatException {
        return null;
      }
    }
    if (decoded is! Map) {
      return null;
    }
    final json = <String, dynamic>{
      for (final entry in decoded.entries) '${entry.key}': entry.value,
    };
    if (json['status'] is! int) {
      json['status'] = httpStatus;
    }
    try {
      return ApiProblem.fromJson(json);
    } on Object {
      // A malformed problem body must never mask the HTTP status: callers fall back
      // to status-only mapping.
      return null;
    }
  }
}
