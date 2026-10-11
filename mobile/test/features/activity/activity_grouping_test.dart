import 'package:afterme/features/activity/application/activity_grouping.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_activity_server.dart';

void main() {
  test('groups neighbouring entries of one calendar day, newest first', () {
    final days = groupActivityByDay([
      activityItem('a', id: 4, at: DateTime.utc(2026, 10, 9, 10)),
      activityItem('b', id: 3, at: DateTime.utc(2026, 10, 9, 8)),
      activityItem('c', id: 2, at: DateTime.utc(2026, 10, 8, 20)),
      activityItem('d', id: 1, at: DateTime.utc(2026, 10, 7, 1)),
    ], timezone: 'UTC');
    expect(days.map((d) => d.date), [
      DateTime.utc(2026, 10, 9),
      DateTime.utc(2026, 10, 8),
      DateTime.utc(2026, 10, 7),
    ]);
    expect(days.first.items.map((i) => i.id), [4, 3]);
  });

  test('the day is the person\'s own, in their timezone', () {
    // 20:00 UTC is already the next day in Kolkata (UTC+5:30).
    final items = [
      activityItem('a', id: 2, at: DateTime.utc(2026, 10, 8, 20)),
      activityItem('b', id: 1, at: DateTime.utc(2026, 10, 8, 10)),
    ];
    final utc = groupActivityByDay(items, timezone: 'UTC');
    expect(utc, hasLength(1));
    final kolkata = groupActivityByDay(items, timezone: 'Asia/Kolkata');
    expect(kolkata.map((d) => d.date), [
      DateTime.utc(2026, 10, 9),
      DateTime.utc(2026, 10, 8),
    ]);
  });

  test('no entries, no days', () {
    expect(groupActivityByDay(const []), isEmpty);
  });

  test('an entry out of order starts a group of its own, nothing is lost', () {
    final days = groupActivityByDay([
      activityItem('a', id: 3, at: DateTime.utc(2026, 10, 9)),
      activityItem('b', id: 2, at: DateTime.utc(2026, 10, 8)),
      activityItem('c', id: 1, at: DateTime.utc(2026, 10, 9, 5)),
    ], timezone: 'UTC');
    expect(days, hasLength(3));
    expect(days.expand((d) => d.items).map((i) => i.id), [3, 2, 1]);
  });
}
