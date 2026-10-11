import '../../../core/push/local_notification_gateway.dart';
import '../../../core/push/notification_channel.dart';
import '../../../l10n/gen/app_localizations.dart';

/// The calm name Android and the Settings screen show for a channel.
String channelName(AppLocalizations l10n, NotificationChannel channel) =>
    switch (channel) {
      NotificationChannel.reminders => l10n.notificationChannelRemindersName,
      NotificationChannel.incidents => l10n.notificationChannelIncidentsName,
      NotificationChannel.account => l10n.notificationChannelAccountName,
    };

/// The one sentence that says what arrives on a channel.
String channelDescription(
  AppLocalizations l10n,
  NotificationChannel channel,
) => switch (channel) {
  NotificationChannel.reminders => l10n.notificationChannelRemindersDescription,
  NotificationChannel.incidents => l10n.notificationChannelIncidentsDescription,
  NotificationChannel.account => l10n.notificationChannelAccountDescription,
};

/// The three channels with their words, in the order Settings lists them.
List<NotificationChannelSpec> notificationChannelSpecs(AppLocalizations l10n) =>
    [
      for (final channel in NotificationChannel.values)
        NotificationChannelSpec(
          channel: channel,
          name: channelName(l10n, channel),
          description: channelDescription(l10n, channel),
        ),
    ];
