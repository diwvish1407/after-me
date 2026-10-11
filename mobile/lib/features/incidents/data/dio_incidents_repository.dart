import 'package:dio/dio.dart';

import '../../../core/api/api_options.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import 'incidents_repository.dart';

/// The incidents API over Dio (API_SPEC.md §9).
///
/// `POST …/safe` always carries the caller's `Idempotency-Key`, so the API client may
/// repeat it after a dropped connection or a 503 (up to its attempt limit) and the
/// server still stops the incident once. Reads are repeated by the client after a
/// transient failure. Names and titles in the answers are never logged.
class DioIncidentsRepository implements IncidentsRepository {
  DioIncidentsRepository({required this.dio});

  final Dio dio;

  static String _path([String? id, String? action]) {
    final base =
        '/v1/incidents${id == null ? '' : '/${Uri.encodeComponent(id)}'}';
    return action == null ? base : '$base/$action';
  }

  Future<T> _run<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (error) {
      throw mapDioException(error);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      // Malformed success body: nothing is treated as confirmed.
      throw UnknownFailure(cause: error);
    }
  }

  Map<String, dynamic> _object(Response<Object?> response) {
    final data = response.data;
    if (data is Map<String, dynamic>) {
      return data;
    }
    throw const FormatException('Expected a JSON object');
  }

  @override
  Future<IncidentPage> list({int limit = 20, String? cursor}) => _run(() async {
    final response = await dio.get<Object?>(
      _path(),
      queryParameters: <String, Object?>{'limit': limit, 'cursor': ?cursor},
    );
    return IncidentPage.fromJson(_object(response));
  });

  @override
  Future<Incident> get(String id) => _run(() async {
    final response = await dio.get<Object?>(_path(id));
    return Incident.fromJson(_object(response));
  });

  @override
  Future<SafeResult> markSafe(
    String incidentId, {
    required String idempotencyKey,
  }) => _run(() async {
    final response = await dio.post<Object?>(
      _path(incidentId, 'safe'),
      options: apiOptions(idempotencyKey: idempotencyKey),
    );
    // Only a parsed 200 counts as "marked safe".
    return SafeResult.fromJson(_object(response));
  });
}
