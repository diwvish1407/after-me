import 'package:material_ui/material_ui.dart';

import '../../../core/design_system/design_system.dart';
import '../../../core/permissions/notification_permission.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../onboarding/presentation/notification_prompt.dart';

/// Settings > Notifications: the system permission and what is always on.
class NotificationsSettingsScreen extends StatelessWidget {
  const NotificationsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return FormPage(
      title: l10n.settingsNotifications,
      children: [
        const NotificationPrompt(),
        Gap.lg,
        StatusBanner(
          kind: StatusBannerKind.info,
          message: l10n.notificationsEmailAlways,
        ),
      ],
    );
  }
}

/// The text for a permission status, shared by the settings and onboarding screens.
String notificationStatusText(
  AppLocalizations l10n,
  NotificationPermission status,
) => switch (status) {
  NotificationPermission.granted => l10n.notificationsStatusOn,
  NotificationPermission.denied => l10n.notificationsStatusOff,
  NotificationPermission.permanentlyDenied => l10n.notificationsStatusBlocked,
  NotificationPermission.unknown => l10n.notificationsStatusUnknown,
};
