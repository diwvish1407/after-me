import 'dart:async';

import 'package:afterme/core/device/device_info_source.dart';
import 'package:afterme/core/push/local_notification_gateway.dart';
import 'package:afterme/core/push/push_gateway.dart';
import 'package:afterme/features/notifications/data/devices_repository.dart';

/// A scriptable [PushGateway]: a push service that is configured or not, a token that can
/// be had or not, and streams the test pushes into.
class FakePushGateway implements PushGateway {
  FakePushGateway({this.configured = false, this.currentToken = defaultToken});

  /// A token the server accepts (20 to 4096 printable characters, no spaces).
  static const String defaultToken = 'fcm-token-aaaaaaaaaaaaaaaaaaaaaaaa';

  /// Whether the build carries a Firebase app. False by default, so the rest of the
  /// app's tests never register a token.
  bool configured;

  /// What Firebase starts with.
  bool starts = true;

  /// The token FCM gives; null when it cannot be had.
  String? currentToken;

  /// Whether deleting the token works (false: offline).
  bool deleteWorks = true;

  /// The token FCM hands out after the old one was deleted (null: none until asked).
  String? tokenAfterDelete;

  /// What [initialMessage] returns (once).
  IncomingPush? initial;

  /// Every call, in order: `init`, `token`, `delete`.
  final List<String> calls = [];

  /// Shared with other fakes to compare the order of calls across them.
  List<String>? events;

  /// While set, [token] waits for it (a request that is on its way).
  Completer<void>? tokenGate;

  // The streams live as long as the test: there is nothing to close them for.
  // ignore: close_sinks
  final StreamController<IncomingPush> foreground =
      StreamController<IncomingPush>.broadcast();
  // ignore: close_sinks
  final StreamController<IncomingPush> opened =
      StreamController<IncomingPush>.broadcast();
  // ignore: close_sinks
  final StreamController<String> refreshes =
      StreamController<String>.broadcast();

  int get tokenReads => calls.where((c) => c == 'token').length;
  int get deletes => calls.where((c) => c == 'delete').length;

  /// A new token from FCM.
  void refreshToken(String token) {
    currentToken = token;
    refreshes.add(token);
  }

  @override
  bool get isConfigured => configured;

  @override
  Future<bool> ensureInitialized() async {
    calls.add('init');
    return configured && starts;
  }

  @override
  Future<String?> token() async {
    calls.add('token');
    events?.add('push.token');
    final gate = tokenGate;
    if (gate != null) {
      await gate.future;
    }
    return configured && starts ? currentToken : null;
  }

  @override
  Stream<String> get tokenRefreshes => refreshes.stream;

  @override
  Future<bool> deleteToken() async {
    calls.add('delete');
    events?.add('push.deleteToken');
    if (!deleteWorks) {
      return false;
    }
    currentToken = tokenAfterDelete;
    tokenAfterDelete = null;
    return true;
  }

  @override
  Stream<IncomingPush> get foregroundMessages => foreground.stream;

  @override
  Stream<IncomingPush> get openedMessages => opened.stream;

  @override
  Future<IncomingPush?> initialMessage() async {
    final message = initial;
    initial = null;
    return message;
  }
}

/// A [LocalNotificationGateway] that records what the app put on screen.
class FakeLocalNotificationGateway implements LocalNotificationGateway {
  int initializations = 0;
  List<NotificationChannelSpec> channels = const [];
  final List<LocalNotification> shown = [];

  /// The payload of the notification that started the app (once).
  String? launch;

  /// Makes [show] throw, like a plugin that fails.
  bool showThrows = false;

  // ignore: close_sinks
  final StreamController<String> tapController =
      StreamController<String>.broadcast();

  /// The person taps a notification the app showed.
  void tap(String payload) => tapController.add(payload);

  @override
  Future<void> initialize() async => initializations++;

  @override
  Future<void> ensureChannels(List<NotificationChannelSpec> channels) async =>
      this.channels = channels;

  @override
  Future<void> show(LocalNotification notification) async {
    if (showThrows) {
      throw StateError('plugin failed');
    }
    shown.add(notification);
  }

  @override
  Stream<String> get taps => tapController.stream;

  @override
  Future<String?> launchPayload() async {
    final payload = launch;
    launch = null;
    return payload;
  }
}

/// A [DevicesRepository] that records the bodies it was given, as they would be on the
/// wire, and fails on request.
class FakeDevicesRepository implements DevicesRepository {
  /// Every `PUT`, as sent.
  final List<Map<String, Object?>> puts = [];

  /// How many `DELETE .../push-token` were made.
  int deletes = 0;

  /// Failures to answer with (any object is thrown as it is), one per call, in order;
  /// success once it is empty.
  final List<Object> failures = [];

  /// While set, a call waits for it (a request that is on its way).
  Completer<void>? gate;

  /// Shared with other fakes to compare the order of calls across them.
  List<String>? events;

  /// The token of the last successful `PUT` that set one.
  String? registeredToken;

  @override
  Future<DeviceRegistration> update(
    DeviceDescriptor device,
    PushTokenChange token,
  ) async {
    final body = deviceUpdateBody(device, token);
    puts.add(body);
    events?.add('devices.put');
    final pending = gate;
    if (pending != null) {
      await pending.future;
    }
    if (failures.isNotEmpty) {
      throw failures.removeAt(0);
    }
    switch (token) {
      case SetPushToken(:final token):
        registeredToken = token;
      case RemovePushToken():
        registeredToken = null;
      case KeepPushToken():
        break;
    }
    return DeviceRegistration(
      deviceId: 'device-1',
      pushRegistered: registeredToken != null,
    );
  }

  @override
  Future<void> deletePushToken() async {
    deletes++;
    registeredToken = null;
  }
}
