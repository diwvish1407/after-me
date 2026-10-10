import 'package:afterme/core/time/zoned_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('inTimezone', () {
    test('reads an instant as wall-clock time in the zone', () {
      final instant = DateTime.utc(2026, 10, 14, 14, 30);
      final kolkata = inTimezone(instant, 'Asia/Kolkata');
      expect([kolkata.year, kolkata.month, kolkata.day], [2026, 10, 14]);
      expect([kolkata.hour, kolkata.minute], [20, 0]);

      final auckland = inTimezone(instant, 'Pacific/Auckland');
      expect([auckland.day, auckland.hour, auckland.minute], [15, 3, 30]);

      final newYork = inTimezone(instant, 'America/New_York');
      expect([newYork.day, newYork.hour, newYork.minute], [14, 10, 30]);
    });

    test('follows daylight saving time of the date, not of today', () {
      // New York springs forward on 2026-03-08 at 02:00 local.
      final before = inTimezone(
        DateTime.utc(2026, 3, 8, 6, 59),
        'America/New_York',
      );
      expect([before.hour, before.minute], [1, 59]);
      final after = inTimezone(
        DateTime.utc(2026, 3, 8, 7, 0),
        'America/New_York',
      );
      expect([after.hour, after.minute], [3, 0]);
      // And back on 2026-11-01.
      final fallBack = inTimezone(
        DateTime.utc(2026, 11, 1, 6, 30),
        'America/New_York',
      );
      expect([fallBack.hour, fallBack.minute], [1, 30]);
    });

    test('an instant given in another zone is the same instant', () {
      final local = DateTime.parse('2026-10-14T20:00:00+05:30');
      final kolkata = inTimezone(local, 'Asia/Kolkata');
      expect([kolkata.hour, kolkata.minute], [20, 0]);
    });

    test('an unknown or missing zone falls back to the phone\'s', () {
      final instant = DateTime.utc(2026, 10, 14, 14, 30);
      for (final zone in [null, '', 'Mars/Olympus_Mons']) {
        final result = inTimezone(instant, zone);
        expect(result.isAtSameMomentAs(instant), isTrue, reason: '$zone');
        expect(result.hour, instant.toLocal().hour, reason: '$zone');
      }
    });

    test('isKnownTimezone', () {
      expect(isKnownTimezone('Asia/Kolkata'), isTrue);
      expect(isKnownTimezone('UTC'), isTrue);
      expect(isKnownTimezone('Nowhere/Land'), isFalse);
      expect(isKnownTimezone(null), isFalse);
      expect(isKnownTimezone(''), isFalse);
    });
  });

  group('calendarDaysBetween (days are counted in the zone)', () {
    test('the same local day, the next and the previous', () {
      final now = DateTime.utc(2026, 10, 8, 12); // 17:30 in Kolkata
      expect(
        calendarDaysBetween(
          now,
          DateTime.utc(2026, 10, 8, 14, 30),
          'Asia/Kolkata',
        ),
        0,
      );
      expect(
        calendarDaysBetween(
          now,
          DateTime.utc(2026, 10, 9, 14, 30),
          'Asia/Kolkata',
        ),
        1,
      );
      expect(
        calendarDaysBetween(
          now,
          DateTime.utc(2026, 10, 7, 14, 30),
          'Asia/Kolkata',
        ),
        -1,
      );
      expect(
        calendarDaysBetween(
          now,
          DateTime.utc(2026, 10, 15, 14, 30),
          'Asia/Kolkata',
        ),
        7,
      );
    });

    test('the zone decides where the day changes', () {
      // 19:00 UTC on Oct 8 is still Oct 8 in London (BST) but already Oct 9 in
      // Kolkata (00:30).
      final now = DateTime.utc(2026, 10, 8, 12);
      final instant = DateTime.utc(2026, 10, 8, 19);
      expect(calendarDaysBetween(now, instant, 'Europe/London'), 0);
      expect(calendarDaysBetween(now, instant, 'Asia/Kolkata'), 1);
    });

    test('across a month and a year boundary', () {
      expect(
        calendarDaysBetween(
          DateTime.utc(2026, 12, 31, 12),
          DateTime.utc(2027, 1, 1, 12),
          'UTC',
        ),
        1,
      );
    });
  });
}
