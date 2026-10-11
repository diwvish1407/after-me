import 'package:flutter/foundation.dart';

import '../../../app/router.dart';
import '../../../core/push/notification_channel.dart';
import '../../../core/push/push_gateway.dart';

/// The only version of the push data format this app reads (`data.v`).
const String supportedPushVersion = '1';

/// Where a tap on a notification goes (`opens` in
/// `docs/contracts/phase8/push_payloads.json`).
enum PushDestination {
  /// The Home tab: I'M OK, I'M SAFE, the status.
  home,

  /// The People tab.
  people;

  /// The route. Fixed paths only: nothing from a message ever becomes part of one.
  String get location => switch (this) {
    PushDestination.home => AppRoutes.home,
    PushDestination.people => AppRoutes.people,
  };

  /// The destination named by [opens], or null when it is not one of ours.
  static PushDestination? fromWire(String? opens) {
    for (final destination in PushDestination.values) {
      if (destination.name == opens) {
        return destination;
      }
    }
    return null;
  }
}

/// Every kind of push the server sends (`data.type`), with the channel it arrives on and
/// where a tap on it goes.
///
/// A type this version of the app does not know is **ignored** when it arrives in the
/// foreground and **opens Home** when it is tapped: it is still an AfterMe notification
/// the person chose to open, and Home is the calm place that has I'M OK.
/// `test/contracts/phase8_contract_test.dart` reads the server's list
/// (`push_payloads.json`) and fails when it names a type that is not here.
enum PushType {
  checkinPreReminder(
    'checkin_pre_reminder',
    NotificationChannel.reminders,
    PushDestination.home,
  ),
  incidentMissed(
    'incident_missed',
    NotificationChannel.reminders,
    PushDestination.home,
  ),
  incidentMidpoint(
    'incident_midpoint',
    NotificationChannel.reminders,
    PushDestination.home,
  ),
  incidentLastChance(
    'incident_last_chance',
    NotificationChannel.reminders,
    PushDestination.home,
  ),
  incidentDelayed(
    'incident_delayed',
    NotificationChannel.reminders,
    PushDestination.home,
  ),
  stageExecuted(
    'stage_executed',
    NotificationChannel.incidents,
    PushDestination.home,
  ),
  releaseFinalWarning(
    'release_final_warning',
    NotificationChannel.incidents,
    PushDestination.home,
  ),
  allClearConfirmation(
    'all_clear_confirmation',
    NotificationChannel.incidents,
    PushDestination.home,
  ),
  serviceInterruption(
    'service_interruption',
    NotificationChannel.incidents,
    PushDestination.home,
  ),
  contactUnreachable(
    'contact_unreachable',
    NotificationChannel.account,
    PushDestination.people,
  );

  const PushType(this.wire, this.channel, this.destination);

  /// The `data.type` value.
  final String wire;

  /// The channel the server sends this type on.
  final NotificationChannel channel;

  final PushDestination destination;

  /// The type named [wire], or null when this version does not know it.
  static PushType? fromWire(String? wire) {
    for (final type in PushType.values) {
      if (type.wire == wire) {
        return type;
      }
    }
    return null;
  }

  /// A stable notification id per type, so a second push of a kind replaces the first.
  int get notificationId => 7000 + index;
}

/// A push this app version understands: a known `type` in the one format it reads.
@immutable
class PushMessage {
  const PushMessage({
    required this.type,
    required this.channel,
    this.incidentId,
    this.title,
    this.body,
  });

  /// Reads [push], or returns null for anything that is not a message to act on: no
  /// type, an unknown type, or another version of the format. Nothing is guessed: such a
  /// message is ignored, calmly.
  static PushMessage? tryParse(IncomingPush push) {
    final type = PushType.fromWire(push.data['type']);
    if (type == null || push.data['v'] != supportedPushVersion) {
      return null;
    }
    return PushMessage(
      type: type,
      // The server names the channel; a name that is not one of ours means this type's own.
      channel: NotificationChannel.fromId(push.channelId) ?? type.channel,
      incidentId: _incidentId(push.data['incident_id']),
      title: _text(push.title),
      body: _text(push.body),
    );
  }

  final PushType type;
  final NotificationChannel channel;

  /// The incident the message is about, when it is shaped like an id. A push never
  /// carries anything the app trusts: Home is read again from the API.
  final String? incidentId;

  /// The server's generic text. Null when the message carried none.
  final String? title;
  final String? body;

  /// Whether there is something to show.
  bool get hasText => (title ?? '').isNotEmpty || (body ?? '').isNotEmpty;

  /// Only the type: a message is not for logs.
  @override
  String toString() => 'PushMessage(${type.wire})';

  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static String? _incidentId(String? raw) =>
      raw != null && _uuid.hasMatch(raw) ? raw : null;

  static String? _text(String? raw) {
    final trimmed = raw?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

/// Where a tap on a notification with [data] goes. A known type goes where the server's
/// table says; anything else (no type, an unknown type, another format version) opens
/// Home.
PushDestination tapDestination(Map<String, String> data) =>
    PushMessage.tryParse(IncomingPush(data: data))?.type.destination ??
    PushDestination.home;
