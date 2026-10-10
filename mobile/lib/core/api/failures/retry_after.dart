import 'dart:io' show HttpDate, HttpException;

/// Parses an HTTP `Retry-After` value (RFC 9110 §10.2.3): either delay-seconds
/// (`"120"`) or an HTTP-date. Returns null when absent or malformed; never negative.
Duration? parseRetryAfter(String? value, {DateTime? now}) {
  if (value == null) {
    return null;
  }
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final seconds = int.tryParse(trimmed);
  if (seconds != null) {
    return seconds < 0 ? null : Duration(seconds: seconds);
  }
  try {
    final at = HttpDate.parse(trimmed);
    final difference = at.difference((now ?? DateTime.now()).toUtc());
    return difference.isNegative ? Duration.zero : difference;
  } on FormatException {
    return null;
  } on HttpException {
    return null;
  }
}
