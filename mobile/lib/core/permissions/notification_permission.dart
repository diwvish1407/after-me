import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../security/app_lock/app_lock_controller.dart';
import '../storage/preferences_store.dart';

/// Where the notification permission stands (Android 13+ asks; earlier versions
/// always allow).
enum NotificationPermission {
  /// Not read yet.
  unknown,
  granted,

  /// Not granted, but the system dialog can still be shown.
  denied,

  /// The system will not ask again; only the system settings can change it.
  permanentlyDenied,
}

/// The app's only contact with the permission plugin.
abstract interface class NotificationPermissionGateway {
  Future<NotificationPermission> status();

  /// Shows the system dialog (Android 13+) and returns the new status.
  Future<NotificationPermission> request();

  /// Opens the app's page in the system settings.
  Future<bool> openSettings();
}

class PlatformNotificationPermissionGateway
    implements NotificationPermissionGateway {
  const PlatformNotificationPermissionGateway();

  static NotificationPermission _map(PermissionStatus status) =>
      switch (status) {
        PermissionStatus.granted ||
        PermissionStatus.limited ||
        PermissionStatus.provisional => NotificationPermission.granted,
        PermissionStatus.permanentlyDenied ||
        PermissionStatus.restricted => NotificationPermission.permanentlyDenied,
        PermissionStatus.denied => NotificationPermission.denied,
      };

  @override
  Future<NotificationPermission> status() async =>
      _map(await Permission.notification.status);

  @override
  Future<NotificationPermission> request() async =>
      _map(await Permission.notification.request());

  @override
  Future<bool> openSettings() => openAppSettings();
}

final notificationPermissionGatewayProvider =
    Provider<NotificationPermissionGateway>(
      (ref) => const PlatformNotificationPermissionGateway(),
    );

@immutable
class NotificationPermissionState {
  const NotificationPermissionState({
    this.status = NotificationPermission.unknown,
    this.busy = false,
  });

  final NotificationPermission status;
  final bool busy;
}

/// The notification permission and its pre-prompt (USER_FLOWS.md §3 step 8).
///
/// The screen explains first; only [request] shows the system dialog. The outcome
/// is stored (a status name) so the app knows the person has been asked. No push
/// registration happens here: that is Phase 8.
class NotificationPermissionController
    extends Notifier<NotificationPermissionState> {
  NotificationPermissionGateway get _gateway =>
      ref.read(notificationPermissionGatewayProvider);

  @override
  NotificationPermissionState build() => const NotificationPermissionState();

  /// Reads the current status (also after returning from system settings).
  Future<void> refresh() async {
    final status = await _safe(_gateway.status);
    if (ref.mounted) {
      state = NotificationPermissionState(status: status);
    }
  }

  /// Shows the system dialog.
  Future<NotificationPermission> request() async {
    if (state.busy) {
      return state.status;
    }
    state = NotificationPermissionState(status: state.status, busy: true);
    // The dialog is a separate activity: do not let it count as leaving the app.
    final status = await ref
        .read(appLockControllerProvider.notifier)
        .runWithoutLocking(() => _safe(_gateway.request));
    if (!ref.mounted) {
      return status;
    }
    state = NotificationPermissionState(status: status);
    try {
      await ref
          .read(preferencesStoreProvider)
          .setString(PreferenceKey.notificationPermissionResult, status.name);
    } on Object {
      // Remembering the answer is a convenience.
    }
    return status;
  }

  /// Opens the app's system settings page.
  ///
  /// Not wrapped in `runWithoutLocking`: opening settings returns as soon as the
  /// activity is launched, so a wrapper would end before the app actually leaves the
  /// foreground and suppress nothing. Coming back follows the normal lock timeout.
  Future<void> openSystemSettings() async {
    await _gateway.openSettings();
  }

  Future<NotificationPermission> _safe(
    Future<NotificationPermission> Function() read,
  ) async {
    try {
      return await read();
    } on Object {
      return NotificationPermission.denied;
    }
  }
}

final notificationPermissionControllerProvider =
    NotifierProvider<
      NotificationPermissionController,
      NotificationPermissionState
    >(NotificationPermissionController.new);
