import 'package:freezed_annotation/freezed_annotation.dart';

part 'account_models.freezed.dart';
part 'account_models.g.dart';

/// The profile part of `GET /v1/me` (API_SPEC.md §3).
@freezed
abstract class Profile with _$Profile {
  const Profile._();

  /// Redacted: tokens and personal details must never reach a log.
  @override
  String toString() => 'Profile(<redacted>)';

  const factory Profile({
    required String displayName,
    required String timezone,
    required String locale,
    String? phoneE164,
    String? countryCode,
  }) = _Profile;

  factory Profile.fromJson(Map<String, dynamic> json) =>
      _$ProfileFromJson(json);
}

/// `GET /v1/me`, `PATCH /v1/me/profile` and `POST /v1/auth/email/change/verify`.
@freezed
abstract class MeResponse with _$MeResponse {
  const MeResponse._();

  /// Redacted: tokens and personal details must never reach a log.
  @override
  String toString() => 'MeResponse(<redacted>)';

  const factory MeResponse({
    required String id,
    required String email,
    required String tier,
    required String status,
    required Profile profile,
    required DateTime createdAt,
  }) = _MeResponse;

  factory MeResponse.fromJson(Map<String, dynamic> json) =>
      _$MeResponseFromJson(json);
}

/// `POST /v1/auth/register/start` -> 202.
@freezed
abstract class RegisterStartResult with _$RegisterStartResult {
  const factory RegisterStartResult({
    required String status,
    @Default(60) int resendAfterSeconds,
  }) = _RegisterStartResult;

  factory RegisterStartResult.fromJson(Map<String, dynamic> json) =>
      _$RegisterStartResultFromJson(json);
}

/// The device summary in a session row.
@freezed
abstract class SessionDevice with _$SessionDevice {
  const factory SessionDevice({required String platform, String? appVersion}) =
      _SessionDevice;

  factory SessionDevice.fromJson(Map<String, dynamic> json) =>
      _$SessionDeviceFromJson(json);
}

/// One row of `GET /v1/auth/sessions`.
@freezed
abstract class SessionItem with _$SessionItem {
  const factory SessionItem({
    required String id,
    required String kind,
    required DateTime createdAt,
    required DateTime lastUsedAt,
    required bool current,
    SessionDevice? device,
  }) = _SessionItem;

  factory SessionItem.fromJson(Map<String, dynamic> json) =>
      _$SessionItemFromJson(json);
}

/// `GET /v1/auth/sessions`.
@freezed
abstract class SessionList with _$SessionList {
  const factory SessionList({
    @Default(<SessionItem>[]) List<SessionItem> items,
  }) = _SessionList;

  factory SessionList.fromJson(Map<String, dynamic> json) =>
      _$SessionListFromJson(json);
}
