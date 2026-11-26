import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../push/local_notification_gateway.dart';
import '../push/plugin_local_notification_gateway.dart';

/// What the reminder says, in the person's language.
class PendingReminderText {
  const PendingReminderText({
    required this.channelName,
    required this.title,
    required this.body,
  });

  final String channelName;
  final String title;
  final String body;
}

/// Reminds the person twice a day (10:00 and 18:00 on the phone's clock) while a
/// trusted contact has not accepted the invitation yet, and stops once nobody is pending.
/// Scheduled on the phone, so it works without the server; Home keeps it in step.
abstract interface class PendingContactReminder {
  Future<void> sync({required bool pending, required PendingReminderText text});
}

const int _morningId = 0x0B01;
const int _eveningId = 0x0B02;
const String _channelId = 'contact_reminders';

/// A tap opens Home (an unknown push type), where the notifications section is.
const String pendingReminderPayload = 'contact_pending_reminder';

class PluginPendingContactReminder implements PendingContactReminder {
  PluginPendingContactReminder({
    required this.local,
    FlutterLocalNotificationsPlugin? plugin,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final LocalNotificationGateway local;
  final FlutterLocalNotificationsPlugin _plugin;

  /// What is scheduled now, so Home can call [sync] on every refresh cheaply.
  bool? _scheduled;

  @override
  Future<void> sync({
    required bool pending,
    required PendingReminderText text,
  }) async {
    if (_scheduled == pending) {
      return;
    }
    try {
      await local.initialize();
      await _plugin.cancel(id: _morningId);
      await _plugin.cancel(id: _eveningId);
      if (pending) {
        await _daily(_morningId, 10, text);
        await _daily(_eveningId, 18, text);
      }
      _scheduled = pending;
    } on Object {
      // Not on Android (tests), or the system refused: the notifications section on
      // Home still shows who has not accepted.
    }
  }

  Future<void> _daily(int id, int hour, PendingReminderText text) async {
    final now = DateTime.now();
    var at = DateTime(now.year, now.month, now.day, hour);
    if (!at.isAfter(now)) {
      at = at.add(const Duration(days: 1));
    }
    await _plugin.zonedSchedule(
      id: id,
      title: text.title,
      body: text.body,
      payload: pendingReminderPayload,
      scheduledDate: tz.TZDateTime.from(at.toUtc(), tz.UTC),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      // Repeats every day at the same time.
      matchDateTimeComponents: DateTimeComponents.time,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          text.channelName,
          importance: Importance.high,
          priority: Priority.high,
          icon: PluginLocalNotificationGateway.iconName,
        ),
      ),
    );
  }
}

final pendingContactReminderProvider = Provider<PendingContactReminder>(
  (ref) => PluginPendingContactReminder(
    local: ref.watch(localNotificationGatewayProvider),
  ),
);
