import 'package:dio/dio.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import 'home_repository.dart';

/// `GET /v1/home` over Dio. A read: the API client repeats it after a transient
/// failure.
class DioHomeRepository implements HomeRepository {
  DioHomeRepository({required this.dio});

  final Dio dio;

  @override
  Future<HomeSnapshot> load() async {
    try {
      final response = await dio.get<Object?>('/v1/home');
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw const FormatException('Expected a JSON object');
      }
      return HomeSnapshot.fromJson(data);
    } on DioException catch (error) {
      throw mapDioException(error);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw UnknownFailure(cause: error);
    }
  }
}
