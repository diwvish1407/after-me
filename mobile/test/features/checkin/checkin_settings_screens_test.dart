import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/features/checkin/application/schedule_controller.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

TestFakes _fakes({bool active = false, bool contact = true}) {
  final fakes = TestFakes();
  if (contact) {
    fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
  }
  if (active) {
    fakes.server.activateNow();
  }
  return fakes;
}

Finder _filled(String label) => find.widgetWithText(FilledButton, label);

bool _enabled(WidgetTester tester, Finder button) =>
    tester.widget<ButtonStyleButton>(button).onPressed != null;

/// A few frames. `pumpAndSettle` cannot be used while the form shows its busy spinner
/// behind the password sheet: an indeterminate indicator never settles.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<ProviderContainer> _open(WidgetTester tester, TestFakes fakes) =>
    openApp(tester, fakes: fakes, route: AppRoutes.settingsSchedule);

void main() {
  group('Settings > Check-in schedule', () {
    testWidgets('is reached from Settings, with the history next to it', (
      tester,
    ) async {
      await openApp(tester, fakes: _fakes(), route: AppRoutes.settings);
      expect(find.text('Check-in schedule'), findsOneWidget);
      expect(find.text('Check-in history'), findsOneWidget);
      await tapText(tester, 'Check-in schedule');
      await tester.pumpAndSettle();
      expect(find.text('Check-ins are off'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapText(tester, 'Check-in history');
      await tester.pumpAndSettle();
      expect(find.text('No check-ins yet'), findsOneWidget);
    });

    testWidgets('shows the schedule as the server has it, switched off', (
      tester,
    ) async {
      await _open(tester, _fakes());
      expect(find.text('Check-ins are off'), findsOneWidget);
      expect(find.text('Check in every day by 8:00 PM.'), findsOneWidget);
      expect(find.text('8:00 PM'), findsWidgets);
      expect(find.text('Times are in Asia/Kolkata.'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(
              find.widgetWithText(ChoiceChip, '1 hour before'),
            )
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Every day'))
            .selected,
        isTrue,
      );
      expect(_enabled(tester, _filled('Save changes')), isFalse);
      expect(find.text('Turn on check-ins'), findsOneWidget);
      expect(find.text('Turn off check-ins'), findsNothing);
    });

    testWidgets('a change is saved with the ETag it was loaded with', (
      tester,
    ) async {
      final fakes = _fakes();
      await _open(tester, fakes);

      await tapText(tester, 'Every week');
      await tapText(tester, '30 minutes before');
      expect(_enabled(tester, _filled('Save changes')), isTrue);
      expect(find.text('Check in every week by 8:00 PM.'), findsOneWidget);

      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(fakes.server.ifMatches, ['"sched-1"']);
      expect(fakes.server.intervalDays, 7);
      expect(fakes.server.reminderLead, 30);
      expect(fakes.server.dueMinutes, 20 * 60);
      expect(find.text('Schedule saved.'), findsOneWidget);
      expect(_enabled(tester, _filled('Save changes')), isFalse);
      // Saving again uses the new ETag.
      await tapText(tester, 'Every 2 days');
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(fakes.server.ifMatches, ['"sched-1"', '"sched-2"']);
    });

    testWidgets('the time is chosen with the time picker', (tester) async {
      final fakes = _fakes();
      await _open(tester, fakes);
      await tapText(tester, '8:00 PM');
      await tester.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(_enabled(tester, _filled('Save changes')), isFalse);

      await tapText(tester, '8:00 PM');
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      // Accepting the dialog without a change leaves the schedule as it was.
      expect(_enabled(tester, _filled('Save changes')), isFalse);
    });

    testWidgets('while on it shows the next check-in and warns that saving '
        'restarts the clock', (tester) async {
      await _open(tester, _fakes(active: true));
      expect(find.text('Check-ins are on'), findsOneWidget);
      expect(find.text('Next check-in: Tomorrow · 8:00 PM'), findsOneWidget);
      expect(
        find.text(
          'Saving starts your clock again: your next check-in is worked out from now.',
        ),
        findsOneWidget,
      );
      expect(find.text('Turn off check-ins'), findsOneWidget);
      expect(find.text('Turn on check-ins'), findsNothing);
    });

    testWidgets('turning on: the server decides and says what is missing', (
      tester,
    ) async {
      final fakes = _fakes(contact: false);
      await _open(tester, fakes);
      await tapText(tester, 'Turn on check-ins');
      await tester.pumpAndSettle();
      expect(
        find.text(
          "Check-ins aren't on yet. Still needed: a trusted contact, a plan stage.",
        ),
        findsOneWidget,
      );
      expect(fakes.server.status, CheckInStatus.inactive);

      // A contact alone is not enough: the plan needs a stage that tells them.
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      await tapText(tester, 'Turn on check-ins');
      await tester.pumpAndSettle();
      expect(
        find.text("Check-ins aren't on yet. Still needed: a plan stage."),
        findsOneWidget,
      );
      expect(fakes.server.status, CheckInStatus.inactive);

      fakes.plan.seedStandard(['c1']);
      await tapText(tester, 'Turn on check-ins');
      await tester.pumpAndSettle();
      expect(fakes.server.status, CheckInStatus.active);
      expect(find.text('Check-ins are on.'), findsOneWidget);
      expect(find.text('Turn off check-ins'), findsOneWidget);
    });

    testWidgets('turning off asks first, then for the password, and only '
        'then turns it off', (tester) async {
      final fakes = _fakes(active: true);
      await _open(tester, fakes);

      await tapText(tester, 'Turn off check-ins');
      await tester.pumpAndSettle();
      expect(find.text('Turn off check-ins?'), findsOneWidget);
      await tapText(tester, 'Cancel');
      await tester.pumpAndSettle();
      expect(fakes.server.calls.where((c) => c == 'deactivate'), isEmpty);

      await tapText(tester, 'Turn off check-ins');
      await tester.pumpAndSettle();
      await tapText(tester, 'Turn off');
      await _frames(tester);
      // The server wants the password again: the sheet opens.
      expect(fakes.server.status, CheckInStatus.active);
      expect(find.text("Confirm it's you"), findsOneWidget);
      await typeInto(tester, 'Password', fakes.auth.password);
      await tapText(tester, 'Confirm');
      await _frames(tester);

      expect(fakes.server.status, CheckInStatus.inactive);
      expect(find.text('Check-ins are off.'), findsOneWidget);
      expect(find.text('Turn on check-ins'), findsOneWidget);
      expect(fakes.server.calls.where((c) => c == 'deactivate'), hasLength(2));
    });

    testWidgets('with a recent password no sheet is needed', (tester) async {
      final fakes = _fakes(active: true);
      fakes.auth.reauthenticated = true;
      await _open(tester, fakes);
      await tapText(tester, 'Turn off check-ins');
      await tester.pumpAndSettle();
      await tapText(tester, 'Turn off');
      await tester.pumpAndSettle();
      expect(fakes.server.status, CheckInStatus.inactive);
      expect(find.text("Confirm it's you"), findsNothing);
    });

    testWidgets('closing the password sheet changes nothing and says nothing', (
      tester,
    ) async {
      final fakes = _fakes(active: true);
      await _open(tester, fakes);
      await tapText(tester, 'Turn off check-ins');
      await tester.pumpAndSettle();
      await tapText(tester, 'Turn off');
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      expect(fakes.server.status, CheckInStatus.active);
      expect(find.text('Check-ins are off.'), findsNothing);
      expect(find.text('Check-ins are on'), findsOneWidget);
    });

    group('making the interval longer while check-ins are on', () {
      const note =
          'Making the interval longer asks for your password when you save.';

      Future<void> editAndSave(WidgetTester tester, String interval) async {
        await tapText(tester, interval);
        await tapText(tester, 'Save changes');
        await _frames(tester);
      }

      testWidgets('says so in a calm line, only while it applies', (
        tester,
      ) async {
        await _open(tester, _fakes(active: true));
        expect(find.text(note), findsOneWidget);

        await _open(tester, _fakes());
        expect(find.text(note), findsNothing, reason: 'off: nothing to ask');

        final locked = _fakes(active: true);
        locked.server.openIncident();
        await _open(tester, locked);
        expect(find.text(note), findsNothing, reason: 'locked: no saving');
      });

      testWidgets('asks for the password, then saves the same change once', (
        tester,
      ) async {
        final fakes = _fakes(active: true);
        await _open(tester, fakes);

        await editAndSave(tester, 'Every week');
        expect(find.text("Confirm it's you"), findsOneWidget);
        expect(fakes.server.intervalDays, 1, reason: 'nothing saved yet');
        expect(fakes.server.calls.where((c) => c == 'save'), hasLength(1));

        await typeInto(tester, 'Password', fakes.auth.password);
        await tapText(tester, 'Confirm');
        await _frames(tester);

        expect(find.text("Confirm it's you"), findsNothing);
        expect(fakes.server.intervalDays, 7);
        expect(fakes.server.calls.where((c) => c == 'save'), hasLength(2));
        expect(fakes.server.ifMatches, [
          '"sched-2"',
          '"sched-2"',
        ], reason: 'the same save, with the same If-Match');
        expect(fakes.auth.calls.where((c) => c == 'reauth'), hasLength(1));
        expect(find.text('Schedule saved.'), findsOneWidget);
        expect(_enabled(tester, _filled('Save changes')), isFalse);
        expect(find.text('Check-ins are on'), findsOneWidget);
      });

      testWidgets('closing the sheet saves nothing and keeps the edits', (
        tester,
      ) async {
        final fakes = _fakes(active: true);
        await _open(tester, fakes);
        await editAndSave(tester, 'Every week');
        expect(find.text("Confirm it's you"), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await _frames(tester);
        expect(find.text("Confirm it's you"), findsNothing);
        expect(fakes.server.intervalDays, 1);
        expect(fakes.server.version, 2);
        expect(fakes.server.calls.where((c) => c == 'save'), hasLength(1));
        expect(fakes.auth.calls.where((c) => c == 'reauth'), isEmpty);
        expect(find.text('Schedule saved.'), findsNothing);
        expect(find.textContaining('something went wrong'), findsNothing);
        expect(
          tester
              .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Every week'))
              .selected,
          isTrue,
          reason: 'the edit is still there',
        );
        expect(_enabled(tester, _filled('Save changes')), isTrue);

        // Saving again asks again, and this time it goes through.
        await tapText(tester, 'Save changes');
        await _frames(tester);
        await typeInto(tester, 'Password', fakes.auth.password);
        await tapText(tester, 'Confirm');
        await _frames(tester);
        expect(fakes.server.intervalDays, 7);
      });

      testWidgets('a wrong password stays in the sheet with its error', (
        tester,
      ) async {
        final fakes = _fakes(active: true);
        await _open(tester, fakes);
        await editAndSave(tester, 'Every week');

        await typeInto(tester, 'Password', 'not the password');
        await tapText(tester, 'Confirm');
        await _frames(tester);
        expect(find.text("Confirm it's you"), findsOneWidget);
        expect(
          find.text("That password didn't match. Try again."),
          findsOneWidget,
        );
        expect(fakes.server.intervalDays, 1);
        expect(fakes.server.calls.where((c) => c == 'save'), hasLength(1));

        await typeInto(tester, 'Password', fakes.auth.password);
        await tapText(tester, 'Confirm');
        await _frames(tester);
        expect(find.text("Confirm it's you"), findsNothing);
        expect(fakes.server.intervalDays, 7);
      });

      testWidgets('with a recent password no sheet is needed', (tester) async {
        final fakes = _fakes(active: true);
        fakes.auth.reauthenticated = true;
        await _open(tester, fakes);
        await editAndSave(tester, 'Every week');
        expect(find.text("Confirm it's you"), findsNothing);
        expect(fakes.server.intervalDays, 7);
        expect(fakes.server.calls.where((c) => c == 'save'), hasLength(1));
      });

      testWidgets('a shorter interval, or only the reminder, needs no '
          'password', (tester) async {
        final fakes = _fakes();
        fakes.server.intervalDays = 7;
        fakes.server.activateNow();
        await _open(tester, fakes);

        await editAndSave(tester, 'Every 2 days');
        expect(find.text("Confirm it's you"), findsNothing);
        expect(fakes.server.intervalDays, 2);

        await editAndSave(tester, '30 minutes before');
        expect(find.text("Confirm it's you"), findsNothing);
        expect(fakes.server.reminderLead, 30);
        expect(fakes.auth.calls.where((c) => c == 'reauth'), isEmpty);
        expect(fakes.server.calls.where((c) => c == 'save'), hasLength(2));
      });

      testWidgets('while check-ins are off no password is asked for', (
        tester,
      ) async {
        final fakes = _fakes();
        await _open(tester, fakes);
        await editAndSave(tester, 'Every week');
        expect(find.text("Confirm it's you"), findsNothing);
        expect(fakes.server.intervalDays, 7);
        expect(fakes.server.calls.where((c) => c == 'save'), hasLength(1));
      });

      testWidgets('changed elsewhere meanwhile (412) is said as before, not '
          'as a password problem', (tester) async {
        final fakes = _fakes(active: true);
        await _open(tester, fakes);
        await tapText(tester, 'Every week');
        fakes.server
          ..intervalDays = 3
          ..version = 3;
        await tapText(tester, 'Save changes');
        await _frames(tester);
        expect(find.text("Confirm it's you"), findsNothing);
        expect(
          find.textContaining('This was changed somewhere else'),
          findsOneWidget,
        );
      });
    });

    testWidgets('changed on another device (412): the latest is loaded and '
        'the person is told', (tester) async {
      final fakes = _fakes();
      await _open(tester, fakes);
      await tapText(tester, 'Every week');
      // Somebody else changes the schedule before this save.
      fakes.server
        ..intervalDays = 3
        ..version = 2;
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('This was changed somewhere else'),
        findsOneWidget,
      );
      expect(find.text('Check in every 3 days by 8:00 PM.'), findsOneWidget);
      expect(fakes.server.intervalDays, 3, reason: 'nothing was overwritten');
      expect(_enabled(tester, _filled('Save changes')), isFalse);

      // Now a deliberate save works.
      await tapText(tester, 'Every week');
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(fakes.server.intervalDays, 7);
      expect(
        find.textContaining('This was changed somewhere else'),
        findsNothing,
      );
    });

    testWidgets('an open incident locks the form', (tester) async {
      final fakes = _fakes(active: true);
      fakes.server.openIncident();
      await _open(tester, fakes);
      expect(find.text('A check-in is overdue'), findsOneWidget);
      expect(
        find.text(
          "This can't be changed while a check-in is overdue. Check in first to make changes.",
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Every week'))
            .onSelected,
        isNull,
      );
      expect(_enabled(tester, _filled('Save changes')), isFalse);
      expect(find.text('Turn off check-ins'), findsNothing);
      expect(find.text('Turn on check-ins'), findsNothing);
    });

    testWidgets('an incident that opened after the page loaded is said '
        'calmly on save', (tester) async {
      final fakes = _fakes(active: true);
      await _open(tester, fakes);
      await tapText(tester, 'Every week');
      fakes.server.openIncident();
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(
        find.text(
          "This can't be changed while a check-in is overdue. Check in first to make changes.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('a value set elsewhere is kept as a choice', (tester) async {
      final fakes = _fakes();
      fakes.server
        ..intervalDays = 5
        ..reminderLead = 120;
      await _open(tester, fakes);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Every 5 days'))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<ChoiceChip>(
              find.widgetWithText(ChoiceChip, '2 hours before'),
            )
            .selected,
        isTrue,
      );
    });

    testWidgets('the schedule that cannot be loaded says so and can be '
        'tried again', (tester) async {
      final fakes = _fakes();
      fakes.server.failures['get'] = [const NetworkFailure()];
      final container = await _open(tester, fakes);
      expect(find.textContaining("You're offline"), findsOneWidget);
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.text('Check-ins are off'), findsOneWidget);
      expect(container.read(scheduleControllerProvider).value, isNotNull);
    });

    testWidgets('another failure while saving is shown and the draft is '
        'kept', (tester) async {
      final fakes = _fakes();
      fakes.server.failures['save'] = [const ServerFailure(statusCode: 500)];
      await _open(tester, fakes);
      await tapText(tester, 'Every week');
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Something went wrong on our side'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Every week'))
            .selected,
        isTrue,
      );
      expect(_enabled(tester, _filled('Save changes')), isTrue);
    });

    testWidgets('fits at 2.0 text scale', (tester) async {
      await openApp(
        tester,
        fakes: _fakes(active: true),
        route: AppRoutes.settingsSchedule,
        textScale: 2,
        size: const Size(320, 690),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Settings > Check-in history', () {
    Future<void> record(TestFakes fakes, int count) async {
      for (var i = 0; i < count; i++) {
        fakes.clock.advance(const Duration(minutes: 1));
        await fakes.server.checkIn(idempotencyKey: 'history-key-$i-00000');
      }
    }

    testWidgets('lists check-ins newest first, in the profile timezone, with '
        'where they came from', (tester) async {
      final fakes = _fakes();
      await record(fakes, 2);
      fakes.server.addHistory(
        CheckInHistoryItem(
          id: 'web-1',
          kind: CheckInKind.ok,
          source: CheckInSource.web,
          receivedAt: DateTime.utc(2026, 10, 7, 14, 30),
        ),
      );
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.settingsCheckInHistory,
      );

      expect(find.text('Times are in Asia/Kolkata.'), findsOneWidget);
      expect(find.text('Checked in'), findsNWidgets(3));
      expect(find.text('From the app'), findsNWidgets(2));
      expect(find.text('From the web'), findsOneWidget);
      // 12:02 UTC is 5:32 PM in Asia/Kolkata; 14:30 UTC is 8:00 PM.
      expect(find.textContaining('5:32 PM'), findsOneWidget);
      expect(find.textContaining('5:31 PM'), findsOneWidget);
      expect(find.textContaining('8:00 PM'), findsOneWidget);
      expect(find.textContaining('Oct 8'), findsWidgets);
      expect(find.textContaining('Oct 7'), findsOneWidget);
      final first = tester.getTopLeft(find.textContaining('5:32 PM')).dy;
      final second = tester.getTopLeft(find.textContaining('5:31 PM')).dy;
      expect(first, lessThan(second));
    });

    testWidgets('rows read as one sentence to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      final fakes = _fakes();
      await record(fakes, 1);
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.settingsCheckInHistory,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^Checked in, .*5:31 PM, From the app$')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('nothing yet is an empty state', (tester) async {
      await openApp(
        tester,
        fakes: _fakes(),
        route: AppRoutes.settingsCheckInHistory,
      );
      expect(find.text('No check-ins yet'), findsOneWidget);
      expect(
        find.text('When you check in, it will appear here.'),
        findsOneWidget,
      );
    });

    testWidgets('more pages load on request, and a failure keeps the list', (
      tester,
    ) async {
      final fakes = _fakes();
      await record(fakes, 24);
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.settingsCheckInHistory,
      );
      expect(find.text('Checked in'), findsNWidgets(20));

      fakes.server.failures['history'] = [const NetworkFailure()];
      await tapText(tester, 'Show more');
      await tester.pumpAndSettle();
      expect(find.text('Checked in'), findsNWidgets(20));
      expect(find.textContaining("You're offline"), findsOneWidget);

      await tapText(tester, 'Show more');
      await tester.pumpAndSettle();
      expect(find.text('Checked in'), findsNWidgets(24));
      expect(find.text('Show more'), findsNothing);
    });

    testWidgets('a failed first load says so and can be tried again', (
      tester,
    ) async {
      final fakes = _fakes();
      fakes.server.failures['history'] = [const NetworkFailure()];
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.settingsCheckInHistory,
      );
      expect(find.textContaining("You're offline"), findsOneWidget);
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.text('No check-ins yet'), findsOneWidget);
    });

    testWidgets('a kind or source from a newer server is shown plainly', (
      tester,
    ) async {
      final fakes = _fakes();
      fakes.server
        ..addHistory(
          CheckInHistoryItem(
            id: 'x',
            kind: CheckInKind.unknown,
            source: CheckInSource.unknown,
            receivedAt: DateTime.utc(2026, 10, 7),
          ),
        )
        ..addHistory(
          CheckInHistoryItem(
            id: 'y',
            kind: CheckInKind.safe,
            source: CheckInSource.app,
            receivedAt: DateTime.utc(2026, 10, 6),
          ),
        );
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.settingsCheckInHistory,
      );
      expect(find.text('Check-in'), findsOneWidget);
      expect(find.text('From another place'), findsOneWidget);
      expect(find.text('Confirmed safe'), findsOneWidget);
    });

    testWidgets('pull to refresh reads again', (tester) async {
      final fakes = _fakes();
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.settingsCheckInHistory,
      );
      await record(fakes, 1);
      await tester.fling(
        find.byType(SingleChildScrollView).first,
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.text('Checked in'), findsOneWidget);
    });

    testWidgets('a failed pull to refresh says so', (tester) async {
      final fakes = _fakes();
      await record(fakes, 1);
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.settingsCheckInHistory,
      );
      fakes.server.failures['history'] = [const NetworkFailure()];
      await tester.fling(
        find.byType(SingleChildScrollView).first,
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.text('Checked in'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
    });
  });
}
