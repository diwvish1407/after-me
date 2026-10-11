import 'package:afterme/features/activity/data/models/activity_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ActivityItem.tryFromJson', () {
    test('reads what the server sends', () {
      final item = ActivityItem.tryFromJson({
        'id': 98121,
        'action': 'release.viewed',
        'occurred_at': '2026-10-08T09:00:00Z',
        'params': {
          'contact_display_name': 'Brother',
          'instruction_titles': ['House emergency'],
        },
      })!;
      expect(item.id, 98121);
      expect(item.action, 'release.viewed');
      expect(item.occurredAt, DateTime.utc(2026, 10, 8, 9));
      expect(item.params['contact_display_name'], 'Brother');
      expect(item.params['instruction_titles'], ['House emergency']);
    });

    test('ignores fields it does not know', () {
      final item = ActivityItem.tryFromJson({
        'id': 1,
        'action': 'checkin.recorded',
        'occurred_at': '2026-10-08T09:00:00Z',
        'params': {'kind': 'ok', 'source': 'app', 'a_new_key': 5},
        'a_new_field': {'x': 1},
      })!;
      expect(item.action, 'checkin.recorded');
      expect(item.params['a_new_key'], 5);
    });

    test('an action nobody knows is kept as it is', () {
      final item = ActivityItem.tryFromJson({
        'id': 2,
        'action': 'something.from_the_future',
        'occurred_at': '2026-10-08T09:00:00Z',
        'params': <String, dynamic>{},
      })!;
      expect(item.action, 'something.from_the_future');
    });

    test(
      'null, missing and mistyped params are an empty map, never a crash',
      () {
        for (final params in <Object?>[
          null,
          'text',
          5,
          [1, 2],
        ]) {
          final item = ActivityItem.tryFromJson({
            'id': 3,
            'action': 'plan.updated',
            'occurred_at': '2026-10-08T09:00:00Z',
            'params': params,
          })!;
          expect(item.params, isEmpty, reason: '$params');
        }
        final missing = ActivityItem.tryFromJson({
          'id': 3,
          'action': 'plan.updated',
          'occurred_at': '2026-10-08T09:00:00Z',
        })!;
        expect(missing.params, isEmpty);
      },
    );

    test('null names and titles stay null inside the params', () {
      final item = ActivityItem.tryFromJson({
        'id': 4,
        'action': 'instruction.recipients_changed',
        'occurred_at': '2026-10-08T09:00:00Z',
        'params': {'instruction_title': null, 'added': 1, 'removed': 0},
      })!;
      expect(item.params['instruction_title'], isNull);
      expect(item.params.containsKey('instruction_title'), isTrue);
    });

    test('a missing or mistyped action or id is tolerated; a missing time is '
        'not an entry', () {
      final noAction = ActivityItem.tryFromJson({
        'id': 'abc',
        'occurred_at': '2026-10-08T09:00:00Z',
      })!;
      expect(noAction.action, isEmpty);
      expect(noAction.id, isNull);
      expect(
        ActivityItem.tryFromJson({'id': 1, 'action': 'checkin.recorded'}),
        isNull,
      );
      expect(
        ActivityItem.tryFromJson({
          'id': 1,
          'action': 'checkin.recorded',
          'occurred_at': 'not a time',
        }),
        isNull,
      );
      expect(ActivityItem.tryFromJson('x'), isNull);
      expect(ActivityItem.tryFromJson(null), isNull);
    });

    test('a numeric id of another type is read as a whole number', () {
      final item = ActivityItem.tryFromJson({
        'id': 12.0,
        'action': 'a',
        'occurred_at': '2026-10-08T09:00:00Z',
      })!;
      expect(item.id, 12);
    });

    test('equality follows the content, and toString hides names', () {
      Map<String, dynamic> json() => {
        'id': 1,
        'action': 'contact.created',
        'occurred_at': '2026-10-08T09:00:00Z',
        'params': {'contact_display_name': 'Mom'},
      };
      final a = ActivityItem.tryFromJson(json())!;
      final b = ActivityItem.tryFromJson(json())!;
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.toString(), isNot(contains('Mom')));
    });
  });

  group('ActivityPage.fromJson', () {
    test('reads items and the cursor', () {
      final page = ActivityPage.fromJson({
        'items': [
          {
            'id': 2,
            'action': 'checkin.recorded',
            'occurred_at': '2026-10-08T09:00:00Z',
            'params': {'kind': 'ok'},
          },
          {
            'id': 1,
            'action': 'schedule.activated',
            'occurred_at': '2026-10-08T08:00:00Z',
            'params': <String, dynamic>{},
          },
        ],
        'next_cursor': 'abc',
      });
      expect(page.items.map((i) => i.id), [2, 1]);
      expect(page.nextCursor, 'abc');
    });

    test('an empty feed and the last page', () {
      final page = ActivityPage.fromJson({
        'items': <Object>[],
        'next_cursor': null,
      });
      expect(page.items, isEmpty);
      expect(page.nextCursor, isNull);
      expect(ActivityPage.fromJson({'next_cursor': ''}).nextCursor, isNull);
    });

    test('an entry that cannot be read is left out, the rest is kept', () {
      final page = ActivityPage.fromJson({
        'items': [
          'junk',
          {'id': 1, 'action': 'a'},
          {'id': 2, 'action': 'b', 'occurred_at': '2026-10-08T09:00:00Z'},
        ],
        'next_cursor': 5,
      });
      expect(page.items.map((i) => i.id), [2]);
      expect(page.nextCursor, isNull);
    });

    test('a body that is not an object is a failure, never an empty feed', () {
      expect(() => ActivityPage.fromJson('<html>'), throwsFormatException);
      expect(() => ActivityPage.fromJson(null), throwsFormatException);
      expect(() => ActivityPage.fromJson([1]), throwsFormatException);
    });
  });
}
