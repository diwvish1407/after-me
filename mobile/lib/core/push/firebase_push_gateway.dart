import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../config/app_config.dart';
import 'push_gateway.dart';

/// Runs in its own isolate when a message arrives while the app is in the background or
/// closed, and **does nothing**.
///
/// The server sends *notification* messages, which the system shows by itself (on the
/// channel, with the private lock-screen visibility and the generic text the message
/// carries). Nothing the app could do here would be safer than leaving it to the system:
/// a push is only a hint (SECURITY.md T21), so no state is read, no request is made and
/// nothing is stored, logged or decided from the payload. The app reads its state from the
/// API when it is opened.
///
/// It is a top-level function with the entry-point pragma because the plugin starts it by
/// handle in a release build.
@pragma('vm:entry-point')
Future<void> afterMeBackgroundMessageHandler(RemoteMessage message) async {}

/// [PushGateway] on `firebase_core` and `firebase_messaging`.
///
/// Firebase is started **by hand** from the build's `FIREBASE_*` values: the build has no
/// `google-services.json` and no google-services Gradle plugin. Without those values the
/// gateway reports [isConfigured] false and every method is a quiet no-op.
///
/// Nothing here is logged: a token and a payload are not for logs.
class FirebasePushGateway implements PushGateway {
  FirebasePushGateway({required this.settings});

  final FirebaseSettings? settings;

  Future<bool>? _initialising;

  @override
  bool get isConfigured => settings != null;

  @override
  Future<bool> ensureInitialized() {
    final running = _initialising;
    if (running != null) {
      return running;
    }
    final future = _initialize();
    _initialising = future;
    // A failed start may be tried again later; a good one is kept.
    return future.then((started) {
      if (!started && identical(_initialising, future)) {
        _initialising = null;
      }
      return started;
    });
  }

  Future<bool> _initialize() async {
    final settings = this.settings;
    if (settings == null) {
      return false;
    }
    try {
      try {
        await Firebase.initializeApp(
          options: FirebaseOptions(
            apiKey: settings.apiKey,
            appId: settings.appId,
            messagingSenderId: settings.messagingSenderId,
            projectId: settings.projectId,
          ),
        );
      } on FirebaseException catch (error) {
        // The same app was started already (a hot restart, say): it is usable.
        if (error.code != 'duplicate-app') {
          rethrow;
        }
      }
      FirebaseMessaging.onBackgroundMessage(afterMeBackgroundMessageHandler);
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<String?> token() async {
    if (!await ensureInitialized()) {
      return null;
    }
    try {
      final messaging = FirebaseMessaging.instance;
      // FCM stays idle (the manifest turns auto-init off) until the person is signed in
      // and has allowed notifications: this is the moment it starts.
      await messaging.setAutoInitEnabled(true);
      final token = await messaging.getToken();
      return token == null || token.isEmpty ? null : token;
    } on Object {
      return null;
    }
  }

  @override
  Stream<String> get tokenRefreshes async* {
    if (await ensureInitialized()) {
      yield* FirebaseMessaging.instance.onTokenRefresh;
    }
  }

  @override
  Future<bool> deleteToken() async {
    if (!await ensureInitialized()) {
      // Never started on this run: there is no token of this run to delete.
      return !isConfigured;
    }
    try {
      final messaging = FirebaseMessaging.instance;
      // Off first, so FCM does not hand out a new token the moment this one is gone.
      await messaging.setAutoInitEnabled(false);
      await messaging.deleteToken();
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Stream<IncomingPush> get foregroundMessages async* {
    if (await ensureInitialized()) {
      yield* FirebaseMessaging.onMessage.map(_convert);
    }
  }

  @override
  Stream<IncomingPush> get openedMessages async* {
    if (await ensureInitialized()) {
      yield* FirebaseMessaging.onMessageOpenedApp.map(_convert);
    }
  }

  @override
  Future<IncomingPush?> initialMessage() async {
    if (!await ensureInitialized()) {
      return null;
    }
    try {
      final message = await FirebaseMessaging.instance.getInitialMessage();
      return message == null ? null : _convert(message);
    } on Object {
      return null;
    }
  }

  /// Only strings are taken from the data (FCM data values are strings), and only the
  /// notification's text and channel: nothing else of the message is kept.
  static IncomingPush _convert(RemoteMessage message) {
    final data = <String, String>{
      for (final entry in message.data.entries)
        if (entry.value is String) entry.key: entry.value as String,
    };
    final notification = message.notification;
    return IncomingPush(
      data: data,
      title: notification?.title,
      body: notification?.body,
      channelId: notification?.android?.channelId,
    );
  }
}
