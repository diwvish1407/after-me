import 'package:dio/dio.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';

class MfaStatus {
  const MfaStatus({required this.enabled, required this.recoveryCodesLeft});

  final bool enabled;
  final int recoveryCodesLeft;
}

class MfaSetup {
  const MfaSetup({required this.secret, required this.otpauthUri});

  /// Base32, for typing into an authenticator app.
  final String secret;

  /// `otpauth://` link: opens an installed authenticator app directly.
  final String otpauthUri;
}

/// Two-step verification (`/v1/me/2fa`). Setup and turning it off need a fresh password
/// (`reauth_required`); a wrong code is `invalid_otp`.
abstract interface class MfaRepository {
  Future<MfaStatus> status();
  Future<MfaSetup> setup();
  Future<List<String>> enable(String code);
  Future<void> disable(String code);
}

class DioMfaRepository implements MfaRepository {
  DioMfaRepository({required this.dio});

  final Dio dio;
  static const _base = '/v1/me/2fa';

  Future<T> _run<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (error) {
      throw mapDioException(error);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw UnknownFailure(cause: error);
    }
  }

  Map<String, dynamic> _object(Response<Object?> r) {
    final data = r.data;
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object');
    }
    return data;
  }

  @override
  Future<MfaStatus> status() => _run(() async {
    final data = _object(await dio.get<Object?>(_base));
    return MfaStatus(
      enabled: data['enabled'] as bool? ?? false,
      recoveryCodesLeft: (data['recovery_codes_left'] as num?)?.toInt() ?? 0,
    );
  });

  @override
  Future<MfaSetup> setup() => _run(() async {
    final data = _object(await dio.post<Object?>('$_base/setup'));
    return MfaSetup(
      secret: data['secret'] as String,
      otpauthUri: data['otpauth_uri'] as String,
    );
  });

  @override
  Future<List<String>> enable(String code) => _run(() async {
    final data = _object(
      await dio.post<Object?>('$_base/enable', data: {'code': code}),
    );
    return [
      for (final c in data['recovery_codes'] as List<dynamic>) c as String,
    ];
  });

  @override
  Future<void> disable(String code) => _run(() async {
    await dio.post<Object?>('$_base/disable', data: {'code': code});
  });
}
