import 'dart:async';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/core/push/push_gateway.dart';
import 'package:afterme/features/notifications/application/push_registration_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_http_adapter.dart';
import '../../helpers/http_world.dart';
import '../../helpers/test_app.dart';

/// A token and a push are not for logs, URLs, headers, preferences or any state of the
/// app: the token goes in the body of one request and in the Keystore-backed store, and a
/// message's words are shown and forgotten.
const _token = 'fcm-token-LEAKCHECK-aaaaaaaaaaaaaaaaaaaa';
const _title = 'LEAKTITLE-You missed your check-in';
const _body = 'LEAKBODY-Tap I\'M OK to stop the reminders.';
const _incident = '99999999-9999-4999-8999-999999999999';

void main() {
  testWidgets('no token and no message is in a log, a URL, a header or a '
      'preference', (tester) async {
    final printed = <String>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
    final errors = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await runZoned(
        () async {
          final fakes = TestFakes()
            ..realDevicesRepository = true
            ..realPushNavigation = true;
          fakes.push
            ..configured = true
            ..currentToken = _token;
          fakes.notifications.current = NotificationPermission.granted;
          var puts = 0;
          final world = await openHttpApp(
            tester,
            fakes: fakes,
            routes: {
              'PUT /v1/devices/current': (request) {
                puts++;
                // The first answer is a refusal, so the failure paths run too.
                return puts == 1
                    ? FakeReply.problem(
                        422,
                        'validation_failed',
                        extra: {
                          'errors': [
                            {
                              'field': 'push_token',
                              'code': 'invalid_format',
                              'message': 'String should match pattern',
                            },
                          ],
                        },
                      )
                    : const FakeReply.json(200, {
                        'device_id': 'device-1',
                        'push_registered': true,
                      });
              },
            },
          );

          // A push in the foreground, one that is ignored, a tap, and a new token.
          fakes.push.foreground.add(
            const IncomingPush(
              data: {
                'type': 'incident_missed',
                'v': '1',
                'incident_id': _incident,
              },
              title: _title,
              body: _body,
              channelId: 'reminders',
            ),
          );
          fakes.push.foreground.add(
            const IncomingPush(
              data: {'type': 'unknown_type', 'v': '1', 'secret': _title},
              title: _title,
              body: _body,
            ),
          );
          fakes.push.opened.add(
            const IncomingPush(
              data: {'type': 'incident_missed', 'v': '1'},
              title: _title,
              body: _body,
            ),
          );
          fakes.push.refreshToken('${_token}2');
          await tester.pumpAndSettle();
          world.container
              .read(routerProvider)
              .go(AppRoutes.settingsNotifications);
          await tester.pumpAndSettle();

          expect(fakes.localNotifications.shown, hasLength(1));
          expect(puts, greaterThanOrEqualTo(2));

          // Nothing printed, however the failure was handled.
          final output = [...printed, ...errors.map((e) => '$e')].join('\n');
          for (final secret in [
            'LEAKCHECK',
            'LEAKTITLE',
            'LEAKBODY',
            _incident,
          ]) {
            expect(output, isNot(contains(secret)), reason: secret);
          }

          // The token is in the body of the device request, nowhere else on the wire.
          final requests = world.adapter.requests;
          for (final request in requests) {
            expect(request.uri.toString(), isNot(contains('LEAK')));
            expect(request.headers.toString(), isNot(contains('LEAK')));
            if (request.method == 'PUT' &&
                request.path == '/v1/devices/current') {
              expect(request.data.toString(), contains('LEAKCHECK'));
            } else {
              expect(request.data.toString(), isNot(contains('LEAK')));
            }
          }

          // Not in preferences, and no message in the secure store; the token is only in
          // the registration record there.
          final prefs = SharedPreferencesAsync();
          for (final entry in (await prefs.getAll()).entries) {
            expect(entry.key, isNot(contains('push')));
            expect('${entry.value}', isNot(contains('LEAK')));
          }
          for (final entry in fakes.secure.values.entries) {
            if (entry.key == PushKeys.registration) {
              continue;
            }
            expect(entry.value, isNot(contains('LEAK')), reason: entry.key);
          }
          expect(
            fakes.secure.values[PushKeys.registration],
            isNot(contains('LEAKTITLE')),
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );
    } finally {
      debugPrint = original;
      FlutterError.onError = previousOnError;
    }
  });

  test('what a token, a push and a registration print is only a word', () {
    expect(
      '${const IncomingPush(data: {'x': _title}, title: _title, body: _body)}',
      isNot(contains('LEAK')),
    );
    final registration = PushRegistration(
      userId: 'user-1',
      token: _token,
      facts: '1|15|en',
      at: DateTime.utc(2026, 10, 11),
    );
    expect('$registration', isNot(contains('LEAK')));
    expect('$registration', isNot(contains('user-1')));
  });
}
