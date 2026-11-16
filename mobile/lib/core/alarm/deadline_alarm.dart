import 'dart:typed_data';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../push/local_notification_gateway.dart';
import '../push/plugin_local_notification_gateway.dart';

/// What the alarm says, in the person's language.
class DeadlineAlarmText {
  const DeadlineAlarmText({
    required this.channelName,
    required this.channelDescription,
    required this.title,
    required this.body,
  });

  final String channelName;
  final String channelDescription;
  final String title;
  final String body;
}

/// A loud alarm on the phone at the check-in deadline, so the person hears it in time to
/// tap I'M OK.
///
/// The deadline always comes from the server (`next_due_at`); the phone never computes
/// one. Whether anyone is told is still decided by the server alone: this alarm only
/// wakes the person up. There is one alarm at a time: setting a new deadline replaces
/// the old one.
abstract interface class DeadlineAlarm {
  /// Sets the alarm for [at] (device time), replacing any earlier one. A time in the past
  /// cancels instead.
  Future<void> set(DateTime at, DeadlineAlarmText text);

  /// Removes the alarm (check-ins off, signed out).
  Future<void> cancel();

  /// Whether Android lets the app ring at the exact minute ("Alarms & reminders").
  Future<bool> canRingOnTime();

  /// Opens the system page where the person allows exact alarms.
  Future<void> askToRingOnTime();
}

/// The id of the one alarm notification. Server pushes use other ids.
const int deadlineAlarmId = 0x0A1A;

/// The tap payload: an unknown push type, so a tap opens Home (where I'M OK is).
const String deadlineAlarmPayload = 'checkin_alarm';

/// The notification channel of the alarm: an alarm sound that plays in silent mode.
const String deadlineAlarmChannelId = 'checkin_alarm';

/// FLAG_INSISTENT: the sound repeats until the notification is opened or dismissed.
const int _flagInsistent = 4;

class PluginDeadlineAlarm implements DeadlineAlarm {
  PluginDeadlineAlarm({
    required this.local,
    FlutterLocalNotificationsPlugin? plugin,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// The gateway owns the plugin's initialisation (and the tap callback).
  final LocalNotificationGateway local;
  LocalNotificationGateway get _local => local;

  final FlutterLocalNotificationsPlugin _plugin;

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  @override
  Future<void> set(DateTime at, DeadlineAlarmText text) async {
    try {
      // The gateway owns the plugin's initialisation (and the tap callback).
      await _local.initialize();
      await _plugin.cancel(id: deadlineAlarmId);
      if (!at.isAfter(DateTime.now())) {
        return;
      }
      final exact = await canRingOnTime();
      await _plugin.zonedSchedule(
        id: deadlineAlarmId,
        title: text.title,
        body: text.body,
        payload: deadlineAlarmPayload,
        scheduledDate: tz.TZDateTime.from(at.toUtc(), tz.UTC),
        androidScheduleMode: exact
            ? AndroidScheduleMode.alarmClock
            : AndroidScheduleMode.inexactAllowWhileIdle,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            deadlineAlarmChannelId,
            text.channelName,
            channelDescription: text.channelDescription,
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.alarm,
            audioAttributesUsage: AudioAttributesUsage.alarm,
            sound: const UriAndroidNotificationSound(
              'content://settings/system/alarm_alert',
            ),
            fullScreenIntent: true,
            visibility: NotificationVisibility.private,
            additionalFlags: Int32List.fromList([_flagInsistent]),
            icon: PluginLocalNotificationGateway.iconName,
          ),
        ),
      );
    } on Object {
      // Not on Android (tests), or the system refused. The server's reminders and
      // emails still reach the person; the alarm is extra.
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _local.initialize();
      await _plugin.cancel(id: deadlineAlarmId);
    } on Object {
      // Nothing was set.
    }
  }

  @override
  Future<bool> canRingOnTime() async {
    try {
      return await _android?.canScheduleExactNotifications() ?? false;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> askToRingOnTime() async {
    try {
      await _android?.requestExactAlarmsPermission();
    } on Object {
      // The page could not be opened.
    }
  }
}

final deadlineAlarmProvider = Provider<DeadlineAlarm>(
  (ref) =>
      PluginDeadlineAlarm(local: ref.watch(localNotificationGatewayProvider)),
);
