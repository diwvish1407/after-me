import 'package:dio/dio.dart';

import '../../../core/api/api_options.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import 'checkin_repository.dart';

/// The check-in API over Dio (API_SPEC.md §6.2).
///
/// `POST /checkins` always carries the caller's `Idempotency-Key`, so the API client
/// may repeat it after a dropped connection or a 503 (up to its attempt limit) and the
/// server still records one check-in.
class DioCheckInRepository implements CheckInRepository {
  DioCheckInRepository({required this.dio});

  final Dio dio;

  Future<T> _run<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (error) {
      throw mapDioException(error);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      // Malformed success body: the check-in is NOT treated as recorded.
      throw UnknownFailure(cause: error);
    }
  }

  /// `2026-10-14T13:30:00Z`: UTC, whole seconds.
  static String _rfc3339(DateTime instant) {
    final utc = instant.toUtc();
    final iso = DateTime.utc(
      utc.year,
      utc.month,
      utc.day,
      utc.hour,
      utc.minute,
      utc.second,
    ).toIso8601String();
    return '${iso.substring(0, iso.indexOf('.'))}Z';
  }

  Map<String, dynamic> _object(Response<Object?> response) {
    final data = response.data;
    if (data is Map<String, dynamic>) {
      return data;
    }
    throw const FormatException('Expected a JSON object');
  }

  @override
  Future<CheckInResult> checkIn({
    required String idempotencyKey,
    DateTime? clientReportedAt,
  }) => _run(() async {
    final response = await dio.post<Object?>(
      '/v1/checkins',
      data: <String, Object?>{
        if (clientReportedAt != null)
          'client_reported_at': _rfc3339(clientReportedAt),
      },
      options: apiOptions(idempotencyKey: idempotencyKey),
    );
    // Only a parsed 200 counts as "received".
    return CheckInResult.fromJson(_object(response));
  });

  @override
  Future<CheckInHistoryPage> history({int limit = 20, String? cursor}) =>
      _run(() async {
        final response = await dio.get<Object?>(
          '/v1/checkins',
          queryParameters: <String, Object?>{'limit': limit, 'cursor': ?cursor},
        );
        return CheckInHistoryPage.fromJson(_object(response));
      });
}
