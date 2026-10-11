import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'local_notification_gateway.dart';
import 'notification_channel.dart';

/// [LocalNotificationGateway] on `flutter_local_notifications`, plus a small method
/// channel to `MainActivity` for creating the channels with a private lock-screen
/// visibility (the plugin cannot set it on a channel).
///
/// Only the foreground display and the tap come from the plugin. It schedules nothing and
/// asks for no permission: the permission has its own gateway, and reminders come from the
/// server, never from an alarm on the phone.
class PluginLocalNotificationGateway implements LocalNotificationGateway {
  PluginLocalNotificationGateway({
    FlutterLocalNotificationsPlugin? plugin,
    MethodChannel? channels,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _channels = channels ?? const MethodChannel(channelsChannelName);

  /// Handled by `MainActivity` (`ensureChannels`).
  static const String channelsChannelName = 'app.afterme/notification_channels';

  /// The drawable of the small icon (`res/drawable/ic_stat_afterme.xml`).
  static const String iconName = 'ic_stat_afterme';

  final FlutterLocalNotificationsPlugin _plugin;
  final MethodChannel _channels;

  final StreamController<String> _taps = StreamController<String>.broadcast();
  final Map<NotificationChannel, NotificationChannelSpec> _specs = {};
  Future<void>? _initialising;

  @override
  Stream<String> get taps => _taps.stream;

  @override
  Future<void> initialize() => _initialising ??= _initialize();

  Future<void> _initialize() async {
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings(iconName),
        ),
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (payload != null && payload.isNotEmpty) {
            _taps.add(payload);
          }
        },
      );
    } on Object {
      // Foreground display is a convenience; the system shows everything else.
    }
  }

  @override
  Future<void> ensureChannels(List<NotificationChannelSpec> channels) async {
    for (final spec in channels) {
      _specs[spec.channel] = spec;
    }
    try {
      await _channels.invokeMethod<void>('ensureChannels', <String, Object?>{
        'channels': [
          for (final spec in channels)
            <String, Object?>{
              'id': spec.channel.id,
              'name': spec.name,
              'description': spec.description,
              'importance':
                  spec.channel.importance == NotificationImportance.high
                  ? 'high'
                  : 'default',
            },
        ],
      });
    } on Object {
      // Not on Android (tests, previews), or the system refused: the plugin creates a
      // channel by itself on first use, with the same name and importance.
    }
  }

  @override
  Future<void> show(LocalNotification notification) async {
    final spec = _specs[notification.channel];
    final high = notification.channel.importance == NotificationImportance.high;
    try {
      await _plugin.show(
        id: notification.id,
        title: notification.title,
        body: notification.body,
        payload: notification.payload,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            notification.channel.id,
            spec?.name ?? notification.channel.id,
            channelDescription: spec?.description,
            importance: high ? Importance.high : Importance.defaultImportance,
            priority: high ? Priority.high : Priority.defaultPriority,
            visibility: NotificationVisibility.private,
            tag: notification.payload,
            icon: iconName,
          ),
        ),
      );
    } on Object {
      // Not shown: the data is on screen in the app anyway.
    }
  }

  @override
  Future<String?> launchPayload() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details == null || !details.didNotificationLaunchApp) {
        return null;
      }
      final payload = details.notificationResponse?.payload;
      return payload == null || payload.isEmpty ? null : payload;
    } on Object {
      return null;
    }
  }
}
