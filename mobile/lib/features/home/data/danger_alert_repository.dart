import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';

/// The Danger button: `POST /v1/contacts/alert` emails every trusted contact who has
/// accepted, at once. Answers how many were alerted. Not retried automatically: the
/// person sees the result and can press again.
class DangerAlertRepository {
  DangerAlertRepository({required this.dio});

  final Dio dio;

  Future<int> alertContacts() async {
    try {
      final response = await dio.post<Object?>('/v1/contacts/alert');
      final data = response.data;
      if (data is Map<String, dynamic> && data['alerted'] is int) {
        return data['alerted'] as int;
      }
      throw const UnknownFailure();
    } on DioException catch (error) {
      throw mapDioException(error);
    }
  }
}

final dangerAlertRepositoryProvider = Provider<DangerAlertRepository>(
  (ref) => DangerAlertRepository(dio: ref.watch(apiClientProvider)),
);
