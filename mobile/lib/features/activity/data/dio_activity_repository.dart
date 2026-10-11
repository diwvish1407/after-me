import 'package:dio/dio.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import 'activity_repository.dart';

/// `GET /v1/activity` over Dio. A read: the API client repeats it after a transient
/// failure. Names and titles in the answer are never logged.
class DioActivityRepository implements ActivityRepository {
  DioActivityRepository({required this.dio});

  final Dio dio;

  @override
  Future<ActivityPage> list({int limit = 20, String? cursor}) async {
    try {
      final response = await dio.get<Object?>(
        '/v1/activity',
        queryParameters: <String, Object?>{'limit': limit, 'cursor': ?cursor},
      );
      return ActivityPage.fromJson(response.data);
    } on DioException catch (error) {
      throw mapDioException(error);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      // A damaged answer: nothing is treated as an empty feed.
      throw UnknownFailure(cause: error);
    }
  }
}
