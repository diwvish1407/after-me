import 'package:afterme/app/router.dart';
import 'package:afterme/core/push/notification_channel.dart';
import 'package:afterme/core/push/push_gateway.dart';
import 'package:afterme/features/notifications/application/push_message.dart';
import 'package:flutter_test/flutter_test.dart';

IncomingPush _push(
  Map<String, String> data, {
  String? title,
  String? body,
  String? channelId,
}) => IncomingPush(data: data, title: title, body: body, channelId: channelId);

void main() {
  group('the types the server sends', () {
    test('every type has its own wire name, notification id and a channel', () {
      expect(
        PushType.values.map((t) => t.wire).toSet(),
        hasLength(PushType.values.length),
      );
      expect(
        PushType.values.map((t) => t.notificationId).toSet(),
        hasLength(PushType.values.length),
      );
      for (final type in PushType.values) {
        expect(PushType.fromWire(type.wire), type);
      }
    });

    test('anything that is not a type of this version is null', () {
      expect(PushType.fromWire(null), isNull);
      expect(PushType.fromWire(''), isNull);
      expect(PushType.fromWire('INCIDENT_MISSED'), isNull);
      expect(PushType.fromWire('incident_missed '), isNull);
      expect(PushType.fromWire('something_new'), isNull);
    });

    test('reminders arrive on reminders, plan alerts on incidents', () {
      expect(
        PushType.checkinPreReminder.channel,
        NotificationChannel.reminders,
      );
      expect(
        PushType.incidentLastChance.channel,
        NotificationChannel.reminders,
      );
      expect(PushType.stageExecuted.channel, NotificationChannel.incidents);
      expect(
        PushType.releaseFinalWarning.channel,
        NotificationChannel.incidents,
      );
      expect(PushType.contactUnreachable.channel, NotificationChannel.account);
    });

    test('the destinations are Home and People and their routes are fixed', () {
      expect(PushDestination.fromWire('home'), PushDestination.home);
      expect(PushDestination.fromWire('people'), PushDestination.people);
      expect(PushDestination.fromWire('settings'), isNull);
      expect(PushDestination.fromWire(null), isNull);
      expect(PushDestination.home.location, AppRoutes.home);
      expect(PushDestination.people.location, AppRoutes.people);
      expect(PushType.contactUnreachable.destination, PushDestination.people);
      for (final type in PushType.values.where(
        (t) => t != PushType.contactUnreachable,
      )) {
        expect(type.destination, PushDestination.home, reason: type.wire);
      }
    });
  });

  group('a message to act on', () {
    test('a known type in version 1 is read, with the server\'s own words', () {
      final message = PushMessage.tryParse(
        _push(
          {
            'type': 'incident_missed',
            'v': '1',
            'incident_id': '11111111-1111-4111-8111-111111111111',
          },
          title: '  You missed your check-in ',
          body: "Tap I'M OK to stop the reminders.",
          channelId: 'reminders',
        ),
      )!;
      expect(message.type, PushType.incidentMissed);
      expect(message.channel, NotificationChannel.reminders);
      expect(message.incidentId, '11111111-1111-4111-8111-111111111111');
      expect(message.title, 'You missed your check-in');
      expect(message.body, "Tap I'M OK to stop the reminders.");
      expect(message.hasText, isTrue);
    });

    test('no type, an unknown type or another version is ignored', () {
      expect(PushMessage.tryParse(_push({})), isNull);
      expect(PushMessage.tryParse(_push({'v': '1'})), isNull);
      expect(
        PushMessage.tryParse(_push({'type': 'something_new', 'v': '1'})),
        isNull,
      );
      expect(PushMessage.tryParse(_push({'type': 'incident_missed'})), isNull);
      expect(
        PushMessage.tryParse(_push({'type': 'incident_missed', 'v': '2'})),
        isNull,
      );
      expect(
        PushMessage.tryParse(_push({'type': 'incident_missed', 'v': '1.0'})),
        isNull,
      );
      expect(supportedPushVersion, '1');
    });

    test(
      'the server names the channel; an unknown name is the type\'s own',
      () {
        PushMessage? parse(String? channelId) => PushMessage.tryParse(
          _push({'type': 'stage_executed', 'v': '1'}, channelId: channelId),
        );
        expect(parse('incidents')!.channel, NotificationChannel.incidents);
        expect(parse('reminders')!.channel, NotificationChannel.reminders);
        expect(parse('miscellaneous')!.channel, NotificationChannel.incidents);
        expect(parse(null)!.channel, NotificationChannel.incidents);
      },
    );

    test('an incident id is kept only when it is shaped like one', () {
      PushMessage? parse(String? id) => PushMessage.tryParse(
        _push({'type': 'incident_missed', 'v': '1', 'incident_id': ?id}),
      );
      expect(parse(null)!.incidentId, isNull);
      expect(parse('not-an-id')!.incidentId, isNull);
      expect(parse("11111111-1111-4111-8111-1111111111'1")!.incidentId, isNull);
      expect(parse('../../settings')!.incidentId, isNull);
      expect(
        parse('AAAAAAAA-1111-4111-8111-111111111111')!.incidentId,
        'AAAAAAAA-1111-4111-8111-111111111111',
      );
    });

    test('empty text is no text', () {
      final message = PushMessage.tryParse(
        _push({'type': 'incident_missed', 'v': '1'}, title: '  ', body: ''),
      )!;
      expect(message.title, isNull);
      expect(message.body, isNull);
      expect(message.hasText, isFalse);
      expect(
        PushMessage.tryParse(
          _push({
            'type': 'incident_missed',
            'v': '1',
          }, body: 'Tap to check in.'),
        )!.hasText,
        isTrue,
      );
    });

    test('a message prints only its type', () {
      final message = PushMessage.tryParse(
        _push(
          {'type': 'incident_missed', 'v': '1'},
          title: 'A secret title',
          body: 'A secret body',
        ),
      )!;
      expect('$message', 'PushMessage(incident_missed)');
      expect(
        '${_push({'type': 'x'}, title: 'A secret title')}',
        isNot(contains('secret')),
      );
    });
  });

  group('where a tap goes', () {
    test('a known type goes where the table says', () {
      expect(
        tapDestination({'type': 'contact_unreachable', 'v': '1'}),
        PushDestination.people,
      );
      expect(
        tapDestination({'type': 'incident_midpoint', 'v': '1'}),
        PushDestination.home,
      );
    });

    test('an unknown type, a missing one and another version open Home', () {
      expect(
        tapDestination({'type': 'something_new', 'v': '1'}),
        PushDestination.home,
      );
      expect(tapDestination({}), PushDestination.home);
      expect(
        tapDestination({'type': 'contact_unreachable', 'v': '2'}),
        PushDestination.home,
        reason: 'a format this version cannot read is not followed',
      );
      expect(
        tapDestination({'type': '/settings/privacy/delete', 'v': '1'}),
        PushDestination.home,
      );
    });
  });
}
