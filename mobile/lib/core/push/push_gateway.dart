import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import 'firebase_push_gateway.dart';

/// A push message as the app sees it: strings only, and nothing of Firebase.
///
/// A push is **a hint** (SECURITY.md T21): the app reads [data] `type` (and `v`) to decide
/// what to show and where a tap goes, and fetches everything else from the API. [title] and
/// [body] are the server's generic text; the app never composes text of its own from what
/// it knows.
@immutable
class IncomingPush {
  const IncomingPush({
    this.data = const <String, String>{},
    this.title,
    this.body,
    this.channelId,
  });

  /// The message's data payload (`type`, `v`, `incident_id?`).
  final Map<String, String> data;

  /// The notification's generic title and text, when the message carried a
  /// notification.
  final String? title;
  final String? body;

  /// The Android channel the server asked for.
  final String? channelId;

  /// Never prints the content: a push does not belong in a log (only its type may be).
  @override
  String toString() => 'IncomingPush(<redacted>)';
}

/// The app's only contact with Firebase Cloud Messaging.
///
/// Everything above this interface (the token's life, what is shown, where a tap goes) is
/// plain Dart and fully tested with a fake; the Firebase adapter
/// ([FirebasePushGateway]) is a thin wrapper that holds no decisions.
///
/// The system permission is **not** here: the notification permission gateway
/// (`core/permissions`) is the one place that knows it, so Home's "notifications are off"
/// banner, Settings and the token's life can never disagree.
abstract interface class PushGateway {
  /// Whether the build carries a Firebase app (`FIREBASE_*` values). Without one nothing
  /// below does anything, and the app says so calmly.
  bool get isConfigured;

  /// Starts Firebase (once). False when push is not configured or Firebase could not
  /// start; never throws.
  Future<bool> ensureInitialized();

  /// This phone's FCM registration token, or null when it cannot be had right now.
  /// Allows FCM to run (auto-init on), which stays off until the person is signed in.
  /// Never throws.
  Future<String?> token();

  /// A new token, whenever FCM issues one.
  Stream<String> get tokenRefreshes;

  /// Deletes the token on this phone and keeps FCM idle until [token] is asked for
  /// again. True when the token is gone (or there was none to delete), false when it
  /// could not be deleted now (offline): the caller tries again later. Never throws.
  Future<bool> deleteToken();

  /// A message that arrived while the app is in the foreground (the system shows
  /// nothing for it).
  Stream<IncomingPush> get foregroundMessages;

  /// A notification the person tapped while the app was in the background.
  Stream<IncomingPush> get openedMessages;

  /// The notification the person tapped to start the app from nothing, once; null
  /// otherwise.
  Future<IncomingPush?> initialMessage();
}

/// The Firebase implementation, configured from the build. Tests override this with a
/// fake.
final pushGatewayProvider = Provider<PushGateway>(
  (ref) => FirebasePushGateway(settings: ref.watch(appConfigProvider).firebase),
);
