import 'dart:async';

import 'package:afterme/core/config/app_config.dart';
import 'package:afterme/core/push/firebase_push_gateway.dart';
import 'package:afterme/core/push/push_gateway.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_messaging_platform_interface/firebase_messaging_platform_interface.dart'
    as platform;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// What the phone's Firebase core does: no app was started natively (the build has no
/// google-services.json), and an app started from Dart is kept with the options it was
/// given.
class _CoreHost implements TestFirebaseCoreHostApi {
  final List<CoreFirebaseOptions> started = [];
  bool failToStart = false;

  @override
  Future<CoreInitializeResponse> initializeApp(
    String appName,
    CoreFirebaseOptions initializeAppRequest,
  ) async {
    if (failToStart) {
      throw PlatformException(code: 'internal', message: 'boom');
    }
    started.add(initializeAppRequest);
    return CoreInitializeResponse(
      name: appName,
      options: initializeAppRequest,
      pluginConstants: <String, Object?>{},
    );
  }

  @override
  Future<List<CoreInitializeResponse>> initializeCore() async => [];

  @override
  Future<CoreFirebaseOptions> optionsFromResource() async =>
      throw PlatformException(code: 'not-found');
}

/// Firebase Messaging as the platform side answers it.
class _Messaging extends platform.FirebaseMessagingPlatform
    with MockPlatformInterfaceMixin {
  final List<String> calls = [];
  String? token = 'fcm-token-aaaaaaaaaaaaaaaaaaaaaaaa';
  bool getTokenThrows = false;
  bool deleteThrows = false;
  bool autoInit = false;
  RemoteMessage? initial;
  bool initialThrows = false;
  platform.BackgroundMessageHandler? registered;
  // ignore: close_sinks
  final StreamController<String> refreshes =
      StreamController<String>.broadcast();

  @override
  platform.FirebaseMessagingPlatform delegateFor({required FirebaseApp app}) =>
      this;

  @override
  platform.FirebaseMessagingPlatform setInitialValues({
    bool? isAutoInitEnabled,
  }) => this;

  @override
  void registerBackgroundMessageHandler(
    platform.BackgroundMessageHandler handler,
  ) {
    calls.add('register');
    registered = handler;
  }

  @override
  Future<void> setAutoInitEnabled(bool enabled) async {
    calls.add('autoInit=$enabled');
    autoInit = enabled;
  }

  @override
  Future<String?> getToken({
    String? vapidKey,
    String? serviceWorkerScriptPath,
  }) async {
    calls.add('getToken');
    if (getTokenThrows) {
      throw StateError('SERVICE_NOT_AVAILABLE');
    }
    return token;
  }

  @override
  Future<void> deleteToken() async {
    calls.add('deleteToken');
    if (deleteThrows) {
      throw StateError('offline');
    }
  }

  @override
  Stream<String> get onTokenRefresh => refreshes.stream;

  @override
  Future<RemoteMessage?> getInitialMessage() async {
    if (initialThrows) {
      throw StateError('nope');
    }
    final message = initial;
    initial = null;
    return message;
  }
}

// The values of a Firebase app: identifiers, not secrets.
const _settings = FirebaseSettings(
  apiKey: 'api-key-for-the-test',
  appId: '1:123456789:android:abcdef',
  messagingSenderId: '123456789',
  projectId: 'afterme-test',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final core = _CoreHost();
  final messaging = _Messaging();

  setUpAll(() {
    TestFirebaseCoreHostApi.setUp(core);
    platform.FirebaseMessagingPlatform.instance = messaging;
  });

  tearDownAll(() => TestFirebaseCoreHostApi.setUp(null));

  setUp(() {
    messaging.calls.clear();
    messaging.token = 'fcm-token-aaaaaaaaaaaaaaaaaaaaaaaa';
    messaging.getTokenThrows = false;
    messaging.deleteThrows = false;
    messaging.initial = null;
    messaging.initialThrows = false;
  });

  group('without a Firebase app in the build', () {
    final gateway = FirebasePushGateway(settings: null);

    test('it says so and every call is a quiet no-op', () async {
      expect(gateway.isConfigured, isFalse);
      expect(await gateway.ensureInitialized(), isFalse);
      expect(await gateway.token(), isNull);
      expect(await gateway.initialMessage(), isNull);
      expect(await gateway.tokenRefreshes.isEmpty, isTrue);
      expect(await gateway.foregroundMessages.isEmpty, isTrue);
      expect(await gateway.openedMessages.isEmpty, isTrue);
      // There is no token of this build to delete: that is done.
      expect(await gateway.deleteToken(), isTrue);
      expect(core.started, isEmpty);
      expect(messaging.calls, isEmpty);
    });
  });

  group('starting Firebase by hand', () {
    test('a start that fails is false, and can be tried again', () async {
      final gateway = FirebasePushGateway(settings: _settings);
      core.failToStart = true;
      expect(gateway.isConfigured, isTrue);
      expect(await gateway.ensureInitialized(), isFalse);
      expect(await gateway.token(), isNull);
      expect(
        await gateway.deleteToken(),
        isFalse,
        reason: 'it could not be done',
      );
      expect(await gateway.initialMessage(), isNull);

      core.failToStart = false;
      expect(await gateway.ensureInitialized(), isTrue);
    });

    test('the options come from the build, once, and the background handler is '
        'registered', () async {
      final gateway = FirebasePushGateway(settings: _settings);
      core.started.clear();
      messaging.calls.clear();
      // Another start in the same process has the default app already: it is reused.
      expect(await gateway.ensureInitialized(), isTrue);
      expect(await gateway.ensureInitialized(), isTrue);
      expect(messaging.registered, same(afterMeBackgroundMessageHandler));
      expect(
        platform.FirebaseMessagingPlatform.onBackgroundMessage,
        same(afterMeBackgroundMessageHandler),
      );
      expect(Firebase.app().options.apiKey, _settings.apiKey);
      expect(Firebase.app().options.appId, _settings.appId);
      expect(
        Firebase.app().options.messagingSenderId,
        _settings.messagingSenderId,
      );
      expect(Firebase.app().options.projectId, _settings.projectId);
    });

    test(
      'an app started with other options is a conflict that is not fatal',
      () async {
        final gateway = FirebasePushGateway(
          settings: const FirebaseSettings(
            apiKey: 'another-key',
            appId: '1:1:android:1',
            messagingSenderId: '1',
            projectId: 'another',
          ),
        );
        expect(await gateway.ensureInitialized(), isTrue);
      },
    );

    test('the background handler does nothing', () async {
      await afterMeBackgroundMessageHandler(
        const RemoteMessage(data: {'type': 'incident_missed', 'v': '1'}),
      );
      expect(messaging.calls, isEmpty);
    });
  });

  group('the token', () {
    test('turns FCM on and asks for it', () async {
      final gateway = FirebasePushGateway(settings: _settings);
      expect(await gateway.token(), 'fcm-token-aaaaaaaaaaaaaaaaaaaaaaaa');
      expect(messaging.calls.where((c) => c != 'register'), [
        'autoInit=true',
        'getToken',
      ]);
      expect(messaging.autoInit, isTrue);
    });

    test('nothing, an empty token or a failure is null', () async {
      final gateway = FirebasePushGateway(settings: _settings);
      messaging.token = null;
      expect(await gateway.token(), isNull);
      messaging.token = '';
      expect(await gateway.token(), isNull);
      messaging.getTokenThrows = true;
      expect(await gateway.token(), isNull);
    });

    test('deleting it turns FCM off first, then deletes', () async {
      final gateway = FirebasePushGateway(settings: _settings);
      expect(await gateway.deleteToken(), isTrue);
      messaging.calls.clear();
      expect(await gateway.deleteToken(), isTrue);
      expect(messaging.calls, ['autoInit=false', 'deleteToken']);
      expect(messaging.autoInit, isFalse);
    });

    test('a token that cannot be deleted (offline) says so', () async {
      final gateway = FirebasePushGateway(settings: _settings);
      messaging.deleteThrows = true;
      expect(await gateway.deleteToken(), isFalse);
    });

    test('a new token is passed on', () async {
      final gateway = FirebasePushGateway(settings: _settings);
      final seen = <String>[];
      final subscription = gateway.tokenRefreshes.listen(seen.add);
      await pumpEventQueue();
      messaging.refreshes.add('fcm-token-bbbbbbbbbbbbbbbbbbbbbbbb');
      await pumpEventQueue();
      await subscription.cancel();
      expect(seen, ['fcm-token-bbbbbbbbbbbbbbbbbbbbbbbb']);
    });
  });

  group('messages', () {
    const incident = RemoteMessage(
      data: <String, dynamic>{
        'type': 'incident_missed',
        'v': '1',
        'incident_id': '11111111-1111-4111-8111-111111111111',
        'count': 3,
      },
      notification: RemoteNotification(
        title: 'You missed your check-in',
        body: "Tap I'M OK to stop the reminders.",
        android: AndroidNotification(
          channelId: 'reminders',
          tag: 'incident_missed',
        ),
      ),
      senderId: 'sender',
      from: 'topic',
      messageId: 'm1',
    );

    void expectIncident(IncomingPush push) {
      expect(push.data, {
        'type': 'incident_missed',
        'v': '1',
        'incident_id': '11111111-1111-4111-8111-111111111111',
      }, reason: 'only strings are taken from the data');
      expect(push.title, 'You missed your check-in');
      expect(push.body, "Tap I'M OK to stop the reminders.");
      expect(push.channelId, 'reminders');
    }

    test('one that arrives in the foreground', () async {
      final gateway = FirebasePushGateway(settings: _settings);
      final seen = <IncomingPush>[];
      final subscription = gateway.foregroundMessages.listen(seen.add);
      await pumpEventQueue();
      platform.FirebaseMessagingPlatform.onMessage.add(incident);
      await pumpEventQueue();
      await subscription.cancel();
      expect(seen, hasLength(1));
      expectIncident(seen.single);
    });

    test('one that was tapped while the app was in the background', () async {
      final gateway = FirebasePushGateway(settings: _settings);
      final seen = <IncomingPush>[];
      final subscription = gateway.openedMessages.listen(seen.add);
      await pumpEventQueue();
      platform.FirebaseMessagingPlatform.onMessageOpenedApp.add(incident);
      await pumpEventQueue();
      await subscription.cancel();
      expectIncident(seen.single);
    });

    test('one that started the app, once', () async {
      final gateway = FirebasePushGateway(settings: _settings);
      messaging.initial = incident;
      expectIncident((await gateway.initialMessage())!);
      expect(await gateway.initialMessage(), isNull);
    });

    test('an initial message that cannot be read is none', () async {
      final gateway = FirebasePushGateway(settings: _settings);
      messaging.initialThrows = true;
      expect(await gateway.initialMessage(), isNull);
    });

    test(
      'a message without a notification has no text and no channel',
      () async {
        final gateway = FirebasePushGateway(settings: _settings);
        final seen = <IncomingPush>[];
        final subscription = gateway.foregroundMessages.listen(seen.add);
        await pumpEventQueue();
        platform.FirebaseMessagingPlatform.onMessage.add(
          const RemoteMessage(data: {'type': 'incident_missed', 'v': '1'}),
        );
        await pumpEventQueue();
        await subscription.cancel();
        expect(seen.single.title, isNull);
        expect(seen.single.body, isNull);
        expect(seen.single.channelId, isNull);
      },
    );
  });
}
