import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/design_system/design_system.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/instructions/application/instruction_autosave.dart';
import 'package:afterme/features/instructions/data/instructions_repository.dart';
import 'package:afterme/features/instructions/presentation/instruction_detail_screen.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

/// Changing who receives something, or switching it off or deleting it, takes the
/// protection of a safety net that is on out of the person's hands, so the server asks
/// for the password (403 `reauth_required`, SECURITY.md §7): while check-ins are on, when
/// an instruction is created with recipients, when its recipients change, when one that
/// has recipients is switched off, and when one that has recipients is deleted. The sheet
/// says why and the very same request is sent again once. Editing the text or the
/// category, switching on, an instruction nobody receives, and everything while check-ins
/// are off (onboarding) never ask.

const _recipientsReason =
    'Changing who receives this needs your password because it decides who sees it.';
const _offReason =
    'Switching this off or deleting it needs your password because it changes what is shared.';

/// Check-ins are on (or, with [on] false, off as during onboarding). Mom (c1) is told at
/// stage 1 and can receive instructions at stage 2 (1 day out); Bro (c2) is in no stage.
TestFakes _active({bool on = true, int receivesInstructions = 0}) {
  final fakes = TestFakes();
  fakes.contacts = InMemoryContactsRepository(
    tier: 'premium',
    initial: [
      testContact(),
      testContact(
        id: 'c2',
        name: 'Bro',
        relationship: ContactRelationship.sibling,
        email: 'bro@example.com',
        priority: 2,
        receivesInstructions: receivesInstructions,
      ),
    ],
  );
  fakes.plan.seed(
    const PlanDraft(
      graceMinutes: 180,
      stages: [
        PlanStageDraft(offsetMinutes: 180, contactIds: ['c1']),
        PlanStageDraft(offsetMinutes: 1440, contactIds: ['c1']),
      ],
    ),
  );
  if (on) {
    fakes.server.activateNow();
  }
  return fakes;
}

String _lateStage(TestFakes fakes) => fakes.plan.stages.last.id;

/// A few frames. `pumpAndSettle` cannot be used while a button shows its busy spinner
/// behind the password sheet: an indeterminate indicator never settles.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

int _calls(TestFakes fakes, String method) =>
    fakes.instructions.calls.where((c) => c == method).length;

int _reauths(TestFakes fakes) =>
    fakes.auth.calls.where((c) => c == 'reauth').length;

Future<void> _confirmPassword(WidgetTester tester, String password) async {
  await typeInto(tester, 'Password', password);
  await tapText(tester, 'Confirm');
  await _frames(tester);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder.first);
  await tester.pump();
  await tester.tap(finder.first);
  await tester.pump();
}

/// The create form, filled in with Mom as the recipient, and Save pressed.
Future<void> _writeAndSave(
  WidgetTester tester,
  TestFakes fakes, {
  bool withRecipient = true,
}) async {
  await openApp(tester, fakes: fakes, route: AppRoutes.instructionNew);
  await _tap(tester, find.widgetWithText(ChoiceChip, 'Home'));
  await typeInto(tester, 'Title', 'House emergency');
  await tester.enterText(
    find.widgetWithText(TextField, 'What should they know?'),
    'The spare key is with a neighbour.',
  );
  await tester.pumpAndSettle();
  if (withRecipient) {
    await _tap(tester, find.widgetWithText(CheckboxListTile, 'Mom'));
    await tester.pumpAndSettle();
    // The plan's own stage a day out: no stage has to be added.
    await _tap(
      tester,
      find.widgetWithText(
        RadioListTile<String>,
        "If you haven't checked in for 1 day",
      ),
    );
    await tester.pumpAndSettle();
  }
  await tapText(tester, 'Save instruction');
  await _frames(tester);
}

void main() {
  group('Creating one with recipients', () {
    testWidgets('asks for the password, says why, then saves it once', (
      tester,
    ) async {
      final fakes = _active();
      await _writeAndSave(tester, fakes);

      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(find.text(_recipientsReason), findsOneWidget);
      expect(fakes.instructions.liveCount, 0, reason: 'not saved yet');
      expect(_calls(fakes, 'create'), 1);

      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();

      expect(find.text("Confirm it's you"), findsNothing);
      expect(_calls(fakes, 'create'), 2, reason: 'the same save, once more');
      expect(fakes.instructions.created.first, fakes.instructions.created.last);
      expect(_reauths(fakes), 1);
      expect(fakes.instructions.liveCount, 1);
      expect(snackText(tester), 'Instruction saved.');
      expect(find.text('House emergency'), findsOneWidget);
    });

    testWidgets('closing the sheet saves nothing, says nothing and keeps what '
        'was typed', (tester) async {
      final fakes = _active();
      await _writeAndSave(tester, fakes);
      expect(find.text("Confirm it's you"), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await _frames(tester);

      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.instructions.liveCount, 0);
      expect(_calls(fakes, 'create'), 1, reason: 'not sent again');
      expect(_reauths(fakes), 0);
      expect(snackText(tester), isNull);
      expect(find.byType(FailureNotice), findsNothing);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Title'))
            .controller!
            .text,
        'House emergency',
      );
      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save instruction'),
      );
      expect(save.onPressed, isNotNull, reason: 'not stuck busy');
    });

    testWidgets('the draft survives a closed sheet and is dropped by the save '
        'that follows', (tester) async {
      final fakes = _active();
      await _writeAndSave(tester, fakes);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(Scaffold).first),
      );
      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      expect(container.read(instructionAutosaveProvider), isNotNull);

      await tapText(tester, 'Save instruction');
      await _frames(tester);
      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();
      expect(container.read(instructionAutosaveProvider), isNull);
      expect(fakes.instructions.liveCount, 1);
    });

    testWidgets('a wrong password stays in the sheet and saves nothing', (
      tester,
    ) async {
      final fakes = _active();
      await _writeAndSave(tester, fakes);

      await _confirmPassword(tester, 'not the password');
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(
        find.text("That password didn't match. Try again."),
        findsOneWidget,
      );
      expect(fakes.instructions.liveCount, 0);
      expect(_calls(fakes, 'create'), 1);
      expect(find.byType(FailureNotice), findsNothing);

      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();
      expect(fakes.instructions.liveCount, 1);
      expect(_calls(fakes, 'create'), 2);
    });

    testWidgets('another failure after the password is shown calmly', (
      tester,
    ) async {
      final fakes = _active();
      fakes.instructions.failures['create'] = [
        const ForbiddenFailure(code: 'reauth_required'),
        const NetworkFailure(),
      ];
      await _writeAndSave(tester, fakes);
      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(
        find.textContaining("We couldn't confirm that this was saved"),
        findsOneWidget,
      );
      expect(fakes.instructions.liveCount, 0);
    });

    testWidgets('with a recent password no sheet is needed', (tester) async {
      final fakes = _active();
      fakes.auth.reauthenticated = true;
      await _writeAndSave(tester, fakes);
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.instructions.liveCount, 1);
      expect(_calls(fakes, 'create'), 1);
    });

    testWidgets('one nobody receives never asks', (tester) async {
      final fakes = _active();
      await _writeAndSave(tester, fakes, withRecipient: false);
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.instructions.liveCount, 1);
      expect(_reauths(fakes), 0);
    });

    testWidgets('while check-ins are off (onboarding) it never asks, even '
        'with recipients', (tester) async {
      final fakes = _active(on: false);
      await _writeAndSave(tester, fakes);
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.instructions.liveCount, 1);
      expect(fakes.instructions.reauthAsked, 0);
    });

    testWidgets('onboarding step 7 saves with recipients without asking', (
      tester,
    ) async {
      final fakes = _active(on: false);
      fakes.prefs = freshPreferences({
        'afterme.onboardingUserId': 'user-1',
        'afterme.onboardingCompleted': false,
        'afterme.onboardingStep': OnboardingStep.instruction.name,
      });
      await pumpAfterMe(tester, fakes: fakes, status: AuthStatus.signedIn);
      await tapText(tester, 'Pets');
      await tester.pumpAndSettle();
      await _tap(
        tester,
        find.widgetWithText(
          RadioListTile<String>,
          "If you haven't checked in for 1 day",
        ),
      );
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.instructions.liveCount, 1);
      expect(
        fakes.instructions.created.single['recipients'],
        isNotEmpty,
        reason: 'the contact just added is ticked',
      );
      expect(find.text('Stay protected'), findsOneWidget);
    });
  });

  group('Editing one', () {
    TestFakes withOne({bool on = true}) {
      final fakes = _active(on: on);
      fakes.instructions.seed(
        title: 'House emergency',
        body: 'The spare key is with a neighbour.',
        recipients: {'c1': _lateStage(fakes)},
      );
      return fakes;
    }

    Future<void> openEdit(WidgetTester tester, TestFakes fakes) => openApp(
      tester,
      fakes: fakes,
      route: AppRoutes.instructionEdit('instruction-1'),
    );

    testWidgets('changing who receives it asks, says why and saves once', (
      tester,
    ) async {
      final fakes = withOne();
      await openEdit(tester, fakes);
      await _tap(tester, find.widgetWithText(CheckboxListTile, 'Bro'));
      await tester.pumpAndSettle();
      await tapText(tester, 'Save changes');
      await _frames(tester);

      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(find.text(_recipientsReason), findsOneWidget);
      expect(_calls(fakes, 'update'), 1);

      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();

      expect(_calls(fakes, 'update'), 2);
      expect(fakes.instructions.updated.first, fakes.instructions.updated.last);
      expect(_reauths(fakes), 1);
      expect(find.text('Save changes'), findsNothing, reason: 'left the form');
      final item = await fakes.instructions.get('instruction-1');
      expect(item.recipients.map((r) => r.contactId).toSet(), {'c1', 'c2'});
    });

    testWidgets('closing the sheet changes nothing and the edits stay', (
      tester,
    ) async {
      final fakes = withOne();
      await openEdit(tester, fakes);
      await _tap(tester, find.widgetWithText(CheckboxListTile, 'Mom'));
      await tester.pumpAndSettle();
      await tapText(tester, 'Save changes');
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await _frames(tester);

      expect(find.text("Confirm it's you"), findsNothing);
      expect(_calls(fakes, 'update'), 1);
      expect(snackText(tester), isNull);
      expect(find.byType(FailureNotice), findsNothing);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Mom'),
            )
            .value,
        isFalse,
        reason: 'the edit is still on the form',
      );
      expect(
        (await fakes.instructions.get('instruction-1')).recipients,
        hasLength(1),
      );
    });

    testWidgets('a wrong password stays in the sheet and changes nothing', (
      tester,
    ) async {
      final fakes = withOne();
      await openEdit(tester, fakes);
      await _tap(tester, find.widgetWithText(CheckboxListTile, 'Mom'));
      await tester.pumpAndSettle();
      await tapText(tester, 'Save changes');
      await _frames(tester);
      await _confirmPassword(tester, 'not the password');
      expect(
        find.text("That password didn't match. Try again."),
        findsOneWidget,
      );
      expect(_calls(fakes, 'update'), 1);
    });

    testWidgets('editing the title and the text never asks', (tester) async {
      final fakes = withOne();
      await openEdit(tester, fakes);
      await typeInto(tester, 'Title', 'House emergency (updated)');
      await tester.enterText(
        find.widgetWithText(TextField, 'What should they know?'),
        'The spare key is with a neighbour.\nCall her first.',
      );
      await tester.pumpAndSettle();
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();

      expect(find.text("Confirm it's you"), findsNothing);
      expect(_calls(fakes, 'update'), 1);
      expect(fakes.instructions.updated.single.keys, {'title', 'body'});
      expect(_reauths(fakes), 0);
    });

    testWidgets('the same people at the same times (ticked again) never ask', (
      tester,
    ) async {
      final fakes = withOne();
      await openEdit(tester, fakes);
      await _tap(tester, find.widgetWithText(CheckboxListTile, 'Mom'));
      await _tap(tester, find.widgetWithText(CheckboxListTile, 'Mom'));
      await tester.pumpAndSettle();
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.instructions.updated, isEmpty, reason: 'nothing changed');
    });

    testWidgets('while check-ins are off (onboarding) changing who receives it '
        'never asks', (tester) async {
      final fakes = withOne(on: false);
      await openEdit(tester, fakes);
      await _tap(tester, find.widgetWithText(CheckboxListTile, 'Bro'));
      await tester.pumpAndSettle();
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(_calls(fakes, 'update'), 1);
      expect(fakes.instructions.reauthAsked, 0);
    });
  });

  group('Switching off', () {
    TestFakes withOne({
      bool recipients = true,
      InstructionStatus status = InstructionStatus.active,
    }) {
      final fakes = _active();
      fakes.instructions.seed(
        title: 'House emergency',
        status: status,
        recipients: recipients ? {'c1': _lateStage(fakes)} : const {},
      );
      return fakes;
    }

    Future<void> openDetail(WidgetTester tester, TestFakes fakes) => openApp(
      tester,
      fakes: fakes,
      route: AppRoutes.instructionDetail('instruction-1'),
    );

    testWidgets('one that has recipients asks, says why and switches off '
        'once', (tester) async {
      final fakes = withOne();
      await openDetail(tester, fakes);
      await _tap(tester, find.byType(Switch));
      await _frames(tester);

      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(find.text(_offReason), findsOneWidget);
      expect(_calls(fakes, 'update'), 1);

      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();

      expect(_calls(fakes, 'update'), 2);
      expect(_reauths(fakes), 1);
      expect(find.text('Inactive'), findsWidgets);
      expect(
        snackText(tester),
        "This instruction is inactive and won't be shared.",
      );
    });

    testWidgets('closing the sheet leaves it on and says nothing', (
      tester,
    ) async {
      final fakes = withOne();
      await openDetail(tester, fakes);
      await _tap(tester, find.byType(Switch));
      await _frames(tester);
      await tester.tap(find.text('Cancel'));
      await _frames(tester);

      expect(find.text("Confirm it's you"), findsNothing);
      expect(snackText(tester), isNull);
      expect(find.byType(FailureNotice), findsNothing);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect((await fakes.instructions.get('instruction-1')).isActive, isTrue);
      expect(
        tester.widget<Switch>(find.byType(Switch)).onChanged,
        isNotNull,
        reason: 'not stuck busy',
      );
    });

    testWidgets('a wrong password stays in the sheet', (tester) async {
      final fakes = withOne();
      await openDetail(tester, fakes);
      await _tap(tester, find.byType(Switch));
      await _frames(tester);
      await _confirmPassword(tester, 'not the password');
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(_calls(fakes, 'update'), 1);
      expect((await fakes.instructions.get('instruction-1')).isActive, isTrue);
    });

    testWidgets('one nobody receives switches off without a password', (
      tester,
    ) async {
      final fakes = withOne(recipients: false);
      await openDetail(tester, fakes);
      await _tap(tester, find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(_calls(fakes, 'update'), 1);
      expect(fakes.instructions.reauthAsked, 0);
    });

    testWidgets('switching on never asks', (tester) async {
      final fakes = withOne(status: InstructionStatus.inactive);
      await openDetail(tester, fakes);
      await _tap(tester, find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(_calls(fakes, 'update'), 1);
      expect(fakes.instructions.updated.single, {'status': 'active'});
      expect(fakes.instructions.reauthAsked, 0);
    });
  });

  group('Deleting', () {
    TestFakes withOne({bool recipients = true}) {
      final fakes = _active();
      fakes.instructions.seed(
        title: 'House emergency',
        recipients: recipients ? {'c1': _lateStage(fakes)} : const {},
      );
      return fakes;
    }

    Future<void> deleteIt(WidgetTester tester, TestFakes fakes) async {
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.instructionDetail('instruction-1'),
      );
      await tapText(tester, 'Delete');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete instruction'));
      await _frames(tester);
    }

    testWidgets('one that has recipients asks, says why and deletes once', (
      tester,
    ) async {
      final fakes = withOne();
      await deleteIt(tester, fakes);

      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(find.text(_offReason), findsOneWidget);
      expect(fakes.instructions.liveCount, 1);
      expect(_calls(fakes, 'delete'), 1);

      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();

      expect(_calls(fakes, 'delete'), 2);
      expect(_reauths(fakes), 1);
      expect(fakes.instructions.liveCount, 0);
      expect(snackText(tester), 'Instruction deleted.');
      expect(find.byType(InstructionDetailScreen), findsNothing);
    });

    testWidgets('closing the sheet keeps it, says nothing and is not stuck', (
      tester,
    ) async {
      final fakes = withOne();
      await deleteIt(tester, fakes);
      await tester.tap(find.text('Cancel'));
      await _frames(tester);

      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.instructions.liveCount, 1);
      expect(_calls(fakes, 'delete'), 1);
      expect(snackText(tester), isNull);
      expect(find.byType(FailureNotice), findsNothing);
      expect(find.byType(InstructionDetailScreen), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Delete'))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('a wrong password stays in the sheet and deletes nothing', (
      tester,
    ) async {
      final fakes = withOne();
      await deleteIt(tester, fakes);
      await _confirmPassword(tester, 'not the password');
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(fakes.instructions.liveCount, 1);
      expect(_calls(fakes, 'delete'), 1);

      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();
      expect(fakes.instructions.liveCount, 0);
    });

    testWidgets('one nobody receives is deleted without a password', (
      tester,
    ) async {
      final fakes = withOne(recipients: false);
      await deleteIt(tester, fakes);
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.instructions.liveCount, 0);
      expect(fakes.instructions.reauthAsked, 0);
    });
  });

  group('A contact who only receives an instruction', () {
    TestFakes withRecipientOnly({
      InstructionStatus status = InstructionStatus.active,
      bool on = true,
    }) {
      final fakes = _active(on: on, receivesInstructions: 1);
      fakes.instructions.seed(
        title: 'House emergency',
        status: status,
        recipients: {'c2': _lateStage(fakes)},
      );
      return fakes;
    }

    Future<void> remove(WidgetTester tester, TestFakes fakes) async {
      await openApp(tester, fakes: fakes, route: AppRoutes.contactDetail('c2'));
      await tapText(tester, 'Remove');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await _frames(tester);
    }

    testWidgets('removing them asks for the password in its own words, then '
        'removes them once', (tester) async {
      final fakes = withRecipientOnly();
      await remove(tester, fakes);

      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(
        find.text(
          'Removing someone who receives your instructions needs your password because it changes who sees them.',
        ),
        findsOneWidget,
      );
      expect(fakes.contacts.contacts, hasLength(2));

      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();
      expect(fakes.contacts.contacts.map((c) => c.id), ['c1']);
      expect(_reauths(fakes), 1);
    });

    testWidgets('closing the sheet keeps them and says nothing', (
      tester,
    ) async {
      final fakes = withRecipientOnly();
      await remove(tester, fakes);
      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      expect(fakes.contacts.contacts, hasLength(2));
      expect(snackText(tester), isNull);
      expect(find.byType(FailureNotice), findsNothing);
    });

    testWidgets('changing their email asks, in its own words', (tester) async {
      final fakes = withRecipientOnly();
      await openApp(tester, fakes: fakes, route: AppRoutes.contactEdit('c2'));
      await typeInto(tester, 'Their email', 'brother@example.com');
      await tapText(tester, 'Save changes');
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(
        find.text(
          'Changing the email address of someone who receives your instructions needs your password because it changes who sees them.',
        ),
        findsOneWidget,
      );
      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();
      expect(
        fakes.contacts.contacts.firstWhere((c) => c.id == 'c2').email,
        'brother@example.com',
      );
    });

    testWidgets('an inactive instruction does not hold them: no password', (
      tester,
    ) async {
      final fakes = withRecipientOnly(status: InstructionStatus.inactive);
      await remove(tester, fakes);
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.contacts.contacts.map((c) => c.id), ['c1']);
    });

    testWidgets('while check-ins are off (onboarding) nobody asks', (
      tester,
    ) async {
      final fakes = withRecipientOnly(on: false);
      await remove(tester, fakes);
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.contacts.contacts.map((c) => c.id), ['c1']);
    });

    testWidgets('someone in a stage keeps the wording about the plan', (
      tester,
    ) async {
      final fakes = _active(receivesInstructions: 1);
      fakes.instructions.seed(
        title: 'House emergency',
        recipients: {'c1': _lateStage(fakes)},
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.contactDetail('c1'));
      await tapText(tester, 'Remove');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await _frames(tester);
      expect(
        find.text(
          'Removing a trusted contact from your plan needs your password because it changes who is told.',
        ),
        findsOneWidget,
      );
    });
  });
}
