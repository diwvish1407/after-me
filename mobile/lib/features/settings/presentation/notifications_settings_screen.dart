import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/permissions/notification_permission.dart';
import '../../../core/push/notification_channel.dart';
import '../../../core/push/push_gateway.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../notifications/presentation/channel_labels.dart';
import '../../onboarding/presentation/notification_prompt.dart';

/// Settings > Notifications: the system permission, what arrives on which channel, what is
/// lost when notifications are off, and what a notification never contains.
///
/// Emails about a missed check-in are always on (USER_FLOWS.md §11): the screen says so,
/// so turning notifications off is never a worry about the plan itself.
class NotificationsSettingsScreen extends ConsumerWidget {
  const NotificationsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final configured = ref.watch(pushGatewayProvider).isConfigured;
    return FormPage(
      title: l10n.settingsNotifications,
      children: [
        const NotificationPrompt(),
        if (!configured) ...[
          Gap.md,
          StatusBanner(
            kind: StatusBannerKind.info,
            message: l10n.notificationsNotConfigured,
          ),
        ],
        Gap.md,
        SectionCard(
          title: l10n.notificationsWhatTitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BodyText(l10n.notificationsWhatBody),
              for (final channel in NotificationChannel.values) ...[
                Gap.sm,
                _ChannelRow(channel: channel),
              ],
            ],
          ),
        ),
        Gap.md,
        SectionCard(
          title: l10n.notificationsLostTitle,
          child: Text(l10n.notificationsLostBody),
        ),
        Gap.md,
        StatusBanner(
          kind: StatusBannerKind.info,
          message: l10n.notificationsEmailAlways,
        ),
        Gap.md,
        BodyText(l10n.notificationsPrivateBody),
      ],
    );
  }
}

/// One channel: its name and what arrives on it, read as one item.
class _ChannelRow extends StatelessWidget {
  const _ChannelRow({required this.channel});

  final NotificationChannel channel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(channelName(l10n, channel), style: textTheme.titleSmall),
          Text(
            channelDescription(l10n, channel),
            style: textTheme.bodyMedium?.copyWith(
              color: context.tokens.textMuted,
            ),
          ),
        ],
      ),
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
