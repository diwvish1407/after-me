import 'package:afterme/core/time/time_format.dart';
import 'package:afterme/l10n/gen/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';

void main() {
  Future<String> format(
    WidgetTester tester,
    DateTime instant, {
    bool use24Hour = false,
  }) async {
    late String text;
    await tester.pumpWidget(
      wrapForTest(
        Builder(
          builder: (context) {
            text = formatDateTime(context, instant);
            return const SizedBox();
          },
        ),
        mediaQuery: (data) => data.copyWith(alwaysUse24HourFormat: use24Hour),
      ),
    );
    return text;
  }

  testWidgets('shows the local date and time in the 12-hour setting', (
    tester,
  ) async {
    final instant = DateTime(2026, 10, 8, 19, 30);
    final text = await format(tester, instant.toUtc());
    expect(text, contains('Oct 8'));
    expect(text, contains('7:30 PM'));
  });

  testWidgets('and in the 24-hour setting', (tester) async {
    final instant = DateTime(2026, 10, 8, 19, 30);
    final text = await format(tester, instant.toUtc(), use24Hour: true);
    expect(text, contains('19:30'));
  });

  group('in a profile timezone', () {
    testWidgets('formatDateTime uses the zone, not the phone\'s', (
      tester,
    ) async {
      late String kolkata;
      late String auckland;
      await tester.pumpWidget(
        wrapForTest(
          Builder(
            builder: (context) {
              final instant = DateTime.utc(2026, 10, 14, 14, 30);
              kolkata = formatDateTime(
                context,
                instant,
                timezone: 'Asia/Kolkata',
              );
              auckland = formatDateTime(
                context,
                instant,
                timezone: 'Pacific/Auckland',
              );
              return const SizedBox();
            },
          ),
        ),
      );
      expect(kolkata, contains('Oct 14'));
      expect(kolkata, contains('8:00 PM'));
      expect(auckland, contains('Oct 15'));
      expect(auckland, contains('3:30 AM'));
    });

    testWidgets('formatClockTime follows the 12/24-hour setting', (
      tester,
    ) async {
      for (final (use24, expected) in [(false, '8:00 PM'), (true, '20:00')]) {
        late String text;
        await tester.pumpWidget(
          wrapForTest(
            Builder(
              builder: (context) {
                text = formatClockTime(
                  context,
                  DateTime.utc(2026, 10, 14, 14, 30),
                  timezone: 'Asia/Kolkata',
                );
                return const SizedBox();
              },
            ),
            mediaQuery: (data) => data.copyWith(alwaysUse24HourFormat: use24),
          ),
        );
        expect(text, expected);
      }
    });

    testWidgets(
      'formatDayTime and formatSpokenDayTime count days in the zone',
      (tester) async {
        final now = DateTime.utc(2026, 10, 8, 12); // 5:30 PM in Kolkata
        final cases = <(DateTime, String, String)>[
          (
            DateTime.utc(2026, 10, 8, 14, 30),
            'Today · 8:00 PM',
            'today at 8:00 PM',
          ),
          (
            DateTime.utc(2026, 10, 9, 14, 30),
            'Tomorrow · 8:00 PM',
            'tomorrow at 8:00 PM',
          ),
          (
            DateTime.utc(2026, 10, 7, 14, 30),
            'Yesterday · 8:00 PM',
            'yesterday at 8:00 PM',
          ),
          (
            DateTime.utc(2026, 10, 16, 14, 30),
            'Oct 16 · 8:00 PM',
            'on Oct 16 at 8:00 PM',
          ),
          // 19:00 UTC is 12:30 AM on Oct 9 in Kolkata: tomorrow, not today.
          (
            DateTime.utc(2026, 10, 8, 19),
            'Tomorrow · 12:30 AM',
            'tomorrow at 12:30 AM',
          ),
        ];
        for (final (instant, visible, spoken) in cases) {
          late String a;
          late String b;
          await tester.pumpWidget(
            wrapForTest(
              Builder(
                builder: (context) {
                  final l10n = AppLocalizations.of(context);
                  a = formatDayTime(
                    context,
                    l10n,
                    instant,
                    now: now,
                    timezone: 'Asia/Kolkata',
                  );
                  b = formatSpokenDayTime(
                    context,
                    l10n,
                    instant,
                    now: now,
                    timezone: 'Asia/Kolkata',
                  );
                  return const SizedBox();
                },
              ),
            ),
          );
          expect(a, visible);
          expect(b, spoken);
        }
      },
    );

    testWidgets('formatUntil', (tester) async {
      late AppLocalizations l10n;
      await tester.pumpWidget(
        wrapForTest(
          Builder(
            builder: (context) {
              l10n = AppLocalizations.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(formatUntil(l10n, Duration.zero), 'less than a minute');
      expect(
        formatUntil(l10n, const Duration(seconds: -5)),
        'less than a minute',
      );
      expect(formatUntil(l10n, const Duration(seconds: 1)), '1 minute');
      expect(formatUntil(l10n, const Duration(seconds: 61)), '2 minutes');
      expect(formatUntil(l10n, const Duration(minutes: 45)), '45 minutes');
      expect(formatUntil(l10n, const Duration(minutes: 60)), '1 hour');
      expect(formatUntil(l10n, const Duration(minutes: 90)), '1 h 30 min');
      expect(formatUntil(l10n, const Duration(hours: 4)), '4 hours');
    });
  });
}
