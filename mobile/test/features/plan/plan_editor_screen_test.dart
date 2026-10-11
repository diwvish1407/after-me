import 'dart:async';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/design_system/design_system.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/incidents/presentation/incident_history_screen.dart';
import 'package:afterme/features/instructions/data/models/instruction_models.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:afterme/features/plan/presentation/plan_editor_screen.dart';
import 'package:afterme/features/plan/presentation/plan_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

/// The plan editor: what a person sees, what each control does, what is sent, and what
/// is said when the server does not agree.

/// Mom (accepted) and Brother (accepted), Sam (waiting), Dad (declined).
List<TrustedContact> _people() => [
  testContact(),
  testContact(
    id: 'c2',
    name: 'Brother',
    relationship: ContactRelationship.sibling,
    email: 'bro@example.com',
    priority: 2,
  ),
  testContact(
    id: 'c3',
    name: 'Sam',
    relationship: ContactRelationship.friend,
    email: 'sam@example.com',
    priority: 3,
    status: VerificationStatus.pending,
  ),
  testContact(
    id: 'c4',
    name: 'Dad',
    relationship: ContactRelationship.father,
    email: 'dad@example.com',
    priority: 4,
    status: VerificationStatus.declined,
  ),
];

/// Mom is told after 3 hours and Brother after 1 day.
TestFakes _world({
  String tier = 'premium',
  bool active = false,
  List<TrustedContact>? contacts,
}) {
  final fakes = TestFakes()
    ..contacts = InMemoryContactsRepository(
      tier: tier,
      initial: contacts ?? _people(),
    );
  fakes.plan.seed(
    const PlanDraft(
      graceMinutes: 180,
      stages: [
        PlanStageDraft(offsetMinutes: 180, contactIds: ['c1']),
        PlanStageDraft(offsetMinutes: 1440, contactIds: ['c2']),
      ],
    ),
  );
  if (active) {
    fakes.server.activateNow();
  }
  return fakes;
}

Future<ProviderContainer> _open(
  WidgetTester tester,
  TestFakes fakes, {
  double textScale = 1,
  Size size = const Size(390, 1400),
}) => openApp(
  tester,
  fakes: fakes,
  route: AppRoutes.planEdit,
  textScale: textScale,
  size: size,
);

/// A few frames: `pumpAndSettle` cannot be used while a busy button spins.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Taps the button with [label] on stage [stage] (the screen reader's name for it).
Future<void> _tapStage(WidgetTester tester, String label, int stage) async {
  final finder = find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.label == '$label $stage',
  );
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _tapButton(WidgetTester tester, String label) async {
  final finder = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// The time chip [label] of the open time sheet (the page behind it has chips too).
Finder _chip(String label) => find.descendant(
  of: find.byType(BottomSheet),
  matching: find.widgetWithText(ChoiceChip, label),
);

/// Chooses the time chip [label] in an open time sheet and confirms it.
Future<void> _pickTime(WidgetTester tester, String label) async {
  await tester.tap(_chip(label));
  await tester.pump();
  await tester.tap(find.widgetWithText(FilledButton, 'Use this time'));
  await tester.pumpAndSettle();
}

bool _saveEnabled(WidgetTester tester) =>
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save changes'))
        .onPressed !=
    null;

ValidationFailure _invalid(List<ApiFieldError> errors) => ValidationFailure(
  code: 'validation_failed',
  fieldErrors: errors,
  problem: ApiProblem(status: 422, code: 'validation_failed', errors: errors),
);

void main() {
  group('opening it', () {
    testWidgets('the Plan tab has the editor and the past incidents', (
      tester,
    ) async {
      final fakes = _world();
      await openApp(tester, fakes: fakes, route: AppRoutes.plan);
      expect(find.byType(PlanScreen), findsOneWidget);
      expect(find.text('Edit your plan'), findsOneWidget);

      await tapText(tester, 'Edit your plan');
      await tester.pumpAndSettle();
      expect(find.byType(PlanEditorScreen), findsOneWidget);
      expect(find.text('Grace period'), findsOneWidget);
      expect(find.text('Stage 1: after 3 hours'), findsOneWidget);
      expect(find.text('Stage 2: after 1 day'), findsOneWidget);
    });

    testWidgets('the Plan tab\'s "Past incidents" opens the same screen as '
        'Settings', (tester) async {
      await openApp(tester, fakes: _world(), route: AppRoutes.plan);
      expect(find.text('Past incidents'), findsOneWidget);
      await tapText(tester, 'Past incidents');
      await tester.pumpAndSettle();
      expect(find.byType(IncidentHistoryScreen), findsOneWidget);
      expect(find.text('Past incidents'), findsWidgets);
      // Back is back where the person was: the Plan tab, not Settings.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(IncidentHistoryScreen), findsNothing);
      expect(find.byType(PlanScreen), findsOneWidget);
    });

    testWidgets('a plan with no stage has the history row too', (tester) async {
      final fakes = TestFakes()
        ..contacts = InMemoryContactsRepository(
          tier: 'premium',
          initial: _people(),
        );
      await openApp(tester, fakes: fakes, route: AppRoutes.plan);
      expect(find.text("You haven't set up a plan yet"), findsOneWidget);
      expect(find.text('Past incidents'), findsOneWidget);
      await tapText(tester, 'Past incidents');
      await tester.pumpAndSettle();
      expect(find.byType(IncidentHistoryScreen), findsOneWidget);
    });

    testWidgets('shows the plan, with the warnings that matter', (
      tester,
    ) async {
      final fakes = _world();
      await _open(tester, fakes);
      expect(find.text('Edit your plan'), findsWidgets);
      expect(
        find.text(
          "If you miss a check-in, we'll remind you for 3 hours before anyone is contacted.",
        ),
        findsOneWidget,
      );
      expect(find.text('Notify: Mom'), findsOneWidget);
      expect(find.text('Notify: Brother'), findsOneWidget);
      // Everyone has accepted: no warning anywhere.
      expect(find.textContaining("hasn't accepted"), findsNothing);
      expect(find.textContaining('nobody is told'), findsNothing);
      // The preview of the plan as it stands.
      expect(
        find.text('If you miss 8:00 PM, we remind you first.'),
        findsOneWidget,
      );
      expect(find.text('At 11:00 PM, Mom is notified.'), findsOneWidget);
      expect(
        find.text('At 8:00 PM the next day, Brother is notified.'),
        findsOneWidget,
      );
      // Nothing to save yet.
      expect(_saveEnabled(tester), isFalse);
      expect(find.text('Discard changes'), findsNothing);
    });

    testWidgets('while the plan loads there is a progress indicator, and a '
        'failure can be retried', (tester) async {
      final fakes = _world();
      fakes.plan.failures['get'] = [const NetworkFailure()];
      await _open(tester, fakes);
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(find.text('Grace period'), findsNothing);

      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.text('Grace period'), findsOneWidget);
    });

    testWidgets('while the plan loads there is a progress indicator', (
      tester,
    ) async {
      final fakes = _world();
      final gate = Completer<void>();
      fakes.plan.gate = gate.future;
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.planEdit,
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(find.text('Grace period'), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Grace period'), findsOneWidget);
    });

    testWidgets('trusted contacts that cannot be read are an error too', (
      tester,
    ) async {
      final fakes = _world();
      fakes.contacts.failures['list'] = [const NetworkFailure()];
      await _open(tester, fakes);
      expect(find.textContaining("You're offline"), findsOneWidget);
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.text('Grace period'), findsOneWidget);
    });
  });

  group('free and premium', () {
    testWidgets('a free account: suggested times only and two stages', (
      tester,
    ) async {
      final fakes = _world(tier: 'free');
      await _open(tester, fakes);
      expect(
        find.textContaining('The free plan uses the suggested times'),
        findsOneWidget,
      );
      expect(find.text('Choose another length of time'), findsNothing);
      // The grace choices are the suggested ones.
      for (final label in ['3 hours', '6 hours', '12 hours', '1 day']) {
        expect(find.widgetWithText(ChoiceChip, label), findsWidgets);
      }
      expect(find.widgetWithText(ChoiceChip, '1 hour'), findsNothing);

      // Two stages: no room for a third, and it says so.
      final add = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Add a stage'),
      );
      expect(add.onPressed, isNull);
      expect(
        find.text(
          'The free plan has room for 2 stages. More are part of Premium.',
        ),
        findsOneWidget,
      );

      // The time sheet has no custom fields.
      await _tapStage(tester, 'Change the time of stage', 2);
      expect(find.text('When should this stage run?'), findsOneWidget);
      expect(find.text('Or choose your own time'), findsNothing);
      expect(_chip('2 days'), findsOneWidget);
      expect(_chip('7 days'), findsNothing);
    });

    testWidgets('a premium account: its own times and up to ten stages', (
      tester,
    ) async {
      final fakes = _world();
      await _open(tester, fakes);
      expect(find.textContaining('The free plan uses'), findsNothing);
      expect(find.text('Choose another length of time'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '1 hour'), findsOneWidget);
      final add = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Add a stage'),
      );
      expect(add.onPressed, isNotNull);

      await _tapStage(tester, 'Change the time of stage', 2);
      expect(find.text('Or choose your own time'), findsOneWidget);
      expect(_chip('7 days'), findsOneWidget);
    });

    testWidgets('a premium account at ten stages cannot add another', (
      tester,
    ) async {
      final fakes = _world();
      fakes.plan.seed(
        PlanDraft(
          graceMinutes: 180,
          stages: [
            for (var i = 0; i < 10; i++)
              PlanStageDraft(
                offsetMinutes: i == 0 ? 180 : 1440 * i,
                contactIds: const ['c1'],
              ),
          ],
        ),
      );
      await _open(tester, fakes);
      final add = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Add a stage'),
      );
      expect(add.onPressed, isNull);
      expect(
        find.text("You've reached the most stages one account can have (10)."),
        findsOneWidget,
      );
    });
  });

  group('an account that was downgraded', () {
    testWidgets('keeps the custom times it has, can change the rest, and '
        'cannot add a stage', (tester) async {
      final fakes = _world(tier: 'free');
      fakes.plan.seed(
        const PlanDraft(
          graceMinutes: 200,
          stages: [
            PlanStageDraft(offsetMinutes: 200, contactIds: ['c1']),
            PlanStageDraft(offsetMinutes: 1000, contactIds: ['c2']),
            PlanStageDraft(offsetMinutes: 4320, contactIds: ['c1']),
          ],
        ),
      );
      await _open(tester, fakes);
      // Its own times are among the choices and need no explanation.
      expect(find.widgetWithText(ChoiceChip, '200 minutes'), findsOneWidget);
      expect(find.textContaining('at least 30 minutes after'), findsNothing);
      expect(
        find.textContaining("isn't available for your plan"),
        findsNothing,
      );
      // Three stages on a plan that allows two: nothing more can be added.
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Add a stage'),
            )
            .onPressed,
        isNull,
      );

      await _tapStage(tester, 'Choose who is told at stage', 3);
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Brother'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Use these people'));
      await tester.pumpAndSettle();
      await _tapButton(tester, 'Save changes');
      await _frames(tester);
      await tester.pumpAndSettle();
      expect(fakes.plan.stages, hasLength(3));
      expect(fakes.plan.stages[1].offsetMinutes, 1000);
      expect(fakes.plan.stages.last.contactIds, ['c1', 'c2']);
    });
  });

  group('editing', () {
    testWidgets('a grace choice changes the sentence and the first stage', (
      tester,
    ) async {
      final fakes = _world();
      await _open(tester, fakes);
      await tester.tap(find.widgetWithText(ChoiceChip, '6 hours').first);
      await tester.pumpAndSettle();
      expect(
        find.text(
          "If you miss a check-in, we'll remind you for 6 hours before anyone is contacted.",
        ),
        findsOneWidget,
      );
      expect(find.text('Stage 1: after 6 hours'), findsOneWidget);
      expect(
        find.text('At 2:00 AM the next day, Mom is notified.'),
        findsOneWidget,
      );
      expect(_saveEnabled(tester), isTrue);
      expect(find.text('Discard changes'), findsOneWidget);
      expect(fakes.plan.calls, ['get'], reason: 'nothing is sent by editing');

      await tapText(tester, 'Discard changes');
      await tester.pumpAndSettle();
      expect(find.text('Stage 1: after 3 hours'), findsOneWidget);
      expect(_saveEnabled(tester), isFalse);
    });

    testWidgets('a grace period of the person\'s own', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      await tapText(tester, 'Choose another length of time');
      await tester.pumpAndSettle();
      expect(
        find.text('How long should we wait before telling anyone?'),
        findsWidgets,
      );

      await tester.enterText(find.widgetWithText(TextField, 'Hours'), '5');
      await tester.enterText(find.widgetWithText(TextField, 'Minutes'), '30');
      await tester.pump();
      expect(
        find.text('That is 330 minutes after a missed check-in.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Use this time'));
      await tester.pumpAndSettle();
      expect(find.text('Stage 1: after 330 minutes'), findsOneWidget);
    });

    testWidgets('a time the account cannot have is explained and cannot be '
        'used', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      await tapText(tester, 'Choose another length of time');
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Minutes'), '20');
      await tester.pump();
      expect(
        find.text('The wait can be from 1 hour to 3 days.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Use this time'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Stage 1: after 3 hours'), findsOneWidget);
    });

    testWidgets('change the time of a later stage: only times that fit are '
        'offered', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      await _tapStage(tester, 'Change the time of stage', 2);
      // 3 hours is stage 1's own time: too close, so it cannot be chosen.
      final threeHours = tester.widget<ChoiceChip>(_chip('3 hours'));
      expect(threeHours.onSelected, isNull);
      expect(find.textContaining("Some times can't be chosen"), findsOneWidget);
      await _pickTime(tester, '2 days');
      expect(find.text('Stage 2: after 2 days'), findsOneWidget);
      expect(
        find.text('At 8:00 PM, 2 days later, Brother is notified.'),
        findsOneWidget,
      );
    });

    testWidgets('a custom time for a later stage, with the check against the '
        'stage before it', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      await _tapStage(tester, 'Change the time of stage', 2);

      await tester.enterText(find.widgetWithText(TextField, 'Minutes'), '190');
      await tester.pump();
      expect(
        find.text(
          'This stage needs to be at least 30 minutes after the one before it.',
        ),
        findsOneWidget,
      );
      await tester.enterText(find.widgetWithText(TextField, 'Days'), '1');
      await tester.enterText(find.widgetWithText(TextField, 'Hours'), '2');
      await tester.enterText(find.widgetWithText(TextField, 'Minutes'), '');
      await tester.pump();
      expect(
        find.text('That is 26 hours after a missed check-in.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Use this time'));
      await tester.pumpAndSettle();
      expect(find.text('Stage 2: after 26 hours'), findsOneWidget);

      // Choosing a suggested time afterwards clears what was typed.
      await _tapStage(tester, 'Change the time of stage', 2);
      await tester.tap(_chip('3 days'));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Days'))
            .controller!
            .text,
        isEmpty,
      );
    });

    testWidgets('choose who is told: a person who has not accepted yet is '
        'said plainly', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      await _tapStage(tester, 'Choose who is told at stage', 2);
      expect(find.text('Who is told at stage 2?'), findsOneWidget);
      expect(find.text('Waiting for them to accept.'), findsOneWidget);
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Sam'));
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Mom'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Use these people'));
      await tester.pumpAndSettle();

      expect(find.text('Notify: Mom, Brother and Sam'), findsOneWidget);
      expect(
        find.text(
          "Sam hasn't accepted yet, so they won't be told until they do.",
        ),
        findsOneWidget,
      );
      expect(_saveEnabled(tester), isTrue);
    });

    testWidgets('closing the sheet changes nothing', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      await _tapStage(tester, 'Choose who is told at stage', 1);
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Mom'));
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Notify: Mom'), findsOneWidget);
      expect(_saveEnabled(tester), isFalse);
    });

    testWidgets('people who declined, and stages nobody is chosen for, are '
        'warned about on the stage and at the top', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      await _tapStage(tester, 'Choose who is told at stage', 1);
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Mom'));
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Dad'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Use these people'));
      await tester.pumpAndSettle();
      expect(
        find.text("Dad won't be told. They said no, so we won't contact them."),
        findsOneWidget,
      );

      await _tapStage(tester, 'Choose who is told at stage', 2);
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Brother'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Use these people'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          "Nobody is chosen for this stage, so it wouldn't tell anyone.",
        ),
        findsOneWidget,
      );
      expect(find.text('Nobody to notify yet'), findsOneWidget);
      // Dad has not accepted: nobody who can be told is chosen.
      expect(
        find.text(
          'Nobody you chose has accepted yet. If you miss a check-in, nobody can be told until someone does.',
        ),
        findsOneWidget,
      );
      // Advice only: it can still be saved.
      expect(_saveEnabled(tester), isTrue);
    });

    testWidgets('a plan nobody is chosen for says so at the top', (
      tester,
    ) async {
      final fakes = _world();
      await _open(tester, fakes);
      for (final stage in [1, 2]) {
        await _tapStage(tester, 'Choose who is told at stage', stage);
        await tester.tap(
          find.widgetWithText(CheckboxListTile, stage == 1 ? 'Mom' : 'Brother'),
        );
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Use these people'));
        await tester.pumpAndSettle();
      }
      expect(
        find.text(
          'No stage has anyone to tell. If you miss a check-in, nobody is told.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('without trusted contacts the sheet leads to adding one', (
      tester,
    ) async {
      final fakes = _world(contacts: const []);
      fakes.plan.seed(
        const PlanDraft(
          graceMinutes: 180,
          stages: [PlanStageDraft(offsetMinutes: 180, contactIds: [])],
        ),
      );
      await _open(tester, fakes);
      await _tapStage(tester, 'Choose who is told at stage', 1);
      expect(
        find.textContaining('You have no trusted contacts yet'),
        findsOneWidget,
      );
      await tester.tap(
        find.widgetWithText(FilledButton, 'Add a trusted contact'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Their name'), findsOneWidget);
    });

    testWidgets('add a stage: pick its time; it tells nobody until chosen', (
      tester,
    ) async {
      final fakes = _world();
      await _open(tester, fakes);
      await tapText(tester, 'Add a stage');
      await tester.pumpAndSettle();
      expect(find.text('When should the new stage run?'), findsOneWidget);
      // 1 day is taken by stage 2.
      expect(tester.widget<ChoiceChip>(_chip('1 day')).onSelected, isNull);
      await _pickTime(tester, '3 days');
      expect(find.text('Stage 3: after 3 days'), findsOneWidget);
      expect(find.text('Nobody to notify yet'), findsOneWidget);
      expect(
        find.text(
          "Nobody is chosen for this stage, so it wouldn't tell anyone.",
        ),
        findsOneWidget,
      );
      expect(_saveEnabled(tester), isTrue);
    });

    testWidgets('adding to a plan with no stage makes the first stage, at '
        'the end of the grace period', (tester) async {
      final fakes = TestFakes()
        ..contacts = InMemoryContactsRepository(
          tier: 'premium',
          initial: _people(),
        );
      await _open(tester, fakes);
      expect(
        find.text(
          'Your plan has no stage. If you miss a check-in, nobody is told.',
        ),
        findsOneWidget,
      );
      expect(_saveEnabled(tester), isFalse);
      await tapText(tester, 'Add a stage');
      await tester.pumpAndSettle();
      expect(find.text('Stage 1: after 3 hours'), findsOneWidget);
      expect(find.text('When should the new stage run?'), findsNothing);
      // It tells nobody yet, so it is still not a plan that can tell anyone.
      await _tapStage(tester, 'Choose who is told at stage', 1);
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Mom'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Use these people'));
      await tester.pumpAndSettle();
      expect(_saveEnabled(tester), isTrue);
      await _tapButton(tester, 'Save changes');
      expect(fakes.plan.saved.single['stages'], [
        {
          'id': null,
          'offset_minutes': 180,
          'notify_contact_ids': ['c1'],
        },
      ]);
    });

    testWidgets('the only stage cannot be removed; others can, after asking', (
      tester,
    ) async {
      final fakes = _world();
      await _open(tester, fakes);
      expect(find.text('Remove stage'), findsNWidgets(2));
      await _tapStage(tester, 'Remove stage', 2);
      expect(find.text('Remove stage 2?'), findsOneWidget);
      expect(
        find.text(
          'Brother will no longer be told at this time. Nothing changes until you save.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Stage 2: after 1 day'), findsOneWidget);

      await _tapStage(tester, 'Remove stage', 2);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove stage'));
      await tester.pumpAndSettle();
      expect(find.text('Stage 2: after 1 day'), findsNothing);
      expect(find.text('Remove stage'), findsNothing, reason: 'the only one');
      expect(fakes.plan.stages, hasLength(2), reason: 'nothing saved yet');
    });

    testWidgets('a stage nobody is chosen for is removed without naming '
        'anyone', (tester) async {
      final fakes = _world();
      fakes.plan.seed(
        PlanDraft(
          graceMinutes: 180,
          stages: [
            PlanStageDraft(
              id: fakes.plan.stages.first.id,
              offsetMinutes: 180,
              contactIds: const ['c1'],
            ),
            PlanStageDraft(
              id: fakes.plan.stages.last.id,
              offsetMinutes: 1440,
              contactIds: const [],
            ),
          ],
        ),
      );
      await _open(tester, fakes);
      await _tapStage(tester, 'Remove stage', 2);
      expect(
        find.text(
          'This stage tells nobody yet. Nothing changes until you save.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Remove stage'));
      await tester.pumpAndSettle();
      expect(find.text('Stage 2: after 1 day'), findsNothing);
    });

    testWidgets('a stage that was only just added is removed without asking', (
      tester,
    ) async {
      final fakes = _world();
      await _open(tester, fakes);
      await tapText(tester, 'Add a stage');
      await tester.pumpAndSettle();
      await _pickTime(tester, '3 days');
      expect(find.text('Stage 3: after 3 days'), findsOneWidget);
      await _tapStage(tester, 'Remove stage', 3);
      expect(find.text('Stage 3: after 3 days'), findsNothing);
      expect(find.text('Remove stage 3?'), findsNothing);
      expect(_saveEnabled(tester), isFalse, reason: 'back to the saved plan');
    });

    testWidgets('removing the first stage says that the next one becomes the '
        'first', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      await _tapStage(tester, 'Remove stage', 1);
      expect(
        find.textContaining(
          'The next stage becomes the first, so we would wait 1 day before telling anyone.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Remove stage'));
      await tester.pumpAndSettle();
      expect(find.text('Stage 1: after 1 day'), findsOneWidget);
      expect(
        find.text(
          "If you miss a check-in, we'll remind you for 1 day before anyone is contacted.",
        ),
        findsOneWidget,
      );
    });
  });

  group('instructions shared at a stage', () {
    testWidgets('each stage says how many; the preview counts them', (
      tester,
    ) async {
      final fakes = _world();
      fakes.instructions.seed(
        title: 'House emergency',
        recipients: {'c2': fakes.plan.stages.last.id},
      );
      await _open(tester, fakes);
      expect(
        find.text('1 instruction will be shared at this stage'),
        findsOneWidget,
      );
      expect(
        find.text(
          'At 8:00 PM the next day, Brother is notified. 1 instruction is also shared.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a screen reader hears one sentence for the facts of a stage', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final fakes = _world();
      fakes.instructions.seed(
        title: 'House emergency',
        recipients: {'c2': fakes.plan.stages.last.id},
      );
      await _open(tester, fakes);
      expect(
        find.bySemanticsLabel(
          'Stage 2, 1 day after the deadline, notifies Brother, 1 instruction will be shared at this stage',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Stage 1, 3 hours after the deadline, notifies Mom',
        ),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Remove stage 2'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Choose who is told at stage 1'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('a stage that shares instructions cannot be removed: the sheet '
        'names them and the window is secure while it does', (tester) async {
      final fakes = _world();
      fakes.instructions.seed(
        title: 'House emergency',
        recipients: {'c2': fakes.plan.stages.last.id},
      );
      fakes.instructions.seed(
        title: 'Old note',
        status: InstructionStatus.inactive,
        recipients: {'c2': fakes.plan.stages.last.id},
      );
      await _open(tester, fakes);
      expect(fakes.secureScreen.calls, isEmpty);

      await _tapStage(tester, 'Remove stage', 2);
      expect(find.text("Stage 2 can't be removed yet"), findsOneWidget);
      expect(
        find.text('2 instructions are set to be shared at this stage:'),
        findsOneWidget,
      );
      expect(find.text('House emergency'), findsOneWidget);
      expect(find.text('Old note'), findsOneWidget);
      expect(fakes.secureScreen.secure, isTrue);

      await tapText(tester, 'Close');
      await tester.pumpAndSettle();
      expect(find.text('House emergency'), findsNothing);
      expect(fakes.secureScreen.secure, isFalse);
      expect(find.text('Stage 2: after 1 day'), findsOneWidget, reason: 'kept');
    });

    testWidgets('a stage that shares instructions cannot be moved earlier than '
        'a day', (tester) async {
      final fakes = _world();
      fakes.instructions.seed(
        title: 'House emergency',
        recipients: {'c2': fakes.plan.stages.last.id},
      );
      await _open(tester, fakes);
      await _tapStage(tester, 'Change the time of stage', 2);
      await tester.enterText(find.widgetWithText(TextField, 'Hours'), '12');
      await tester.pump();
      expect(
        find.text(
          'This stage shares instructions, so it must be at least 1 day after a missed check-in.',
        ),
        findsOneWidget,
      );
      expect(tester.widget<ChoiceChip>(_chip('6 hours')).onSelected, isNull);
    });

    testWidgets('a grace period that would put the first stage (with '
        'instructions) under a day is not offered', (tester) async {
      final fakes = TestFakes()
        ..contacts = InMemoryContactsRepository(
          tier: 'premium',
          initial: _people(),
        );
      fakes.plan.seed(
        const PlanDraft(
          graceMinutes: 1440,
          stages: [
            PlanStageDraft(offsetMinutes: 1440, contactIds: ['c1']),
          ],
        ),
      );
      fakes.instructions.seed(
        title: 'House emergency',
        recipients: {'c1': fakes.plan.stages.first.id},
      );
      await _open(tester, fakes);
      final sixHours = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '6 hours').first,
      );
      expect(sixHours.onSelected, isNull);
    });
  });

  group('saving', () {
    testWidgets('sends the plan with the ids of the stages it keeps, then '
        'says so and goes back to the Plan tab', (tester) async {
      final fakes = _world();
      final stageOne = fakes.plan.stages.first.id;
      await openApp(tester, fakes: fakes, route: AppRoutes.plan);
      await tapText(tester, 'Edit your plan');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '6 hours').first);
      await tester.pumpAndSettle();
      await _tapStage(tester, 'Choose who is told at stage', 1);
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Brother'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Use these people'));
      await tester.pumpAndSettle();

      await _tapButton(tester, 'Save changes');
      await _frames(tester);
      await tester.pumpAndSettle();

      expect(fakes.plan.ifMatches, ['"plan-2"']);
      expect(fakes.plan.saved.single['grace_minutes'], 360);
      final stages = fakes.plan.saved.single['stages']! as List;
      expect((stages[0] as Map)['id'], stageOne);
      expect((stages[0] as Map)['offset_minutes'], 360);
      expect((stages[0] as Map)['notify_contact_ids'], ['c1', 'c2']);
      expect(fakes.plan.stages.first.offsetMinutes, 360);

      expect(find.byType(PlanEditorScreen), findsNothing);
      expect(find.byType(PlanScreen), findsOneWidget);
      expect(find.text('Your plan was saved.'), findsOneWidget);
      expect(find.text('Stage 1: after 6 hours'), findsOneWidget);
      expect(find.text('Notify: Mom and Brother'), findsOneWidget);
    });

    testWidgets('while it is on the wire the button is busy and nothing else '
        'can be changed', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      await tester.tap(find.widgetWithText(ChoiceChip, '6 hours').first);
      await tester.pumpAndSettle();
      final gate = Completer<void>();
      fakes.plan.gate = gate.future;
      await _tapButtonNoSettle(tester, 'Save changes');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(
        tester
            .widget<ChoiceChip>(
              find.widgetWithText(ChoiceChip, '12 hours').first,
            )
            .onSelected,
        isNull,
      );
      expect(find.text('Add a stage'), findsOneWidget);
      gate.complete();
      await _frames(tester);
      await tester.pumpAndSettle();
      expect(fakes.plan.saved, hasLength(1));
    });

    testWidgets('a time that does not fit says so on the stage and keeps '
        'Save off, without sending anything', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      // A grace period of 1 day is where stage 2 already is.
      await tester.tap(find.widgetWithText(ChoiceChip, '1 day').first);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This stage needs to be at least 30 minutes after the one before it.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Fix the times marked above before saving.'),
        findsOneWidget,
      );
      expect(_saveEnabled(tester), isFalse);
      expect(fakes.plan.saved, isEmpty);
    });

    testWidgets('a network failure keeps every edit and the same save can be '
        'sent again', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      await tester.tap(find.widgetWithText(ChoiceChip, '6 hours').first);
      await tester.pumpAndSettle();
      fakes.plan.failures['save'] = [const NetworkFailure()];
      await _tapButton(tester, 'Save changes');
      expect(
        find.textContaining("We couldn't confirm that this was saved"),
        findsOneWidget,
      );
      expect(find.text('Stage 1: after 6 hours'), findsOneWidget);
      expect(find.text('Your plan was saved.'), findsNothing);
      expect(find.byType(PlanEditorScreen), findsOneWidget);
      expect(_saveEnabled(tester), isTrue);

      await _tapButton(tester, 'Save changes');
      await _frames(tester);
      await tester.pumpAndSettle();
      expect(fakes.plan.graceMinutes, 360);
      expect(find.text('Your plan was saved.'), findsOneWidget);
    });

    testWidgets('a stale plan (412): the latest is loaded, the edits are still '
        'there, and "use the latest" drops them', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      await tester.tap(find.widgetWithText(ChoiceChip, '6 hours').first);
      await tester.pumpAndSettle();
      fakes.plan.seed(
        PlanDraft(
          graceMinutes: 180,
          stages: [
            PlanStageDraft(
              id: fakes.plan.stages.first.id,
              offsetMinutes: 180,
              contactIds: const ['c1', 'c2'],
            ),
            PlanStageDraft(
              id: fakes.plan.stages.last.id,
              offsetMinutes: 1440,
              contactIds: const ['c2'],
            ),
          ],
        ),
      );
      await _tapButton(tester, 'Save changes');
      expect(
        find.textContaining('Your plan was changed somewhere else'),
        findsOneWidget,
      );
      expect(
        find.text('Stage 1: after 6 hours'),
        findsOneWidget,
        reason: 'kept',
      );
      expect(
        find.text('Notify: Mom'),
        findsOneWidget,
        reason: 'mine, not theirs',
      );

      await tapText(tester, 'Use the latest plan instead');
      await tester.pumpAndSettle();
      expect(find.text('Stage 1: after 3 hours'), findsOneWidget);
      expect(find.text('Notify: Mom and Brother'), findsOneWidget);
      expect(
        find.textContaining('Your plan was changed somewhere else'),
        findsNothing,
      );
      expect(_saveEnabled(tester), isFalse);
    });

    testWidgets('after a 412 the next save goes through with the latest '
        'version', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      await tester.tap(find.widgetWithText(ChoiceChip, '6 hours').first);
      await tester.pumpAndSettle();
      fakes.plan.seed(
        PlanDraft(
          graceMinutes: 180,
          stages: [
            PlanStageDraft(
              id: fakes.plan.stages.first.id,
              offsetMinutes: 180,
              contactIds: const ['c1'],
            ),
            PlanStageDraft(
              id: fakes.plan.stages.last.id,
              offsetMinutes: 1440,
              contactIds: const ['c1', 'c2'],
            ),
          ],
        ),
      );
      await _tapButton(tester, 'Save changes');
      await _tapButton(tester, 'Save changes');
      await _frames(tester);
      await tester.pumpAndSettle();
      expect(fakes.plan.ifMatches, ['"plan-2"', '"plan-3"']);
      expect(fakes.plan.graceMinutes, 360);
      expect(find.text('Your plan was saved.'), findsOneWidget);
    });

    testWidgets('the server\'s field errors are said on the stages', (
      tester,
    ) async {
      final fakes = _world();
      await _open(tester, fakes);
      await tester.tap(find.widgetWithText(ChoiceChip, '6 hours').first);
      await tester.pumpAndSettle();
      fakes.plan.failures['save'] = [
        _invalid(const [
          ApiFieldError(
            field: 'grace_minutes',
            code: 'not_a_preset',
            message: 'server words',
          ),
          ApiFieldError(
            field: 'stages[1].offset_minutes',
            code: 'too_close',
            message: 'server words',
          ),
        ]),
      ];
      await _tapButton(tester, 'Save changes');
      expect(
        find.text(
          "That wait isn't available for your plan. Choose one of the times shown.",
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'This stage needs to be at least 30 minutes after the one before it.',
        ),
        findsOneWidget,
      );
      expect(find.text('server words'), findsNothing);
      expect(_saveEnabled(tester), isFalse);
      // Changing something takes the old answer away.
      final chip = find.widgetWithText(ChoiceChip, '12 hours').first;
      await tester.ensureVisible(chip);
      await tester.pump();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.textContaining('at least 30 minutes after'), findsNothing);
      expect(_saveEnabled(tester), isTrue);
    });

    testWidgets('a limit the app did not know about (403) is said calmly and '
        'keeps the edits', (tester) async {
      final fakes = _world(tier: 'free');
      await _open(tester, fakes);
      await tester.tap(find.widgetWithText(ChoiceChip, '6 hours').first);
      await tester.pumpAndSettle();
      fakes.plan.failures['save'] = [
        const PlanLimitFailure(resource: 'stages', limit: 2, current: 3),
      ];
      await _tapButton(tester, 'Save changes');
      expect(
        find.text("You've reached the number of stages your account includes."),
        findsOneWidget,
      );
      expect(find.text('Stage 1: after 6 hours'), findsOneWidget);
    });

    testWidgets('someone who is gone (404): reloaded, dropped from the stage, '
        'the rest kept', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      await _tapStage(tester, 'Choose who is told at stage', 1);
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Sam'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Use these people'));
      await tester.pumpAndSettle();
      // Sam was removed on another device.
      await fakes.contacts.delete('c3');
      await _tapButton(tester, 'Save changes');
      expect(
        find.textContaining("Something in your plan can't be found any more"),
        findsOneWidget,
      );
      expect(find.text('Notify: Mom'), findsOneWidget);
      expect(find.textContaining('Sam'), findsNothing);
    });
  });

  group('while check-ins are on', () {
    testWidgets('the password is asked for with the reason, then the very '
        'same save is sent again', (tester) async {
      final fakes = _world(active: true);
      await _open(tester, fakes);
      await tester.tap(find.widgetWithText(ChoiceChip, '6 hours').first);
      await tester.pumpAndSettle();
      await _tapButtonNoSettle(tester, 'Save changes');
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(
        find.text(
          'Changing your plan needs your password because it decides who is told.',
        ),
        findsOneWidget,
      );
      expect(fakes.plan.graceMinutes, 180);

      await typeInto(tester, 'Password', fakes.auth.password);
      await tapText(tester, 'Confirm');
      await _frames(tester);
      await tester.pumpAndSettle();

      expect(fakes.plan.calls.where((c) => c == 'save'), hasLength(2));
      expect(fakes.plan.ifMatches, ['"plan-2"', '"plan-2"']);
      expect(fakes.plan.saved[0], fakes.plan.saved[1]);
      expect(fakes.plan.graceMinutes, 360);
      expect(find.text('Your plan was saved.'), findsOneWidget);
      expect(fakes.auth.calls.where((c) => c == 'reauth'), hasLength(1));
    });

    testWidgets('closing the password sheet keeps the edits and says '
        'nothing', (tester) async {
      final fakes = _world(active: true);
      await _open(tester, fakes);
      await tester.tap(find.widgetWithText(ChoiceChip, '6 hours').first);
      await tester.pumpAndSettle();
      await _tapButtonNoSettle(tester, 'Save changes');
      await _frames(tester);
      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      await tester.pumpAndSettle();

      expect(find.text("Confirm it's you"), findsNothing);
      expect(find.byType(FailureNotice), findsNothing);
      expect(find.text('Stage 1: after 6 hours'), findsOneWidget);
      expect(fakes.plan.calls.where((c) => c == 'save'), hasLength(1));
      expect(_saveEnabled(tester), isTrue);
      expect(find.byType(PlanEditorScreen), findsOneWidget);
    });

    testWidgets('a wrong password stays in the sheet and sends nothing '
        'more', (tester) async {
      final fakes = _world(active: true);
      await _open(tester, fakes);
      await tester.tap(find.widgetWithText(ChoiceChip, '6 hours').first);
      await tester.pumpAndSettle();
      await _tapButtonNoSettle(tester, 'Save changes');
      await _frames(tester);
      await typeInto(tester, 'Password', 'not the password at all');
      await tapText(tester, 'Confirm');
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(
        find.text("That password didn't match. Try again."),
        findsOneWidget,
      );
      expect(fakes.plan.calls.where((c) => c == 'save'), hasLength(1));
      expect(fakes.plan.graceMinutes, 180);

      await typeInto(tester, 'Password', fakes.auth.password);
      await tapText(tester, 'Confirm');
      await _frames(tester);
      await tester.pumpAndSettle();
      expect(fakes.plan.graceMinutes, 360);
    });

    testWidgets('a plan that would tell nobody is asked about first', (
      tester,
    ) async {
      final fakes = _world(active: true);
      fakes.auth.reauthenticated = true;
      await _open(tester, fakes);
      for (final stage in [1, 2]) {
        await _tapStage(tester, 'Choose who is told at stage', stage);
        await tester.tap(
          find.widgetWithText(CheckboxListTile, stage == 1 ? 'Mom' : 'Brother'),
        );
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Use these people'));
        await tester.pumpAndSettle();
      }
      await _tapButton(tester, 'Save changes');
      expect(find.text('Nobody would be told'), findsOneWidget);
      expect(fakes.plan.saved, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(fakes.plan.saved, isEmpty);
      expect(find.byType(PlanEditorScreen), findsOneWidget);

      await _tapButton(tester, 'Save changes');
      await tester.tap(find.widgetWithText(FilledButton, 'Save anyway'));
      await _frames(tester);
      await tester.pumpAndSettle();
      expect(fakes.plan.saved, hasLength(1));
      expect(fakes.plan.stages.every((s) => s.contactIds.isEmpty), isTrue);
    });
  });

  group('while a check-in is overdue', () {
    testWidgets('the editor is read-only with a calm explanation', (
      tester,
    ) async {
      final fakes = _world(active: true);
      fakes.server.openIncident();
      await _open(tester, fakes);
      expect(find.text("Your plan can't change right now"), findsOneWidget);
      expect(
        find.text(
          "Your plan can't change while a check-in is overdue. Check in first, then come back to make changes.",
        ),
        findsOneWidget,
      );
      // The plan is still shown; nothing can be changed.
      expect(find.text('Stage 1: after 3 hours'), findsOneWidget);
      expect(find.text('Notify: Mom'), findsOneWidget);
      expect(find.text('Save changes'), findsNothing);
      expect(find.text('Add a stage'), findsNothing);
      expect(find.text('Change time'), findsNothing);
      expect(find.text('Choose who is told'), findsNothing);
      expect(find.text('Remove stage'), findsNothing);
      for (final chip in tester.widgetList<ChoiceChip>(
        find.byType(ChoiceChip),
      )) {
        expect(chip.onSelected, isNull);
      }
      expect(find.text('Choose another length of time'), findsNothing);
    });

    testWidgets('an incident that opened meanwhile is learnt from the '
        'server\'s answer, and the edits are still shown', (tester) async {
      final fakes = _world(active: true);
      fakes.auth.reauthenticated = true;
      await _open(tester, fakes);
      await tester.tap(find.widgetWithText(ChoiceChip, '6 hours').first);
      await tester.pumpAndSettle();
      fakes.server.openIncident();
      await _tapButton(tester, 'Save changes');
      expect(find.text("Your plan can't change right now"), findsOneWidget);
      expect(find.text('Stage 1: after 6 hours'), findsOneWidget);
      expect(find.text('Save changes'), findsNothing);
      expect(fakes.plan.graceMinutes, 180);
    });
  });

  group('stages that still share instructions', () {
    testWidgets('the server\'s answer puts the stage back and names the '
        'instructions', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      // The list on the phone does not know yet (it was made on another device).
      fakes.instructions.seed(
        title: 'House emergency',
        status: InstructionStatus.inactive,
        recipients: {'c2': fakes.plan.stages.last.id},
      );
      await _tapStage(tester, 'Remove stage', 2);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove stage'));
      await tester.pumpAndSettle();
      expect(find.text('Stage 2: after 1 day'), findsNothing);

      await _tapButton(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('A stage you removed still shares instructions'),
        findsOneWidget,
      );
      expect(find.textContaining('House emergency'), findsOneWidget);
      expect(find.text('Stage 2: after 1 day'), findsOneWidget, reason: 'back');
      expect(fakes.secureScreen.secure, isTrue, reason: 'a title is on screen');
      expect(fakes.plan.stages, hasLength(2));
    });
  });

  group('stages that still share instructions, list unavailable', () {
    testWidgets('the notice still says it, without names', (tester) async {
      final fakes = _world();
      await _open(tester, fakes);
      fakes.instructions.seed(
        title: 'House emergency',
        status: InstructionStatus.inactive,
        recipients: {'c2': fakes.plan.stages.last.id},
      );
      fakes.instructions.failures['list'] = [
        const NetworkFailure(),
        const NetworkFailure(),
      ];
      await _tapStage(tester, 'Remove stage', 2);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove stage'));
      await tester.pumpAndSettle();
      await _tapButton(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(
        find.text(
          'A stage you removed still shares instructions, so it was put back. Choose another time for these instructions first.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('House emergency'), findsNothing);
      expect(find.text('Stage 2: after 1 day'), findsOneWidget);
      expect(fakes.secureScreen.secure, isFalse);
    });
  });

  group('leaving', () {
    testWidgets('with nothing changed, back leaves at once', (tester) async {
      final fakes = _world();
      await openApp(tester, fakes: fakes, route: AppRoutes.plan);
      await tapText(tester, 'Edit your plan');
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(PlanEditorScreen), findsNothing);
      expect(find.byType(PlanScreen), findsOneWidget);
    });

    testWidgets('with changes, back asks; keep editing stays, leave drops '
        'them', (tester) async {
      final fakes = _world();
      await openApp(tester, fakes: fakes, route: AppRoutes.plan);
      await tapText(tester, 'Edit your plan');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '6 hours').first);
      await tester.pumpAndSettle();

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Leave without saving?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.byType(PlanEditorScreen), findsOneWidget);
      expect(find.text('Stage 1: after 6 hours'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(find.byType(PlanEditorScreen), findsNothing);
      expect(find.byType(PlanScreen), findsOneWidget);
      expect(fakes.plan.saved, isEmpty);
      expect(find.text('Stage 1: after 3 hours'), findsOneWidget);
    });

    testWidgets('tapping the Plan tab again asks the same question as Back and '
        'does not throw the draft away', (tester) async {
      // The tab bar used to reset the branch to its first page without asking: the
      // editor's PopScope was bypassed and its autoDispose draft was gone.
      final fakes = _world();
      await openApp(tester, fakes: fakes, route: AppRoutes.plan);
      await tapText(tester, 'Edit your plan');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '6 hours').first);
      await tester.pumpAndSettle();
      final tab = find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Plan'),
      );

      await tester.tap(tab);
      await tester.pumpAndSettle();
      expect(find.text('Leave without saving?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.byType(PlanEditorScreen), findsOneWidget);
      expect(
        find.text('Stage 1: after 6 hours'),
        findsOneWidget,
        reason: 'the edit is still there',
      );

      await tester.tap(tab);
      await tester.pumpAndSettle();
      expect(find.text('Leave without saving?'), findsOneWidget);
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(find.byType(PlanEditorScreen), findsNothing);
      expect(find.byType(PlanScreen), findsOneWidget);
      expect(fakes.plan.saved, isEmpty);
    });

    testWidgets('with nothing to lose the tab still goes back to the first '
        'page', (tester) async {
      final fakes = _world();
      await openApp(tester, fakes: fakes, route: AppRoutes.plan);
      await tapText(tester, 'Edit your plan');
      await tester.pumpAndSettle();
      expect(find.byType(PlanEditorScreen), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Plan'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Leave without saving?'), findsNothing);
      expect(find.byType(PlanEditorScreen), findsNothing);
      expect(find.byType(PlanScreen), findsOneWidget);
    });
  });
}

Future<void> _tapButtonNoSettle(WidgetTester tester, String label) async {
  final finder = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}
