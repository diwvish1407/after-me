import 'package:dio/dio.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import 'schedule_repository.dart';

/// The schedule API over Dio (API_SPEC.md §6.1).
///
/// A change carries `If-Match` with the ETag of the snapshot it was made from. None of
/// these calls is retried automatically (no `Idempotency-Key`; the retry policy only
/// repeats GET and keyed requests): a failed save is shown to the person, who decides.
class DioScheduleRepository implements ScheduleRepository {
  DioScheduleRepository({required this.dio});

  final Dio dio;

  static const _schedule = '/v1/checkin/schedule';

  Future<T> _run<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (error) {
      throw mapDioException(error);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      // Malformed success body (bad JSON shape, a time that is not HH:MM, ...).
      throw UnknownFailure(cause: error);
    }
  }

  ScheduleSnapshot _snapshot(Response<Object?> response) {
    final data = response.data;
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object');
    }
    // A time of day that is not HH:MM fails here, in parsing, not later in the UI.
    return ScheduleSnapshot.fromJson(data)
        .copyWith(etag: response.headers.value('etag'));
  }

  @override
  Future<ScheduleSnapshot> get() => _run(() async {
    return _snapshot(await dio.get<Object?>(_schedule));
  });

  @override
  Future<ScheduleSnapshot> save(
    CheckInSchedule schedule, {
    required String ifMatch,
  }) => _run(() async {
    return _snapshot(
      await dio.put<Object?>(
        _schedule,
        data: schedule.toJson(),
        options: Options(headers: <String, Object>{'If-Match': ifMatch}),
      ),
    );
  });

  @override
  Future<ScheduleSnapshot> activate() => _run(() async {
    return _snapshot(await dio.post<Object?>('/v1/checkin/activate'));
  });

  @override
  Future<ScheduleSnapshot> deactivate() => _run(() async {
    return _snapshot(await dio.post<Object?>('/v1/checkin/deactivate'));
  });
}
