import 'package:afterme/core/push/local_notification_gateway.dart';
import 'package:afterme/core/push/notification_channel.dart';
import 'package:afterme/core/push/plugin_local_notification_gateway.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

/// The adapter over `flutter_local_notifications` and the channel creation of
/// `MainActivity`, against mocked method channels: what is sent to the platform is what
/// the foreground copy of a push must be (the channel, a private visibility, the server's
/// words and only the type as the payload).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pluginChannel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  const channelsChannel = MethodChannel('app.afterme/notification_channels');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final pluginCalls = <MethodCall>[];
  final channelCalls = <MethodCall>[];
  Object? launchDetails;
  bool pluginThrows = false;
  bool channelsThrow = false;

  setUp(() {
    // The plugin registers itself on a device; in a test it is done by hand.
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    pluginCalls.clear();
    channelCalls.clear();
    launchDetails = null;
    pluginThrows = false;
    channelsThrow = false;
    messenger.setMockMethodCallHandler(pluginChannel, (call) async {
      pluginCalls.add(call);
      if (pluginThrows) {
        throw PlatformException(code: 'boom');
      }
      return switch (call.method) {
        'initialize' => true,
        'getNotificationAppLaunchDetails' => launchDetails,
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(channelsChannel, (call) async {
      channelCalls.add(call);
      if (channelsThrow) {
        throw PlatformException(code: 'failed');
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(pluginChannel, null);
    messenger.setMockMethodCallHandler(channelsChannel, null);
  });

  const specs = [
    NotificationChannelSpec(
      channel: NotificationChannel.reminders,
      name: 'Check-in reminders',
      description: 'A reminder before a check-in is due.',
    ),
    NotificationChannelSpec(
      channel: NotificationChannel.incidents,
      name: 'Alerts about your plan',
      description: 'Tells you when your contacts were told.',
    ),
    NotificationChannelSpec(
      channel: NotificationChannel.account,
      name: 'Account notices',
      description: 'Things about your account.',
    ),
  ];

  group('the channels', () {
    test('are created natively, with their words and importance', () async {
      final gateway = PluginLocalNotificationGateway();
      await gateway.ensureChannels(specs);
      final call = channelCalls.single;
      expect(call.method, 'ensureChannels');
      expect(call.arguments, {
        'channels': [
          {
            'id': 'reminders',
            'name': 'Check-in reminders',
            'description': 'A reminder before a check-in is due.',
            'importance': 'high',
          },
          {
            'id': 'incidents',
            'name': 'Alerts about your plan',
            'description': 'Tells you when your contacts were told.',
            'importance': 'high',
          },
          {
            'id': 'account',
            'name': 'Account notices',
            'description': 'Things about your account.',
            'importance': 'default',
          },
        ],
      });
    });

    test('a refusal or a missing platform is not an error', () async {
      final gateway = PluginLocalNotificationGateway();
      channelsThrow = true;
      await gateway.ensureChannels(specs);
      messenger.setMockMethodCallHandler(channelsChannel, null);
      await gateway.ensureChannels(specs);
    });
  });

  group('showing a push that arrived in the foreground', () {
    test(
      'uses its channel, a private visibility and the server\'s words',
      () async {
        final gateway = PluginLocalNotificationGateway();
        await gateway.ensureChannels(specs);
        await gateway.show(
          const LocalNotification(
            id: 7005,
            channel: NotificationChannel.incidents,
            title: 'Your contacts have been notified',
            body: "If you're safe, open AfterMe and tap I'M SAFE.",
            payload: 'stage_executed',
          ),
        );
        final call = pluginCalls.singleWhere((c) => c.method == 'show');
        final args = call.arguments as Map;
        expect(args['id'], 7005);
        expect(args['title'], 'Your contacts have been notified');
        expect(args['body'], "If you're safe, open AfterMe and tap I'M SAFE.");
        expect(args['payload'], 'stage_executed');
        final details = args['platformSpecifics'] as Map;
        expect(details['channelId'], 'incidents');
        expect(details['channelName'], 'Alerts about your plan');
        expect(
          details['channelDescription'],
          'Tells you when your contacts were told.',
        );
        expect(details['tag'], 'stage_executed');
        expect(details['icon'], 'ic_stat_afterme');
        expect(
          details['visibility'],
          NotificationVisibility.private.index,
          reason: 'the lock screen shows nothing of it',
        );
        expect(details['importance'], Importance.high.value);
        expect(details['priority'], Priority.high.value);
      },
    );

    test('the calm channel is a default importance', () async {
      final gateway = PluginLocalNotificationGateway();
      await gateway.show(
        const LocalNotification(
          id: 7009,
          channel: NotificationChannel.account,
          title: 'A contact could not be reached',
          body: 'Open AfterMe to see who and what to do.',
          payload: 'contact_unreachable',
        ),
      );
      final details =
          (pluginCalls.single.arguments as Map)['platformSpecifics'] as Map;
      expect(details['channelId'], 'account');
      expect(
        details['channelName'],
        'account',
        reason: 'until the words are known',
      );
      expect(details['importance'], Importance.defaultImportance.value);
    });

    test('a plugin that fails is not an error', () async {
      final gateway = PluginLocalNotificationGateway();
      pluginThrows = true;
      await gateway.show(
        const LocalNotification(
          id: 1,
          channel: NotificationChannel.reminders,
          title: 't',
          body: 'b',
          payload: 'incident_missed',
        ),
      );
    });

    test('a notification prints nothing of what it says', () {
      const notification = LocalNotification(
        id: 1,
        channel: NotificationChannel.reminders,
        title: 'A secret title',
        body: 'A secret body',
        payload: 'incident_missed',
      );
      expect('$notification', isNot(contains('secret')));
    });
  });

  group('a tap', () {
    test(
      'on a notification of the running app hands back its payload',
      () async {
        final gateway = PluginLocalNotificationGateway();
        await gateway.initialize();
        await gateway.initialize();
        expect(
          pluginCalls.where((c) => c.method == 'initialize'),
          hasLength(1),
          reason: 'once',
        );
        final initialize = pluginCalls.singleWhere(
          (c) => c.method == 'initialize',
        );
        expect((initialize.arguments as Map)['defaultIcon'], 'ic_stat_afterme');

        final taps = <String>[];
        final subscription = gateway.taps.listen(taps.add);
        Future<void> deliver(String? payload) =>
            messenger.handlePlatformMessage(
              pluginChannel.name,
              const StandardMethodCodec().encodeMethodCall(
                MethodCall('didReceiveNotificationResponse', <String, Object?>{
                  'notificationId': 7001,
                  'actionId': null,
                  'input': null,
                  'payload': payload,
                  'notificationResponseType': 0,
                }),
              ),
              (_) {},
            );
        await deliver('incident_missed');
        await deliver(null);
        await deliver('');
        await pumpEventQueue();
        await subscription.cancel();
        expect(taps, ['incident_missed']);
      },
    );

    test(
      'that started the app hands back the payload once the plugin says so',
      () async {
        final gateway = PluginLocalNotificationGateway();
        launchDetails = <String, Object?>{
          'notificationLaunchedApp': true,
          'notificationResponse': <String, Object?>{
            'notificationId': 7009,
            'actionId': null,
            'input': null,
            'notificationResponseType': 0,
            'payload': 'contact_unreachable',
          },
        };
        expect(await gateway.launchPayload(), 'contact_unreachable');
      },
    );

    test('nothing launched it, or nothing came back, is null', () async {
      final gateway = PluginLocalNotificationGateway();
      launchDetails = null;
      expect(await gateway.launchPayload(), isNull);
      launchDetails = <String, Object?>{'notificationLaunchedApp': false};
      expect(await gateway.launchPayload(), isNull);
      launchDetails = <String, Object?>{
        'notificationLaunchedApp': true,
        'notificationResponse': <String, Object?>{
          'notificationId': 1,
          'notificationResponseType': 0,
          'payload': '',
        },
      };
      expect(await gateway.launchPayload(), isNull);
      pluginThrows = true;
      expect(await gateway.launchPayload(), isNull);
    });

    test('a plugin that cannot start is not an error', () async {
      final gateway = PluginLocalNotificationGateway();
      pluginThrows = true;
      await gateway.initialize();
    });
  });
}
