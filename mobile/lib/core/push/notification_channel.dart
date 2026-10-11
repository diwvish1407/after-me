/// The three Android notification channels of the app (ARCHITECTURE.md §5.7).
///
/// A channel is what lets the person silence one kind of notification without silencing
/// another: reminders can be turned off while alerts about the plan stay on. The ids are
/// the ones the server names in `android.notification.channel_id`
/// (`docs/contracts/phase8/push_payloads.json`).
enum NotificationChannel {
  /// A check-in is due soon, was missed, or the deadline was moved.
  reminders('reminders', NotificationImportance.high),

  /// Contacts were told, something is about to be shared, an all clear was sent, or the
  /// service had a problem.
  incidents('incidents', NotificationImportance.high),

  /// A trusted contact could not be reached, and other things about the account.
  account('account', NotificationImportance.standard);

  const NotificationChannel(this.id, this.importance);

  /// The channel id, as the server and Android know it.
  final String id;

  final NotificationImportance importance;

  /// The channel named [id], or null when it is none of ours.
  static NotificationChannel? fromId(String? id) {
    for (final channel in NotificationChannel.values) {
      if (channel.id == id) {
        return channel;
      }
    }
    return null;
  }
}

/// How loudly a channel's notifications arrive. `high` shows a heads-up notification,
/// `standard` is the calm default.
enum NotificationImportance { high, standard }
