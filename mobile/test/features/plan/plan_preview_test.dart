import 'package:afterme/core/time/time_format.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:afterme/features/plan/presentation/plan_preview.dart';
import 'package:afterme/l10n/gen/app_localizations.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/plan_fixtures.dart';
import '../../helpers/test_app.dart';

final _mom = testContact(id: 'm', name: 'Mom', email: 'm@x.co');
final _bro = testContact(
  id: 'b',
  name: 'Brother',
  relationship: ContactRelationship.sibling,
  email: 'b@x.co',
);
final _sam = testContact(
  id: 's',
  name: 'Sam',
  relationship: ContactRelationship.friend,
  email: 's@x.co',
);

Future<T> _inContext<T>(
  WidgetTester tester,
  T Function(BuildContext context) body, {
  bool use24Hour = false,
}) async {
  late T result;
  await tester.pumpWidget(
    wrapForTest(
      Builder(
        builder: (context) {
          result = body(context);
          return const SizedBox();
        },
      ),
      mediaQuery: (data) => data.copyWith(alwaysUse24HourFormat: use24Hour),
    ),
  );
  return result;
}

void main() {
  final AppLocalizations l10n = AppLocalizationsEn();

  testWidgets('time formatting follows the 12/24 hour setting and wraps days', (
    tester,
  ) async {
    expect(
      await _inContext(tester, (c) => formatMinutesOfDay(c, 20 * 60)),
      '8:00 PM',
    );
    expect(
      await _inContext(
        tester,
        (c) => formatMinutesOfDay(c, 20 * 60),
        use24Hour: true,
      ),
      '20:00',
    );
    expect(
      await _inContext(tester, (c) => formatMinutesOfDay(c, 25 * 60 + 5)),
      '1:05 AM',
    );
    expect(
      await _inContext(tester, (c) => formatMinutesOfDay(c, -60)),
      '11:00 PM',
    );

    String day(int minutes) => formatMinutesWithDay(
      tester.element(find.byType(SizedBox)),
      l10n,
      minutes,
    );
    await _inContext(tester, (c) => 0);
    expect(day(23 * 60), '11:00 PM');
    expect(day(25 * 60), '1:00 AM the next day');
    expect(day(2 * 1440 + 20 * 60), '8:00 PM, 2 days later');
  });

  test('durations read naturally', () {
    expect(formatDurationMinutes(l10n, 90), '90 minutes');
    expect(formatDurationMinutes(l10n, 60), '1 hour');
    expect(formatDurationMinutes(l10n, 180), '3 hours');
    expect(formatDurationMinutes(l10n, 1440), '1 day');
    expect(formatDurationMinutes(l10n, 2880), '2 days');
  });

  test('names are joined in plain words', () {
    expect(joinNames(l10n, const []), '');
    expect(joinNames(l10n, ['Mom']), 'Mom');
    expect(joinNames(l10n, ['Mom', 'Brother']), 'Mom and Brother');
    expect(joinNames(l10n, ['Mom', 'Brother', 'Sam']), 'Mom, Brother and Sam');
  });

  testWidgets(
    'the standard plan reads "If you miss 8:00 PM ... At 11:00 PM, Mom is notified."',
    (tester) async {
      final lines = await _inContext(
        tester,
        (c) => buildPlanPreview(
          c,
          dueMinutes: 20 * 60,
          plan: PlanPresets.standard([_mom]),
          contacts: [_mom],
        ).map((l) => l.text).toList(),
      );
      expect(lines, [
        'If you miss 8:00 PM, we remind you first.',
        'At 11:00 PM, Mom is notified.',
        'Checking in before then stops it.',
      ]);
    },
  );

  testWidgets(
    'several contacts, plural verb, next-day times, unknown ids skipped',
    (tester) async {
      final lines = await _inContext(
        tester,
        (c) => buildPlanPreview(
          c,
          dueMinutes: 22 * 60,
          plan: const PlanDraft(
            graceMinutes: 180,
            stages: [
              PlanStageDraft(offsetMinutes: 180, contactIds: ['m', 'b']),
              PlanStageDraft(offsetMinutes: 1440 + 60, contactIds: ['s']),
              PlanStageDraft(offsetMinutes: 600, contactIds: ['ghost']),
            ],
          ),
          contacts: [_mom, _bro, _sam],
        ).map((l) => l.text).toList(),
      );
      expect(lines, [
        'If you miss 10:00 PM, we remind you first.',
        'At 1:00 AM the next day, Mom and Brother are notified.',
        'At 11:00 PM the next day, Sam is notified.',
        'Checking in before then stops it.',
      ]);
    },
  );

  testWidgets('what a stage shares is said next to who is told, using only the '
      'server\'s offsets and the schedule\'s due time', (tester) async {
    final lines = await _inContext(
      tester,
      (c) => buildPlanPreview(
        c,
        dueMinutes: 20 * 60,
        plan: const PlanDraft(
          graceMinutes: 180,
          stages: [
            PlanStageDraft(id: 's1', offsetMinutes: 180, contactIds: ['m']),
            PlanStageDraft(id: 's2', offsetMinutes: 1440, contactIds: ['b']),
            PlanStageDraft(
              id: 's3',
              offsetMinutes: 2880,
              contactIds: ['b', 's'],
            ),
            PlanStageDraft(offsetMinutes: 4320, contactIds: ['m']),
          ],
        ),
        contacts: [_mom, _bro, _sam],
        releaseCounts: const {'s1': 0, 's2': 1, 's3': 3, 'other': 9},
      ).map((l) => l.text).toList(),
    );
    expect(lines, [
      'If you miss 8:00 PM, we remind you first.',
      'At 11:00 PM, Mom is notified.',
      'At 8:00 PM the next day, Brother is notified. 1 instruction is also shared.',
      'At 8:00 PM, 2 days later, Brother and Sam are notified. 3 instructions are also shared.',
      'At 8:00 PM, 3 days later, Mom is notified.',
      'Checking in before then stops it.',
    ]);
  });

  testWidgets(
    'a stage that tells nobody still says what it shares; one that does '
    'neither is left out',
    (tester) async {
      final lines = await _inContext(
        tester,
        (c) => buildPlanPreview(
          c,
          dueMinutes: 20 * 60,
          plan: const PlanDraft(
            graceMinutes: 180,
            stages: [
              PlanStageDraft(id: 's1', offsetMinutes: 180, contactIds: []),
              PlanStageDraft(id: 's2', offsetMinutes: 1440, contactIds: []),
              PlanStageDraft(id: 's3', offsetMinutes: 2880, contactIds: []),
            ],
          ),
          contacts: [_mom],
          releaseCounts: const {'s2': 1, 's3': 2},
        ).map((l) => l.text).toList(),
      );
      expect(lines, [
        'If you miss 8:00 PM, we remind you first.',
        'At 8:00 PM the next day, 1 instruction is shared.',
        'At 8:00 PM, 2 days later, 2 instructions are shared.',
        'Checking in before then stops it.',
      ]);
    },
  );

  testWidgets('PlanPreview renders every line with an icon', (tester) async {
    await tester.pumpWidget(
      wrapForTest(
        const PlanPreview(
          lines: [
            PlanPreviewLine(Icons.notifications_active_outlined, 'One'),
            PlanPreviewLine(Icons.verified_outlined, 'Two'),
          ],
        ),
      ),
    );
    expect(find.text('One'), findsOneWidget);
    expect(find.text('Two'), findsOneWidget);
    expect(find.byType(Icon), findsNWidgets(2));
  });

  test('plan presets', () {
    expect(PlanPresets.standardGraceMinutes, 180);
    expect(PlanPresets.graceChoicesMinutes, contains(180));
    expect(PlanPresets.standard([_mom, _bro]).stages.single.contactIds, [
      'm',
      'b',
    ]);
    expect(PlanPresets.standard([_mom]).graceMinutes, 180);
    expect(PlanPresets.standard([_mom]).stages.single.id, isNull);
    expect(
      PlanPresets.standard([
        _mom,
      ], graceMinutes: 360).stages.single.offsetMinutes,
      360,
      reason: 'stage 1 always runs when the grace period ends',
    );
  });

  test('the preset tells only contacts that are switched on', () {
    final off = _mom.copyWith(isActive: false);
    expect(PlanPresets.standard([off, _bro]).stages.single.contactIds, ['b']);
  });

  group('the preset on a plan that already has stages', () {
    final saved = testPlan(
      grace: 180,
      stages: const [
        PlanStage(id: 's1', position: 1, offsetMinutes: 180, contactIds: ['x']),
        PlanStage(
          id: 's2',
          position: 2,
          offsetMinutes: 1440,
          contactIds: ['b'],
          releaseCount: 2,
        ),
      ],
    );

    test('replaces only stage 1 (keeping its id) and keeps the others', () {
      final draft = PlanPresets.standard(
        [_mom],
        current: saved,
        graceMinutes: 360,
      );
      expect(draft.graceMinutes, 360);
      expect(draft.stages, const [
        PlanStageDraft(id: 's1', offsetMinutes: 360, contactIds: ['m']),
        PlanStageDraft(id: 's2', offsetMinutes: 1440, contactIds: ['b']),
      ]);
    });

    test('keeps the saved delay unless another is chosen', () {
      expect(PlanPresets.standard([_mom], current: saved).graceMinutes, 180);
    });

    test('a plan without stages gives a new stage', () {
      final empty = testPlan(grace: 180);
      final draft = PlanPresets.standard([_mom], current: empty);
      expect(draft.stages.single.id, isNull);
    });
  });

  group('grace choices follow the server rules', () {
    test('a free account is offered the presets only', () {
      expect(PlanPresets.graceChoices(planRules()), [180, 360, 720, 1440]);
    });

    test('an account with custom offsets is offered the shorter ones too', () {
      expect(PlanPresets.graceChoices(planRules(custom: true)), [
        60,
        120,
        180,
        360,
        720,
        1440,
      ]);
    });

    test('the saved delay is always one of the choices', () {
      expect(PlanPresets.graceChoices(planRules(), current: 2880), [
        180,
        360,
        720,
        1440,
        2880,
      ]);
    });

    test('nothing outside the tier range is offered', () {
      expect(PlanPresets.graceChoices(planRules(custom: true, graceMin: 150)), [
        180,
        360,
        720,
        1440,
      ]);
    });

    test('without rules only the presets every tier has', () {
      expect(PlanPresets.graceChoices(null), [180, 360, 720, 1440]);
    });
  });
}
