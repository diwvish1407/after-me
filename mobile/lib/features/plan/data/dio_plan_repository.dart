import 'package:dio/dio.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import 'plan_repository.dart';

/// The plan API over Dio (API_SPEC.md §8).
///
/// A save carries `If-Match` with the `"plan-<version>"` of the plan it was made from.
/// Like the schedule, none of these calls is retried automatically (no
/// `Idempotency-Key`; the retry policy only repeats GET and keyed requests): a failed
/// save is shown to the person, who decides.
class DioPlanRepository implements PlanRepository {
  DioPlanRepository({required this.dio});

  final Dio dio;

  static const _plan = '/v1/plan';

  Future<T> _run<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (error) {
      throw mapDioException(error);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      // Malformed success body (bad JSON shape, a missing field, ...).
      throw UnknownFailure(cause: error);
    }
  }

  Plan _snapshot(Response<Object?> response) {
    final data = response.data;
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object');
    }
    return Plan.fromJson(data).copyWith(etag: response.headers.value('etag'));
  }

  @override
  Future<Plan> get() => _run(() async {
    return _snapshot(await dio.get<Object?>(_plan));
  });

  @override
  Future<Plan> save(PlanDraft draft, {required String ifMatch}) =>
      _run(() async {
        return _snapshot(
          await dio.put<Object?>(
            _plan,
            data: draft.toJson(),
            options: Options(headers: <String, Object>{'If-Match': ifMatch}),
          ),
        );
      });
}
