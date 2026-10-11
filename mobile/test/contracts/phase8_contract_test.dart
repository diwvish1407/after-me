@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/failures/failure_mapper.dart';
import 'package:afterme/core/device/device_info_source.dart';
import 'package:afterme/core/push/notification_channel.dart';
import 'package:afterme/core/push/push_gateway.dart';
import 'package:afterme/features/notifications/application/push_message.dart';
import 'package:afterme/features/notifications/data/devices_repository.dart';
import 'package:afterme/features/notifications/data/dio_devices_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/api_wire.dart';
import '../helpers/fake_http_adapter.dart';

/// The backend writes example requests and responses for every Phase 8 endpoint to
/// docs/contracts/phase8 (generated and compared by a backend test), and, in
/// `push_payloads.json`, the `message` it sends to FCM for each kind of push. Those files
/// are the source of truth: the app must send what the golden requests show, read what the
/// golden responses contain, map every problem file, and know every push type the server
/// lists (a type it does not know opens Home, and this test says which ones those are).
///
/// The files are in the repository root; `flutter test` runs from `mobile/`. Golden files
/// are read-only here.
final Directory _dir = Directory('../docs/contracts/phase8');

bool get _present => File('${_dir.path}/index.json').existsSync();

Map<String, dynamic> _json(String file) =>
    jsonDecode(File('${_dir.path}/$file').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  if (!_present) {
    test(
      'phase 8 golden files',
      () {},
      skip:
          'docs/contracts/phase8/index.json does not exist yet: the backend '
          'half of Phase 8 writes it (make contracts).',
    );
    return;
  }

  late Map<String, dynamic> index;
  late List<Map<String, dynamic>> endpoints;
  late List<Map<String, dynamic>> problems;

  setUpAll(() {
    index = _json('index.json');
    endpoints = (index['endpoints'] as List).cast<Map<String, dynamic>>();
    problems = ((index['problems'] ?? const <Object?>[]) as List)
        .cast<Map<String, dynamic>>();
  });

  Map<String, dynamic> endpoint(String name) =>
      endpoints.singleWhere((e) => e['name'] == name);

  /// The device facts of a golden request, as the app would have read them.
  DeviceDescriptor deviceOf(Map<String, dynamic> request) => DeviceDescriptor(
    platform: request['platform'] as String,
    appVersion: request['app_version'] as String,
    osVersion: request['os_version'] as String,
    locale: request['locale'] as String,
  );

  FakeReply replyFor(Map<String, dynamic> e) {
    final response = e['response'] as String?;
    return FakeReply.json(
      e['status'] as int,
      response == null ? null : _json(response),
    );
  }

  test('the index names the contract and the four device calls', () {
    expect(index['contract'], 'afterme-phase8');
    expect(index['base_path'], '/v1');
    expect(
      {for (final e in endpoints) '${e['method']} ${e['path']}'},
      {'PUT /v1/devices/current', 'DELETE /v1/devices/current/push-token'},
    );
    expect(
      {for (final e in endpoints) e['name']},
      {
        'device_register',
        'device_keep_token',
        'device_remove_token',
        'device_push_token_delete',
      },
    );
  });

  test('every file is in the index (or is the push payloads) and is JSON', () {
    final referenced = <String>{'index.json', 'push_payloads.json'};
    for (final e in [...endpoints, ...problems]) {
      for (final key in ['request', 'response']) {
        final file = e[key] as String?;
        if (file != null) {
          referenced.add(file);
          expect(File('${_dir.path}/$file').existsSync(), isTrue, reason: file);
        }
      }
    }
    final onDisk = _dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.json'))
        .toSet();
    expect(onDisk.difference(referenced), isEmpty, reason: 'unlisted files');
    for (final name in onDisk) {
      expect(_json(name), isA<Map<String, dynamic>>(), reason: name);
    }
  });

  group('devices', () {
    test('registering the token sends the facts and the token', () async {
      final e = endpoint('device_register');
      final request = _json(e['request'] as String);
      final wire = await apiWire((_, _) => replyFor(e));
      final registration = await DioDevicesRepository(dio: wire.dio).update(
        deviceOf(request),
        SetPushToken(request['push_token'] as String),
      );
      expect(wire.request.method, 'PUT');
      expect(wire.request.path, '/v1/devices/current');
      expect(wire.request.bearer, isNotNull);
      expect(wire.body, request);
      final response = _json(e['response'] as String);
      expect(registration.deviceId, response['device_id']);
      expect(registration.pushRegistered, isTrue);
      expect(isAcceptablePushToken(request['push_token'] as String), isTrue);
    });

    test('keeping the token leaves push_token out of the body', () async {
      final e = endpoint('device_keep_token');
      final request = _json(e['request'] as String);
      expect(request.containsKey('push_token'), isFalse);
      final wire = await apiWire((_, _) => replyFor(e));
      final registration = await DioDevicesRepository(dio: wire.dio)
          .update(deviceOf(request), const KeepPushToken());
      expect(wire.body, request);
      expect(wire.body.containsKey('push_token'), isFalse);
      expect(registration.pushRegistered, isTrue);
    });

    test('removing the token sends an explicit null', () async {
      final e = endpoint('device_remove_token');
      final request = _json(e['request'] as String);
      expect(request.containsKey('push_token'), isTrue);
      expect(request['push_token'], isNull);
      final wire = await apiWire((_, _) => replyFor(e));
      final registration = await DioDevicesRepository(dio: wire.dio)
          .update(deviceOf(request), const RemovePushToken());
      expect(wire.body, request);
      expect(wire.body.containsKey('push_token'), isTrue);
      expect(registration.pushRegistered, isFalse);
    });

    test('turning notifications off by the delete route', () async {
      final e = endpoint('device_push_token_delete');
      expect(e['status'], 204);
      final wire = await apiWire((_, _) => replyFor(e));
      await DioDevicesRepository(dio: wire.dio).deletePushToken();
      expect(wire.request.method, 'DELETE');
      expect(wire.request.path, '/v1/devices/current/push-token');
      expect(wire.request.bearer, isNotNull);
    });

    test('the refused token is a field error the app can read, and the app '
        'would not have sent it', () async {
      final p = problems.singleWhere(
        (p) => p['name'] == 'problem_device_bad_token',
      );
      final request = _json(p['request'] as String);
      final golden = _json(p['response'] as String);
      expect(isAcceptablePushToken(request['push_token'] as String), isFalse);

      final wire = await apiWire(
        (_, _) => FakeReply.raw(
          golden['status'] as int,
          jsonEncode(golden),
          'application/problem+json',
        ),
      );
      Object? caught;
      try {
        await DioDevicesRepository(dio: wire.dio).update(
          deviceOf(request),
          SetPushToken(request['push_token'] as String),
        );
      } on Object catch (error) {
        caught = toAppFailure(error);
      }
      expect(caught, isA<ValidationFailure>());
      final failure = caught! as ValidationFailure;
      expect(failure.fieldErrors.single.field, 'push_token');
      expect(failure.fieldErrors.single.code, 'invalid_format');
      expect(failure.requestId, golden['request_id']);
    });

    test(
      'an answer that is not a device is an unknown failure, not a crash',
      () async {
        for (final body in <Object?>[
          <String, Object?>{},
          <String, Object?>{'device_id': 'd', 'push_registered': 'yes'},
          <Object?>[],
        ]) {
          final wire = await apiWire((_, _) => FakeReply.json(200, body));
          await expectLater(
            DioDevicesRepository(dio: wire.dio).update(
              const DeviceDescriptor(
                appVersion: '1.0.0+1',
                osVersion: '15',
                locale: 'en',
              ),
              const KeepPushToken(),
            ),
            throwsA(isA<UnknownFailure>()),
            reason: '$body',
          );
        }
      },
    );

    test('a token is never printed', () {
      expect(
        '${const SetPushToken('fcm-token-secret-aaaaaaaaaaaa')}',
        isNot(contains('secret')),
      );
    });
  });

  group('push payloads', () {
    late Map<String, dynamic> file;
    late List<Map<String, dynamic>> payloads;

    setUpAll(() {
      file = _json('push_payloads.json');
      payloads = (file['payloads'] as List).cast<Map<String, dynamic>>();
    });

    test('the file is the one this app reads: contract and version', () {
      expect(file['contract'], 'afterme-phase8');
      expect(file['version'], 1);
      expect(payloads, isNotEmpty);
      expect(
        {for (final p in payloads) p['type']},
        hasLength(payloads.length),
        reason: 'one entry per type',
      );
    });

    test('every type the server sends is a type this app knows', () {
      final unknown = [
        for (final p in payloads)
          if (PushType.fromWire(p['type'] as String) == null) p['type'],
      ];
      expect(
        unknown,
        isEmpty,
        reason:
            'the server sends a push type that has no mapping in the app: it '
            'would open Home and be ignored in the foreground. Add it to PushType.',
      );
    });

    test('and the app knows no type the server does not send', () {
      expect(
        {for (final type in PushType.values) type.wire},
        {for (final p in payloads) p['type']},
      );
    });

    test('a tap goes where the file says it opens', () {
      for (final p in payloads) {
        final message = p['message'] as Map<String, dynamic>;
        final data = (message['data'] as Map).cast<String, String>();
        expect(data['type'], p['type']);
        expect(
          tapDestination(data).name,
          p['opens'],
          reason: '${p['type']} opens ${p['opens']}',
        );
        expect(PushDestination.fromWire(p['opens'] as String), isNotNull);
      }
    });

    test('every payload is in the version the app reads, with a private '
        'lock-screen visibility and a channel of ours', () {
      for (final p in payloads) {
        final message = p['message'] as Map<String, dynamic>;
        final data = (message['data'] as Map).cast<String, String>();
        final notification =
            (message['android'] as Map<String, dynamic>)['notification']
                as Map<String, dynamic>;
        final type = PushType.fromWire(p['type'] as String)!;
        expect(data['v'], supportedPushVersion, reason: '${p['type']}');
        expect(notification['visibility'], 'PRIVATE', reason: '${p['type']}');
        expect(
          notification['channel_id'],
          type.channel.id,
          reason: '${p['type']}',
        );
        expect(
          NotificationChannel.fromId(notification['channel_id'] as String),
          isNotNull,
        );
      }
    });

    test('a payload is read into the message the app shows', () {
      for (final p in payloads) {
        final message = p['message'] as Map<String, dynamic>;
        final data = (message['data'] as Map).cast<String, String>();
        final notification = message['notification'] as Map<String, dynamic>;
        final android =
            (message['android'] as Map<String, dynamic>)['notification']
                as Map<String, dynamic>;
        final parsed = PushMessage.tryParse(
          IncomingPush(
            data: data,
            title: notification['title'] as String,
            body: notification['body'] as String,
            channelId: android['channel_id'] as String,
          ),
        )!;
        expect(parsed.type.wire, p['type']);
        expect(parsed.title, notification['title']);
        expect(parsed.body, notification['body']);
        expect(parsed.channel.id, android['channel_id']);
        expect(parsed.incidentId, data['incident_id']);
        expect(parsed.hasText, isTrue);
      }
    });

    test('nothing in a payload carries a name or a time of day', () {
      // The server's generic text (SECURITY T21, FR-NOT-04): no person, no clock time.
      final clock = RegExp(r'\d{1,2}:\d{2}');
      for (final p in payloads) {
        final notification =
            (p['message'] as Map<String, dynamic>)['notification']
                as Map<String, dynamic>;
        final text = '${notification['title']} ${notification['body']}';
        expect(clock.hasMatch(text), isFalse, reason: text);
        expect(
          (p['message'] as Map<String, dynamic>)['data'],
          isNot(contains('name')),
        );
      }
    });
  });
}
