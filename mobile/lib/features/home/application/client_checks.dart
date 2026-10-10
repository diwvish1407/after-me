import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/device/device_info_source.dart';
import '../../../core/permissions/notification_permission.dart';

/// What the phone says about readiness: whether notifications are off and the phone's
/// timezone. Both reads already exist in the app (the notification pre-prompt and the
/// profile's timezone suggestion); this only looks, it never asks for anything.
class ClientChecks {
  const ClientChecks({
    this.notifications = NotificationPermission.unknown,
    this.deviceTimezone,
  });

  final NotificationPermission notifications;

  /// The phone's IANA timezone, or null when it cannot be read.
  final String? deviceTimezone;

  /// Known to be off (not merely unknown).
  bool get notificationsOff =>
      notifications == NotificationPermission.denied ||
      notifications == NotificationPermission.permanentlyDenied;
}

class ClientChecksController extends Notifier<ClientChecks> {
  @override
  ClientChecks build() => const ClientChecks();

  /// Reads the notification permission and the phone's timezone again.
  Future<void> refresh() async {
    var notifications = NotificationPermission.unknown;
    try {
      notifications = await ref
          .read(notificationPermissionGatewayProvider)
          .status();
    } on Object {
      // Unknown: no banner for something that could not be read.
    }
    String? timezone;
    try {
      timezone = await ref.read(deviceInfoSourceProvider).timezone();
    } on Object {
      // Unknown, as above.
    }
    if (ref.mounted) {
      state = ClientChecks(
        notifications: notifications,
        deviceTimezone: timezone,
      );
    }
  }
}

final clientChecksProvider =
    NotifierProvider<ClientChecksController, ClientChecks>(
      ClientChecksController.new,
    );
