import 'package:freezed_annotation/freezed_annotation.dart';

part 'token_response.freezed.dart';
part 'token_response.g.dart';

/// The account summary returned with a new session (API_SPEC.md §2.2).
@freezed
abstract class TokenUser with _$TokenUser {
  const TokenUser._();

  /// Redacted: tokens and personal details must never reach a log.
  @override
  String toString() => 'TokenUser(<redacted>)';

  const factory TokenUser({
    required String id,
    required String email,
    required String tier,
  }) = _TokenUser;

  factory TokenUser.fromJson(Map<String, dynamic> json) =>
      _$TokenUserFromJson(json);
}

/// Response of `POST /v1/auth/register/verify` (201) and `POST /v1/auth/login` (200)
/// (API_SPEC.md §2.2–2.3).
@freezed
abstract class TokenResponse with _$TokenResponse {
  const TokenResponse._();

  /// Redacted: tokens and personal details must never reach a log.
  @override
  String toString() => 'TokenResponse(<redacted>)';

  const factory TokenResponse({
    required String accessToken,
    required DateTime accessTokenExpiresAt,
    required String refreshToken,
    required String sessionId,
    required String deviceId,
    required TokenUser user,
  }) = _TokenResponse;

  factory TokenResponse.fromJson(Map<String, dynamic> json) =>
      _$TokenResponseFromJson(json);
}

/// Response of `POST /v1/auth/refresh` (API_SPEC.md §2.3). The refresh token is
/// rotated on every use and must be persisted before the new access token is used.
@freezed
abstract class RefreshResponse with _$RefreshResponse {
  const RefreshResponse._();

  /// Redacted: tokens and personal details must never reach a log.
  @override
  String toString() => 'RefreshResponse(<redacted>)';

  const factory RefreshResponse({
    required String accessToken,
    required DateTime accessTokenExpiresAt,
    required String refreshToken,
  }) = _RefreshResponse;

  factory RefreshResponse.fromJson(Map<String, dynamic> json) =>
      _$RefreshResponseFromJson(json);
}
