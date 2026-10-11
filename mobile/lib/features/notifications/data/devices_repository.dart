import 'package:flutter/foundation.dart';

import '../../../core/device/device_info_source.dart';

/// What `PUT /v1/devices/current` does with the push token (API_SPEC.md §4).
///
/// The three cases are three different bodies: leaving `push_token` out keeps the token
/// the server has, a string registers it, and `null` removes it.
@immutable
sealed class PushTokenChange {
  const PushTokenChange();
}

/// Say nothing about the token: only the device facts are refreshed.
final class KeepPushToken extends PushTokenChange {
  const KeepPushToken();
}

/// Register [token] for this device.
final class SetPushToken extends PushTokenChange {
  const SetPushToken(this.token);

  final String token;

  /// A token is not for logs.
  @override
  String toString() => 'SetPushToken(<redacted>)';
}

/// This device no longer receives pushes (notifications turned off).
final class RemovePushToken extends PushTokenChange {
  const RemovePushToken();
}

/// The body of `PUT /v1/devices/current`: the device's facts, plus `push_token` as
/// [token] says (omitted, a string, or `null`).
Map<String, Object?> deviceUpdateBody(
  DeviceDescriptor device,
  PushTokenChange token,
) => <String, Object?>{
  ...device.toJson(),
  ...switch (token) {
    KeepPushToken() => const <String, Object?>{},
    SetPushToken(:final token) => <String, Object?>{'push_token': token},
    RemovePushToken() => const <String, Object?>{'push_token': null},
  },
};

/// The server's answer: which device this is and whether it now has a push token. The
/// token itself is never echoed back.
@immutable
class DeviceRegistration {
  const DeviceRegistration({
    required this.deviceId,
    required this.pushRegistered,
  });

  /// Throws a [FormatException] for an answer that is not this shape.
  factory DeviceRegistration.fromJson(Map<String, dynamic> json) {
    final id = json['device_id'];
    final registered = json['push_registered'];
    if (id is! String || id.isEmpty || registered is! bool) {
      throw const FormatException('Not a device registration');
    }
    return DeviceRegistration(deviceId: id, pushRegistered: registered);
  }

  final String deviceId;
  final bool pushRegistered;
}

/// The FCM token as the server accepts it: printable ASCII without spaces, 20 to 4096
/// characters (`^[\x21-\x7e]{20,4096}$`). A token outside that would only be refused (422),
/// so it is not sent.
bool isAcceptablePushToken(String token) =>
    RegExp(r'^[\x21-\x7e]{20,4096}$').hasMatch(token);

/// Everything the app does with the devices endpoints (API_SPEC.md §4).
///
/// Methods complete normally on success and throw an `AppFailure` otherwise. Nothing here
/// logs a body: it carries the push token.
abstract interface class DevicesRepository {
  /// `PUT /v1/devices/current`: the device's facts and what to do with the push token.
  Future<DeviceRegistration> update(
    DeviceDescriptor device,
    PushTokenChange token,
  );

  /// `DELETE /v1/devices/current/push-token`: the person turned notifications off.
  Future<void> deletePushToken();
}
