import 'package:dio/dio.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/device/device_info_source.dart';
import 'devices_repository.dart';

/// `/v1/devices/current` over Dio.
///
/// The `PUT` is not marked idempotent (no `Idempotency-Key`) and is not retried by the
/// client: it is an upsert, and the push coordinator tries again by itself, later, when
/// something may have changed (a token refresh, the app returning, the network).
class DioDevicesRepository implements DevicesRepository {
  DioDevicesRepository({required this.dio});

  final Dio dio;

  static const String _path = '/v1/devices/current';

  @override
  Future<DeviceRegistration> update(
    DeviceDescriptor device,
    PushTokenChange token,
  ) => _run(() async {
    final response = await dio.put<Object?>(
      _path,
      data: deviceUpdateBody(device, token),
    );
    final data = response.data;
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object');
    }
    return DeviceRegistration.fromJson(data);
  });

  @override
  Future<void> deletePushToken() =>
      _run(() => dio.delete<Object?>('$_path/push-token')).then((_) {});

  Future<T> _run<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (error) {
      throw mapDioException(error);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      // A success answer that is not the expected shape.
      throw UnknownFailure(cause: error);
    }
  }
}
