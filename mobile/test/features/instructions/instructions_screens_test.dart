import 'dart:async';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/instructions/application/instruction_autosave.dart';
import 'package:afterme/features/instructions/application/instructions_controller.dart';
import 'package:afterme/features/instructions/data/instructions_repository.dart';
import 'package:afterme/features/instructions/presentation/add_instruction_screen.dart';
import 'package:afterme/features/instructions/presentation/edit_instruction_screen.dart';
import 'package:afterme/features/instructions/presentation/instruction_detail_screen.dart';
import 'package:afterme/features/instructions/presentation/instructions_screen.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

/// Mom (accepted), Sam (has not accepted yet) and Dad (said no), and a plan with three
/// stages: after 3 hours (who is told first), after 1 day and after 2 days (the two that
/// can release an instruction).
///
/// [stageOffsets] replaces the stages (minutes after the missed check-in): a free plan
/// with two stages that are both early has no room for another and no stage that can
/// release anything.
TestFakes _world({
  String tier = 'premium',
  int lateStages = 2,
  List<int>? stageOffsets,
  List<TrustedContact>? contacts,
}) {
  final fakes = TestFakes()
    ..contacts = InMemoryContactsRepository(
      tier: tier,
      initial:
          contacts ??
          [
            testContact(),
            testContact(
              id: 'c2',
              name: 'Sam',
              email: 'sam@example.com',
              priority: 2,
              status: VerificationStatus.pending,
            ),
            testContact(
              id: 'c3',
              name: 'Dad',
              relationship: ContactRelationship.father,
              email: 'dad@example.com',
              priority: 3,
              status: VerificationStatus.declined,
            ),
          ],
    );
  fakes.plan.seed(
    PlanDraft(
      graceMinutes: 180,
      stages: stageOffsets != null
          ? [
              for (final offset in stageOffsets)
                PlanStageDraft(offsetMinutes: offset, contactIds: const ['c1']),
            ]
          : [
              const PlanStageDraft(offsetMinutes: 180, contactIds: ['c1']),
              if (lateStages >= 1)
                const PlanStageDraft(offsetMinutes: 1440, contactIds: ['c1']),
              if (lateStages >= 2)
                const PlanStageDraft(offsetMinutes: 2880, contactIds: ['c1']),
            ],
    ),
  );
  return fakes;
}

String _stage(TestFakes fakes, int position) =>
    fakes.plan.stages.firstWhere((s) => s.position == position).id;

Finder _field(String label) => find.widgetWithText(TextField, label);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder.first);
  await tester.pump();
  await tester.tap(finder.first);
  await tester.pump();
}

Future<void> _chip(WidgetTester tester, String label) =>
    _tap(tester, find.widgetWithText(ChoiceChip, label));

Future<void> _tick(WidgetTester tester, String name) =>
    _tap(tester, find.widgetWithText(CheckboxListTile, name));

Future<void> _stagePick(WidgetTester tester, String label) =>
    _tap(tester, find.widgetWithText(RadioListTile<String>, label));

const _afterOneDay = "If you haven't checked in for 1 day";
const _afterTwoDays = "If you haven't checked in for 2 days";

Future<void> _fill(
  WidgetTester tester, {
  String title = 'House emergency',
  String body = 'The spare key is with a neighbour.',
}) async {
  await typeInto(tester, 'Title', title);
  await tester.enterText(_field('What should they know?'), body);
  await tester.pump();
}

/// The text of a field's controller.
String _text(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;

String? _error(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).decoration?.errorText;

void main() {
  group('the list', () {
    testWidgets('empty: why it is worth writing one, a blank page and the six '
        'examples', (tester) async {
      await openApp(tester, fakes: _world(), route: AppRoutes.instructions);
      expect(find.byType(InstructionsScreen), findsOneWidget);
      expect(find.text('Write down what someone may need'), findsOneWidget);
      expect(
        find.textContaining(
          'Nothing is shared unless you stop checking in for the time you choose.',
        ),
        findsOneWidget,
      );
      expect(find.text('Write your own'), findsOneWidget);
      for (final title in [
        'Who to call first',
        'Home and keys',
        'Pets',
        'Work handover',
        'Where my documents are',
        'Insurance',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.byTooltip('Add instruction'), findsNothing);
    });

    testWidgets('an example opens the form with its title and text filled in', (
      tester,
    ) async {
      await openApp(tester, fakes: _world(), route: AppRoutes.instructions);
      await tapText(tester, 'Pets');
      await tester.pumpAndSettle();
      expect(find.byType(AddInstructionScreen), findsOneWidget);
      expect(_text(tester, 'Title'), 'Pets');
      expect(
        _text(tester, 'What should they know?'),
        startsWith("My pet's name is…"),
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Pets'))
            .selected,
        isTrue,
        reason: 'the example chooses its category',
      );
    });

    testWidgets('loading shows a progress indicator', (tester) async {
      final gate = Completer<void>();
      final fakes = _world()..instructions.listGate = gate.future;
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructions,
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('an error is calm and Try again recovers', (tester) async {
      final fakes = _world();
      fakes.instructions.failures['list'] = [const NetworkFailure()];
      await openApp(tester, fakes: fakes, route: AppRoutes.instructions);
      expect(find.textContaining("You're offline"), findsOneWidget);
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsNothing);
      expect(find.text('Write down what someone may need'), findsOneWidget);
    });

    testWidgets('cards are grouped by category and show title, status, who '
        'receives it and when', (tester) async {
      final fakes = _world();
      fakes.instructions
        ..seed(
          title: 'House emergency',
          category: InstructionCategory.home,
          recipients: {'c1': _stage(fakes, 2)},
        )
        ..seed(
          title: 'Spare papers',
          category: InstructionCategory.documents,
          status: InstructionStatus.inactive,
          recipients: {'c2': _stage(fakes, 3)},
        )
        ..seed(title: 'Goldfish', category: InstructionCategory.pets);
      await openApp(tester, fakes: fakes, route: AppRoutes.instructions);

      for (final heading in ['Home', 'Documents', 'Pets']) {
        expect(find.text(heading), findsWidgets, reason: heading);
      }
      expect(find.text('House emergency'), findsOneWidget);
      expect(find.text('Mom: After 1 day'), findsOneWidget);
      expect(find.text('Sam: After 2 days'), findsOneWidget);
      expect(find.text('Not shared with anyone yet'), findsOneWidget);
      expect(find.text('Active'), findsWidgets);
      expect(find.text('Inactive'), findsOneWidget);
      // Never colour alone: the word is in the text and in what is read out.
      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(
          RegExp(r'^Spare papers\. Documents\. Inactive\.'),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('a recipient who has not accepted gets a gentle note, and one '
        'who cannot be reached a different one', (tester) async {
      final fakes = _world();
      fakes.instructions.seed(
        title: 'Spare papers',
        recipients: {'c2': _stage(fakes, 2), 'c3': _stage(fakes, 2)},
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.instructions);
      expect(find.text("Sam hasn't accepted yet."), findsOneWidget);
      expect(
        find.text("Dad can't be reached right now. See People for what to do."),
        findsOneWidget,
      );
    });

    testWidgets('the filter shows one category at a time', (tester) async {
      final fakes = _world();
      fakes.instructions
        ..seed(title: 'House emergency', category: InstructionCategory.home)
        ..seed(title: 'Goldfish', category: InstructionCategory.pets);
      await openApp(tester, fakes: fakes, route: AppRoutes.instructions);
      expect(find.text('House emergency'), findsOneWidget);
      expect(find.text('Goldfish'), findsOneWidget);
      await _chip(tester, 'Pets');
      await tester.pumpAndSettle();
      expect(find.text('House emergency'), findsNothing);
      expect(find.text('Goldfish'), findsOneWidget);
      await _chip(tester, 'All');
      await tester.pumpAndSettle();
      expect(find.text('House emergency'), findsOneWidget);
    });

    testWidgets('a card opens the instruction', (tester) async {
      final fakes = _world();
      fakes.instructions.seed(
        title: 'House emergency',
        body: 'The spare key is with a neighbour.',
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.instructions);
      await tapText(tester, 'House emergency');
      await tester.pumpAndSettle();
      expect(find.byType(InstructionDetailScreen), findsOneWidget);
      expect(find.text('The spare key is with a neighbour.'), findsOneWidget);
    });

    testWidgets('the list is never given a body', (tester) async {
      final fakes = _world();
      fakes.instructions.seed(
        title: 'House emergency',
        body: 'a-body-that-must-not-be-kept',
      );
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructions,
      );
      final items = container.read(instructionsControllerProvider).value!;
      expect(items.single.toString(), isNot(contains('House emergency')));
      expect(find.textContaining('a-body-that-must-not-be-kept'), findsNothing);
    });
  });

  group('the free-plan limit', () {
    TestFakes full() {
      final fakes = _world(tier: 'free');
      for (var i = 1; i <= 3; i++) {
        fakes.instructions.seed(title: 'Note $i');
      }
      return fakes;
    }

    testWidgets('at three, Add opens the sheet: an explanation and Close '
        'only', (tester) async {
      final fakes = full();
      await openApp(tester, fakes: fakes, route: AppRoutes.instructions);
      await tapText(tester, 'Add instruction');
      await tester.pumpAndSettle();
      expect(
        find.text('More instructions are part of Premium'),
        findsOneWidget,
      );
      expect(
        find.text(
          'The free plan allows 3 instructions. Adding more is part of Premium. You can also delete one to make room for another.',
        ),
        findsOneWidget,
      );
      expect(find.text('Close'), findsOneWidget);
      expect(find.textContaining('Upgrade'), findsNothing);
      expect(find.textContaining('Subscribe'), findsNothing);
      expect(find.byType(AddInstructionScreen), findsNothing);
      await tapText(tester, 'Close');
      await tester.pumpAndSettle();
      expect(find.text('More instructions are part of Premium'), findsNothing);
    });

    testWidgets('a limit answer from the server opens the same sheet and keeps '
        'what was typed', (tester) async {
      final fakes = _world(tier: 'free');
      for (var i = 1; i <= 3; i++) {
        fakes.instructions.seed(title: 'Note $i');
      }
      // The app has not yet read the new usage: the server is the authority.
      fakes.contacts.instructionUsage = () => 0;
      await openApp(tester, fakes: fakes, route: AppRoutes.instructions);
      await tapText(tester, 'Add instruction');
      await tester.pumpAndSettle();
      expect(find.byType(AddInstructionScreen), findsOneWidget);
      await _chip(tester, 'Home');
      await _fill(tester);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(
        find.text('More instructions are part of Premium'),
        findsOneWidget,
      );
      await tapText(tester, 'Close');
      await tester.pumpAndSettle();
      expect(_text(tester, 'Title'), 'House emergency');
      expect(fakes.instructions.liveCount, 3);
    });
  });

  group('writing one', () {
    Future<TestFakes> open(
      WidgetTester tester, {
      TestFakes? fakes,
      String? starter,
    }) async {
      final f = fakes ?? _world();
      await openApp(tester, fakes: f, route: AppRoutes.instructionNew);
      return f;
    }

    testWidgets('category, title, text, who and when; the request is exactly '
        'that', (tester) async {
      final fakes = await open(tester);
      await _chip(tester, 'Home');
      await _fill(tester);
      expect(find.text('34 of 20,000 characters'), findsOneWidget);
      await _tick(tester, 'Mom');
      await _stagePick(tester, _afterOneDay);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();

      expect(fakes.instructions.created.single, {
        'category': 'home',
        'title': 'House emergency',
        'body': 'The spare key is with a neighbour.',
        'status': 'active',
        'recipients': [
          {'contact_id': 'c1', 'release_stage_id': _stage(fakes, 2)},
        ],
      });
      expect(snackText(tester), 'Instruction saved.');
      expect(find.byType(InstructionsScreen), findsOneWidget);
      expect(find.text('Mom: After 1 day'), findsOneWidget);
    });

    testWidgets('the category, the title and the text are required, and '
        'nothing is sent', (tester) async {
      final fakes = await open(tester);
      await tapText(tester, 'Save instruction');
      await tester.pump();
      expect(find.text('Choose a category.'), findsOneWidget);
      expect(_error(tester, 'Title'), 'Please fill this in.');
      expect(_error(tester, 'What should they know?'), 'Please fill this in.');
      expect(fakes.instructions.calls, isNot(contains('create')));
      await _chip(tester, 'Home');
      expect(find.text('Choose a category.'), findsNothing);
    });

    testWidgets('limits and characters are explained, not sent', (
      tester,
    ) async {
      final fakes = await open(tester);
      await _chip(tester, 'Work');
      await typeInto(tester, 'Title', 'x' * 121);
      await tester.enterText(
        _field('What should they know?'),
        'a\u202Eb', // a text-direction override
      );
      await tester.pump();
      await tapText(tester, 'Save instruction');
      await tester.pump();
      expect(
        _error(tester, 'Title'),
        'That title is too long. Use 120 characters or fewer.',
      );
      expect(
        _error(tester, 'What should they know?'),
        "This contains characters that can't be used. Remove them and try again.",
      );

      await typeInto(tester, 'Title', 'Fine');
      await tester.enterText(_field('What should they know?'), 'y' * 20001);
      await tester.pump();
      expect(find.text('20,001 of 20,000 characters'), findsOneWidget);
      await tapText(tester, 'Save instruction');
      await tester.pump();
      expect(
        _error(tester, 'What should they know?'),
        "That's too long. Use 20,000 characters or fewer.",
      );
      expect(fakes.instructions.calls, isNot(contains('create')));

      // Exactly 120 and 20,000 are fine, and line breaks and tabs are plain text.
      await typeInto(tester, 'Title', 'z' * 120);
      await tester.enterText(
        _field('What should they know?'),
        '${'y' * 19990}\n\tdone.',
      );
      await tester.pump();
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(fakes.instructions.created, hasLength(1));
    });

    testWidgets('Digital accounts says to say where a password is, never to '
        'paste it', (tester) async {
      await open(tester);
      const guidance =
          "Don't paste passwords. Say where they can be found (for example, your password manager's emergency access).";
      expect(find.text(guidance), findsNothing);
      await _chip(tester, 'Home');
      expect(find.text(guidance), findsNothing);
      expect(find.textContaining("Don't write passwords here"), findsOneWidget);
      await _chip(tester, 'Digital accounts');
      expect(find.text(guidance), findsOneWidget);
      expect(find.textContaining("Don't write passwords here"), findsNothing);
    });

    testWidgets('somebody who has not accepted yet may be chosen, with a '
        'gentle note', (tester) async {
      final fakes = await open(tester);
      expect(find.text("Sam hasn't accepted yet."), findsOneWidget);
      expect(
        find.text("Dad can't be reached right now. See People for what to do."),
        findsOneWidget,
      );
      await _chip(tester, 'Family');
      await _fill(tester, title: 'For Sam');
      await _tick(tester, 'Sam');
      await _stagePick(tester, _afterTwoDays);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(fakes.instructions.created.single['recipients'], [
        {'contact_id': 'c2', 'release_stage_id': _stage(fakes, 3)},
      ]);
      expect(find.text("Sam hasn't accepted yet."), findsWidgets);
    });

    testWidgets('a time is required once somebody is chosen', (tester) async {
      final fakes = await open(tester);
      await _chip(tester, 'Home');
      await _fill(tester);
      await _tick(tester, 'Mom');
      await tapText(tester, 'Save instruction');
      await tester.pump();
      expect(find.text('Choose when this is shared.'), findsOneWidget);
      expect(fakes.instructions.calls, isNot(contains('create')));
      await _stagePick(tester, _afterOneDay);
      expect(find.text('Choose when this is shared.'), findsNothing);
    });

    testWidgets('with only one time to choose from it is the choice', (
      tester,
    ) async {
      final fakes = await open(
        tester,
        fakes: _world(tier: 'free', lateStages: 1),
      );
      await _chip(tester, 'Home');
      await _fill(tester);
      await _tick(tester, 'Mom');
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(fakes.instructions.created.single['recipients'], [
        {'contact_id': 'c1', 'release_stage_id': _stage(fakes, 2)},
      ]);
    });

    testWidgets('different times for different people', (tester) async {
      final fakes = await open(tester);
      await _chip(tester, 'Family');
      await _fill(tester);
      await _tick(tester, 'Mom');
      await _tick(tester, 'Sam');
      await _tap(tester, find.text('Choose a time for each person'));
      expect(find.text('When should Mom receive it?'), findsOneWidget);
      expect(find.text('When should Sam receive it?'), findsOneWidget);
      // Each person has their own choices: the first radio of each group.
      await _tap(
        tester,
        find.widgetWithText(RadioListTile<String>, _afterOneDay).first,
      );
      await _tap(
        tester,
        find.widgetWithText(RadioListTile<String>, _afterTwoDays).last,
      );
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(fakes.instructions.created.single['recipients'], [
        {'contact_id': 'c1', 'release_stage_id': _stage(fakes, 2)},
        {'contact_id': 'c2', 'release_stage_id': _stage(fakes, 3)},
      ]);
    });

    testWidgets('a plan with no stage 1 day out and no room for one says so '
        'plainly and offers the plan; it can still be saved', (tester) async {
      // Free: two stages is all it holds, and both are early.
      final fakes = await open(
        tester,
        fakes: _world(tier: 'free', stageOffsets: [180, 360]),
      );
      expect(
        find.text(
          "Your plan has no stage at least 1 day after a missed check-in, so this can't be shared with anyone yet. You can save it now and choose who receives it once your plan has one.",
        ),
        findsOneWidget,
      );
      expect(find.byType(CheckboxListTile), findsNothing);
      await _chip(tester, 'Pets');
      await _fill(tester, title: 'Goldfish');
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(fakes.instructions.created.single['recipients'], isEmpty);
      expect(fakes.plan.calls, isNot(contains('save')));
      expect(find.text('Goldfish'), findsOneWidget);
      expect(find.text('Not shared with anyone yet'), findsOneWidget);
    });

    testWidgets('Review your plan opens the plan', (tester) async {
      final fakes = _world(tier: 'free', stageOffsets: [180, 360]);
      await open(tester, fakes: fakes);
      await tapText(tester, 'Review your plan');
      await tester.pumpAndSettle();
      expect(find.text('Your plan'), findsOneWidget);
      expect(find.text('Step 6 of 9'), findsOneWidget);
    });

    testWidgets('without a contact it offers to add one', (tester) async {
      await open(tester, fakes: _world(contacts: const []));
      expect(
        find.textContaining('Add a trusted contact first'),
        findsOneWidget,
      );
      await tapText(tester, 'Add a trusted contact');
      await tester.pumpAndSettle();
      expect(find.text('Save and send invitation'), findsOneWidget);
    });

    testWidgets('"Start from an example" lists the examples of the category '
        'and fills the form', (tester) async {
      await open(tester);
      await _chip(tester, 'Home');
      await tapText(tester, 'Start from an example');
      await tester.pumpAndSettle();
      expect(
        find.text(
          'These are only examples to get you started. Change anything you like, and never add passwords.',
        ),
        findsOneWidget,
      );
      for (final title in [
        'House emergency',
        'Home and keys',
        'Bills and household accounts',
        'Utilities and repairs',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('Feeding and daily routine'), findsNothing);
      await tester.tap(find.text('House emergency'));
      await tester.pumpAndSettle();
      expect(_text(tester, 'Title'), 'House emergency');
      expect(
        _text(tester, 'What should they know?'),
        'The spare keys are…\nIn an emergency, call…\nTo turn off the water…\nTo turn off the power…',
      );
      expect(find.text('Start from an example'), findsNothing);
    });

    testWidgets('with no category chosen the examples are grouped by '
        'category', (tester) async {
      await open(tester);
      await tapText(tester, 'Start from an example');
      await tester.pumpAndSettle();
      expect(find.text('Feeding and daily routine'), findsOneWidget);
      await _tap(tester, find.text('Password manager and emergency access'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(
              find.widgetWithText(ChoiceChip, 'Digital accounts'),
            )
            .selected,
        isTrue,
      );
      expect(find.textContaining("Don't paste passwords."), findsOneWidget);
    });

    group('what the server says', () {
      Future<TestFakes> filled(
        WidgetTester tester, {
        AppFailure? failure,
        TestFakes? fakes,
      }) async {
        final f = await open(tester, fakes: fakes);
        if (failure != null) {
          f.instructions.failures['create'] = [failure];
        }
        await _chip(tester, 'Home');
        await _fill(tester);
        await _tick(tester, 'Mom');
        await _stagePick(tester, _afterOneDay);
        await tapText(tester, 'Save instruction');
        await tester.pumpAndSettle();
        return f;
      }

      testWidgets('a field error lands on its field, in the app\'s words', (
        tester,
      ) async {
        await filled(
          tester,
          failure: const ValidationFailure(
            code: 'validation_failed',
            fieldErrors: [
              ApiFieldError(
                field: 'title',
                code: 'invalid_characters',
                message: 'The server wrote this.',
              ),
            ],
          ),
        );
        expect(
          _error(tester, 'Title'),
          "This contains characters that can't be used. Remove them and try again.",
        );
        expect(find.text('The server wrote this.'), findsNothing);
        expect(_text(tester, 'Title'), 'House emergency', reason: 'kept');
      });

      testWidgets('a time that is too early is said under the people', (
        tester,
      ) async {
        await filled(
          tester,
          failure: const ValidationFailure(
            code: 'validation_failed',
            fieldErrors: [
              ApiFieldError(
                field: 'recipients[0].release_stage_id',
                code: 'release_stage_too_early',
                message: 'Choose a stage at least 24 hours after.',
              ),
            ],
          ),
        );
        expect(
          find.text(
            'Choose a time at least 1 day after a missed check-in for sharing instructions.',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Choose a stage at least 24 hours after.'),
          findsNothing,
        );
      });

      testWidgets('an unknown category and a duplicate person are said '
          'plainly', (tester) async {
        await filled(
          tester,
          failure: const ValidationFailure(
            code: 'validation_failed',
            fieldErrors: [
              ApiFieldError(field: 'category', code: 'unknown_category'),
              ApiFieldError(
                field: 'recipients[1].contact_id',
                code: 'duplicate_recipient',
              ),
            ],
          ),
        );
        expect(
          find.text("That category isn't available. Choose another."),
          findsOneWidget,
        );
        expect(find.text('Each person can be chosen once.'), findsOneWidget);
      });

      testWidgets('somebody that is gone (404) reloads and says so; saving '
          'again works', (tester) async {
        final fakes = await filled(tester, failure: const NotFoundFailure());
        expect(
          find.textContaining("Something in this instruction can't be found"),
          findsOneWidget,
        );
        expect(
          fakes.contacts.calls.where((c) => c == 'list').length,
          greaterThan(1),
          reason: 'the contacts were read again',
        );
        await tapText(tester, 'Save instruction');
        await tester.pumpAndSettle();
        expect(fakes.instructions.created, hasLength(1));
        expect(fakes.instructions.liveCount, 1);
        expect(find.byType(InstructionsScreen), findsOneWidget);
      });

      testWidgets('offline is said and nothing is lost', (tester) async {
        final fakes = await filled(tester, failure: const NetworkFailure());
        expect(find.textContaining("You're offline"), findsOneWidget);
        expect(_text(tester, 'Title'), 'House emergency');
        await tapText(tester, 'Save instruction');
        await tester.pumpAndSettle();
        expect(fakes.instructions.liveCount, 1);
      });
    });
  });

  group('what is typed stays in memory only', () {
    Future<void> tab(WidgetTester tester, String label) async {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('leaving and coming back finds the draft, and Start over '
        'clears it', (tester) async {
      final fakes = _world();
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructionNew,
      );
      await _chip(tester, 'Home');
      await _fill(tester, title: 'Draft title', body: 'Draft text.');
      expect(container.read(instructionAutosaveProvider)!.title, 'Draft title');

      // Another tab and back: the tab keeps its page as it was.
      await tab(tester, 'People');
      await tab(tester, 'Instructions');
      expect(_text(tester, 'Title'), 'Draft title');

      // The page was closed: a new one finds what was typed, with a way out.
      container.read(routerProvider).go(AppRoutes.instructions);
      await tester.pumpAndSettle();
      expect(find.byType(AddInstructionScreen), findsNothing);
      container.read(routerProvider).go(AppRoutes.instructionNew);
      await tester.pumpAndSettle();
      expect(_text(tester, 'Title'), 'Draft title');
      expect(_text(tester, 'What should they know?'), 'Draft text.');
      expect(find.text('We kept what you typed.'), findsOneWidget);
      await tapText(tester, 'Start over');
      await tester.pumpAndSettle();
      expect(_text(tester, 'Title'), '');
      expect(container.read(instructionAutosaveProvider), isNull);
      expect(find.text('We kept what you typed.'), findsNothing);
    });

    testWidgets('an edit is kept for that instruction only', (tester) async {
      final fakes = _world();
      fakes.instructions
        ..seed(title: 'First')
        ..seed(title: 'Second');
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructionEdit('instruction-1'),
      );
      await typeInto(tester, 'Title', 'First, changed');
      final router = container.read(routerProvider);
      router.go(AppRoutes.instructionEdit('instruction-2'));
      await tester.pumpAndSettle();
      expect(_text(tester, 'Title'), 'Second');
      expect(find.text('We kept what you typed.'), findsNothing);
      router.go(AppRoutes.instructionEdit('instruction-1'));
      await tester.pumpAndSettle();
      expect(_text(tester, 'Title'), 'First, changed');
      expect(find.text('We kept what you typed.'), findsOneWidget);
      await tapText(tester, 'Start over');
      await tester.pumpAndSettle();
      expect(_text(tester, 'Title'), 'First');
    });

    testWidgets('signing out drops it', (tester) async {
      final fakes = _world();
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructionNew,
      );
      await _chip(tester, 'Home');
      await _fill(tester, title: 'Draft title');
      expect(container.read(instructionAutosaveProvider), isNotNull);
      (container.read(authControllerProvider.notifier) as FixedAuthController)
          .set(AuthStatus.signedOut);
      await tester.pumpAndSettle();
      expect(container.read(instructionAutosaveProvider), isNull);
    });

    testWidgets('it never reaches storage or a log', (tester) async {
      final fakes = _world();
      await openApp(tester, fakes: fakes, route: AppRoutes.instructionNew);
      await _chip(tester, 'Home');
      await _fill(
        tester,
        title: 'A-very-secret-title',
        body: 'A-very-secret-body',
      );
      await tester.pump(const Duration(seconds: 2));
      final prefs = await SharedPreferencesAsync().getAll();
      expect('${prefs.values}', isNot(contains('A-very-secret')));
      expect(
        fakes.secure.values.values.join(' '),
        isNot(contains('A-very-secret')),
      );
    });

    testWidgets('saving clears it', (tester) async {
      final fakes = _world();
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructionNew,
      );
      await _chip(tester, 'Pets');
      await _fill(tester, title: 'Goldfish');
      await _tick(tester, 'Mom');
      await _stagePick(tester, _afterOneDay);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(container.read(instructionAutosaveProvider), isNull);
    });
  });

  group('one instruction', () {
    TestFakes withOne({InstructionStatus status = InstructionStatus.active}) {
      final fakes = _world();
      fakes.instructions.seed(
        title: 'House emergency',
        body: 'The spare key is with a neighbour.\nCall her first.',
        category: InstructionCategory.home,
        status: status,
        recipients: {'c1': _stage(fakes, 2), 'c2': _stage(fakes, 3)},
      );
      return fakes;
    }

    testWidgets('shows the text, who receives it and when, and the status', (
      tester,
    ) async {
      await openApp(
        tester,
        fakes: withOne(),
        route: AppRoutes.instructionDetail('instruction-1'),
      );
      expect(find.text('House emergency'), findsOneWidget);
      expect(find.text('Home'), findsWidgets);
      expect(
        find.text('The spare key is with a neighbour.\nCall her first.'),
        findsOneWidget,
      );
      expect(find.text('Mom'), findsOneWidget);
      expect(find.text('Stage 2: after 1 day'), findsOneWidget);
      expect(find.text('Sam'), findsOneWidget);
      expect(find.text('Stage 3: after 2 days'), findsOneWidget);
      expect(find.text("Sam hasn't accepted yet."), findsOneWidget);
      expect(find.text('Active'), findsWidgets);
      expect(find.textContaining('Last changed'), findsOneWidget);
    });

    testWidgets('can be switched off and on, and says what that means', (
      tester,
    ) async {
      final fakes = withOne();
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructionDetail('instruction-1'),
      );
      expect(
        find.text(
          'It will be shared with the people you chose, at the time you chose.',
        ),
        findsOneWidget,
      );
      await _tap(tester, find.byType(Switch));
      await tester.pumpAndSettle();
      expect(fakes.instructions.updated.single, {'status': 'inactive'});
      expect(
        find.text('It will never be shared while it is inactive.'),
        findsOneWidget,
      );
      expect(find.text('Inactive'), findsWidgets);
      expect(
        snackText(tester),
        "This instruction is inactive and won't be shared.",
      );

      await _tap(tester, find.byType(Switch));
      await tester.pumpAndSettle();
      expect(fakes.instructions.updated.last, {'status': 'active'});
      expect(find.text('Inactive'), findsNothing);
    });

    testWidgets('delete asks first; cancelling changes nothing', (
      tester,
    ) async {
      final fakes = withOne();
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructionDetail('instruction-1'),
      );
      await tapText(tester, 'Delete');
      await tester.pumpAndSettle();
      expect(find.text('Delete this instruction?'), findsOneWidget);
      expect(
        find.text(
          "It will no longer be shared with anyone, and this can't be undone.",
        ),
        findsOneWidget,
      );
      await tapText(tester, 'Cancel');
      await tester.pumpAndSettle();
      expect(fakes.instructions.calls, isNot(contains('delete')));
      expect(find.byType(InstructionDetailScreen), findsOneWidget);
    });

    testWidgets('confirming deletes it and returns to the list', (
      tester,
    ) async {
      final fakes = withOne();
      await openApp(tester, fakes: fakes, route: AppRoutes.instructions);
      await tapText(tester, 'House emergency');
      await tester.pumpAndSettle();
      await tapText(tester, 'Delete');
      await tester.pumpAndSettle();
      await tapText(tester, 'Delete instruction');
      await tester.pumpAndSettle();
      expect(fakes.instructions.liveCount, 0);
      expect(snackText(tester), 'Instruction deleted.');
      expect(find.byType(InstructionsScreen), findsOneWidget);
      expect(find.text('Write down what someone may need'), findsOneWidget);
    });

    testWidgets('a failed delete is said and the instruction stays', (
      tester,
    ) async {
      final fakes = withOne();
      fakes.instructions.failures['delete'] = [const NetworkFailure()];
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructionDetail('instruction-1'),
      );
      await tapText(tester, 'Delete');
      await tester.pumpAndSettle();
      await tapText(tester, 'Delete instruction');
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(fakes.instructions.liveCount, 1);
      expect(find.byType(InstructionDetailScreen), findsOneWidget);
    });

    testWidgets('one that is not there is a calm "not found"', (tester) async {
      await openApp(
        tester,
        fakes: _world(),
        route: AppRoutes.instructionDetail('nope'),
      );
      expect(
        find.text("We couldn't find that. It may have been removed."),
        findsOneWidget,
      );
    });

    testWidgets('cannot be loaded: Try again recovers', (tester) async {
      final fakes = withOne();
      fakes.instructions.failures['get'] = [const NetworkFailure()];
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructionDetail('instruction-1'),
      );
      expect(find.textContaining("You're offline"), findsOneWidget);
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.text('House emergency'), findsOneWidget);
    });

    testWidgets('Edit sends only what changed and the detail shows it', (
      tester,
    ) async {
      final fakes = withOne();
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructionDetail('instruction-1'),
      );
      await tapText(tester, 'Edit');
      await tester.pumpAndSettle();
      expect(find.byType(EditInstructionScreen), findsOneWidget);
      expect(_text(tester, 'Title'), 'House emergency');
      expect(
        _text(tester, 'What should they know?'),
        'The spare key is with a neighbour.\nCall her first.',
      );
      await typeInto(tester, 'Title', 'House emergency (updated)');
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();

      expect(fakes.instructions.updated.single, {
        'title': 'House emergency (updated)',
      });
      expect(find.byType(InstructionDetailScreen), findsOneWidget);
      expect(find.text('House emergency (updated)'), findsOneWidget);
    });

    testWidgets('Edit with nothing changed sends nothing', (tester) async {
      final fakes = withOne();
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructionEdit('instruction-1'),
      );
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(fakes.instructions.updated, isEmpty);
    });

    testWidgets('Edit keeps each person\'s own time unless it is changed', (
      tester,
    ) async {
      final fakes = withOne();
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructionEdit('instruction-1'),
      );
      // Two different times: shown per person, none flattened.
      expect(find.text('When should Mom receive it?'), findsOneWidget);
      expect(find.text('When should Sam receive it?'), findsOneWidget);
      await _tick(tester, 'Sam');
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(fakes.instructions.updated.single, {
        'recipients': [
          {'contact_id': 'c1', 'release_stage_id': _stage(fakes, 2)},
        ],
      });
    });

    testWidgets('an edit that the server refuses is said, and kept', (
      tester,
    ) async {
      final fakes = withOne();
      fakes.instructions.failures['update'] = [
        const ValidationFailure(
          code: 'validation_failed',
          fieldErrors: [ApiFieldError(field: 'body', code: 'too_long')],
        ),
      ];
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructionEdit('instruction-1'),
      );
      await typeInto(tester, 'Title', 'Changed');
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(
        _error(tester, 'What should they know?'),
        "That's too long. Use 20,000 characters or fewer.",
      );
      expect(_text(tester, 'Title'), 'Changed');
    });
  });

  group('the plan and Home follow', () {
    testWidgets('a stage says how many instructions it shares', (tester) async {
      final fakes = _world();
      fakes.instructions
        ..seed(title: 'A', recipients: {'c1': _stage(fakes, 2)})
        ..seed(title: 'B', recipients: {'c1': _stage(fakes, 2)});
      await openApp(tester, fakes: fakes, route: AppRoutes.plan);
      expect(find.text('Shares 2 instructions'), findsOneWidget);
    });

    testWidgets('a new instruction is counted by the plan and by Home', (
      tester,
    ) async {
      final fakes = _world();
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructionNew,
      );
      await _chip(tester, 'Pets');
      await _fill(tester, title: 'Goldfish');
      await _tick(tester, 'Mom');
      await _stagePick(tester, _afterOneDay);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();

      final plan = fakes.plan.stages.firstWhere((s) => s.position == 2);
      expect(fakes.instructions.releaseCount(plan.id), 1);
      container.read(routerProvider).go(AppRoutes.plan);
      await tester.pumpAndSettle();
      expect(find.text('Shares 1 instruction'), findsOneWidget);
      expect((await fakes.contacts.entitlements()).usage.instructions, 1);
    });
  });
}
