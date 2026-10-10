import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_options.dart';
import '../../../core/api/client_info.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/api/models/token_response.dart';
import '../../../core/auth/session_store.dart';
import '../../../core/device/device_info_source.dart';
import 'models/account_models.dart';

/// A partial profile update (`PATCH /v1/me/profile`). Only the fields that are set are
/// sent; [clearPhone] and [clearCountry] send an explicit `null`.
class ProfilePatch {
  const ProfilePatch({
    this.displayName,
    this.phoneE164,
    this.countryCode,
    this.timezone,
    this.locale,
    this.clearPhone = false,
    this.clearCountry = false,
  });

  final String? displayName;
  final String? phoneE164;
  final String? countryCode;
  final String? timezone;
  final String? locale;
  final bool clearPhone;
  final bool clearCountry;

  bool get isEmpty => toJson().isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'display_name': ?displayName,
    if (clearPhone) 'phone_e164': null else 'phone_e164': ?phoneE164,
    if (clearCountry) 'country_code': null else 'country_code': ?countryCode,
    'timezone': ?timezone,
    'locale': ?locale,
  };
}

/// Everything the app does with the account endpoints (API_SPEC.md §2-3).
///
/// Methods complete normally on success and throw an [AppFailure] otherwise
/// (see `toAppFailure`). Implementations never log request bodies: they carry
/// passwords and codes.
abstract interface class AuthRepository {
  /// `POST /auth/register/start`. [password] is validated server-side with the same
  /// policy as everywhere else.
  Future<RegisterStartResult> registerStart({
    required String email,
    required String password,
    required String displayName,
    required String timezone,
    required String locale,
    String? countryCode,
  });

  /// `POST /auth/register/verify`. The signup password must be repeated.
  Future<TokenResponse> registerVerify({
    required String email,
    required String code,
    required String password,
  });

  /// `POST /auth/register/resend`. Returns the seconds before the next resend.
  Future<int> registerResend({required String email});

  /// `POST /auth/login`. `403 email_unverified` arrives as a [ForbiddenFailure].
  Future<TokenResponse> login({
    required String email,
    required String password,
  });

  /// `POST /auth/logout`.
  Future<void> logout();

  /// `POST /auth/logout-all`.
  Future<void> logoutAll();

  /// `POST /auth/password/forgot`. Always succeeds from the user's point of view.
  Future<void> forgotPassword({required String email});

  /// `POST /auth/reauth`. A wrong password is a 401 `invalid_credentials`, which
  /// keeps the session.
  Future<void> reauth({required String password});

  /// `POST /auth/password/change`.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  });

  /// `POST /auth/email/change/start` (needs a recent re-auth).
  Future<void> emailChangeStart({required String newEmail});

  /// `POST /auth/email/change/verify`; returns the updated account.
  Future<MeResponse> emailChangeVerify({required String code});

  /// `GET /auth/sessions`.
  Future<List<SessionItem>> listSessions();

  /// `DELETE /auth/sessions/{id}`.
  Future<void> revokeSession(String id);

  /// `GET /me`.
  Future<MeResponse> me();

  /// `PATCH /me/profile`.
  Future<MeResponse> patchProfile(ProfilePatch patch);
}

/// The Dio implementation. Public endpoints opt out of auth with
/// `apiOptions(authenticated: false)`.
class DioAuthRepository implements AuthRepository {
  DioAuthRepository({
    required this.dio,
    required this.clientInfo,
    required this.deviceInfo,
    required this.sessionStore,
  });

  final Dio dio;
  final ClientInfo clientInfo;
  final DeviceInfoSource deviceInfo;
  final SessionStore sessionStore;

  static final Options _public = apiOptions(authenticated: false);

  Future<Map<String, Object?>> _device({bool includeId = false}) async {
    final descriptor = await DeviceDescriptors.describe(clientInfo, deviceInfo);
    String? id;
    if (includeId) {
      try {
        id = await sessionStore.readDeviceId();
      } on Object {
        id = null;
      }
    }
    return <String, Object?>{
      if (id != null && id.isNotEmpty) 'id': id,
      ...descriptor.toJson(),
    };
  }

  /// Runs [call], converting every error to an [AppFailure].
  Future<T> _run<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (error) {
      throw mapDioException(error);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      // Malformed success body (CheckedFromJsonException, cast errors, ...).
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
  Future<RegisterStartResult> registerStart({
    required String email,
    required String password,
    required String displayName,
    required String timezone,
    required String locale,
    String? countryCode,
  }) => _run(() async {
    final response = await dio.post<Object?>(
      '/v1/auth/register/start',
      data: <String, Object?>{
        'email': email,
        'password': password,
        'display_name': displayName,
        'timezone': timezone,
        'locale': locale,
        'country_code': ?countryCode,
      },
      options: _public,
    );
    return RegisterStartResult.fromJson(_object(response));
  });

  @override
  Future<TokenResponse> registerVerify({
    required String email,
    required String code,
    required String password,
  }) => _run(() async {
    final response = await dio.post<Object?>(
      '/v1/auth/register/verify',
      data: <String, Object?>{
        'email': email,
        'code': code,
        'password': password,
        'device': await _device(),
      },
      options: _public,
    );
    return TokenResponse.fromJson(_object(response));
  });

  @override
  Future<int> registerResend({required String email}) => _run(() async {
    final response = await dio.post<Object?>(
      '/v1/auth/register/resend',
      data: <String, Object?>{'email': email},
      options: _public,
    );
    final data = response.data;
    final seconds = data is Map ? data['resend_after_seconds'] : null;
    return seconds is int && seconds > 0 ? seconds : 60;
  });

  @override
  Future<TokenResponse> login({
    required String email,
    required String password,
  }) => _run(() async {
    final response = await dio.post<Object?>(
      '/v1/auth/login',
      data: <String, Object?>{
        'email': email,
        'password': password,
        'device': await _device(includeId: true),
      },
      options: _public,
    );
    return TokenResponse.fromJson(_object(response));
  });

  @override
  Future<void> logout() =>
      _run(() => dio.post<Object?>('/v1/auth/logout')).then((_) {});

  @override
  Future<void> logoutAll() =>
      _run(() => dio.post<Object?>('/v1/auth/logout-all')).then((_) {});

  @override
  Future<void> forgotPassword({required String email}) => _run(
    () => dio.post<Object?>(
      '/v1/auth/password/forgot',
      data: <String, Object?>{'email': email},
      options: _public,
    ),
  ).then((_) {});

  @override
  Future<void> reauth({required String password}) => _run(
    () => dio.post<Object?>(
      '/v1/auth/reauth',
      data: <String, Object?>{'password': password},
    ),
  ).then((_) {});

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) => _run(
    () => dio.post<Object?>(
      '/v1/auth/password/change',
      data: <String, Object?>{
        'current_password': currentPassword,
        'new_password': newPassword,
      },
    ),
  ).then((_) {});

  @override
  Future<void> emailChangeStart({required String newEmail}) => _run(
    () => dio.post<Object?>(
      '/v1/auth/email/change/start',
      data: <String, Object?>{'new_email': newEmail},
    ),
  ).then((_) {});

  @override
  Future<MeResponse> emailChangeVerify({required String code}) =>
      _run(() async {
        final response = await dio.post<Object?>(
          '/v1/auth/email/change/verify',
          data: <String, Object?>{'code': code},
        );
        return MeResponse.fromJson(_object(response));
      });

  @override
  Future<List<SessionItem>> listSessions() => _run(() async {
    final response = await dio.get<Object?>('/v1/auth/sessions');
    return SessionList.fromJson(_object(response)).items;
  });

  @override
  Future<void> revokeSession(String id) => _run(
    () => dio.delete<Object?>('/v1/auth/sessions/${Uri.encodeComponent(id)}'),
  ).then((_) {});

  @override
  Future<MeResponse> me() => _run(() async {
    final response = await dio.get<Object?>('/v1/me');
    return MeResponse.fromJson(_object(response));
  });

  @override
  Future<MeResponse> patchProfile(ProfilePatch patch) => _run(() async {
    final response = await dio.patch<Object?>(
      '/v1/me/profile',
      data: patch.toJson(),
    );
    return MeResponse.fromJson(_object(response));
  });
}

/// The account API. Tests override it with a fake.
final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => DioAuthRepository(
    dio: ref.watch(apiClientProvider),
    clientInfo: ref.watch(clientInfoProvider),
    deviceInfo: ref.watch(deviceInfoSourceProvider),
    sessionStore: ref.watch(sessionStoreProvider),
  ),
);
