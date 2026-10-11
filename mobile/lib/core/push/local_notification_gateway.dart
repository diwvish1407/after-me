import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notification_channel.dart';
import 'plugin_local_notification_gateway.dart';

/// A channel as Android shows it in the system settings: a calm name and one sentence
/// that says what arrives on it. Nothing about the person is ever in either.
@immutable
class NotificationChannelSpec {
  const NotificationChannelSpec({
    required this.channel,
    required this.name,
    required this.description,
  });

  final NotificationChannel channel;
  final String name;
  final String description;
}

/// A notification the app itself puts on screen (a push that arrived while the app is in
/// the foreground; the system shows none for it).
///
/// [title] and [body] are the text the server sent, never text the app composes from what
/// it knows (no names, no times). [payload] is only the message's type.
@immutable
class LocalNotification {
  const LocalNotification({
    required this.id,
    required this.channel,
    required this.title,
    required this.body,
    required this.payload,
  });

  /// Stable per kind, so a second push of the same kind replaces the first instead of
  /// piling up (the server's own pushes do the same with their `tag`).
  final int id;

  final NotificationChannel channel;
  final String title;
  final String body;

  /// What a tap on the notification hands back: the push's `type`, nothing else.
  final String payload;

  @override
  String toString() => 'LocalNotification(<redacted>)';
}

/// The app's only contact with the local-notifications plugin and with the creation of the
/// notification channels.
///
/// Like the push gateway it holds no decisions: what to show and where a tap goes is
/// decided above, in plain Dart.
abstract interface class LocalNotificationGateway {
  /// Prepares the plugin (once) and starts listening for taps. Never throws.
  Future<void> initialize();

  /// Creates the channels (or refreshes their name and description). A channel that
  /// exists keeps the importance the person gave it. Never throws.
  Future<void> ensureChannels(List<NotificationChannelSpec> channels);

  /// Puts [notification] on screen, private on the lock screen, on its channel. Never
  /// throws.
  Future<void> show(LocalNotification notification);

  /// The payload of every local notification the person taps while the app is running.
  Stream<String> get taps;

  /// The payload of the local notification that started the app from nothing, once;
  /// null otherwise.
  Future<String?> launchPayload();
}

/// The plugin implementation. Tests override this with a fake.
final localNotificationGatewayProvider = Provider<LocalNotificationGateway>(
  (ref) => PluginLocalNotificationGateway(),
);
