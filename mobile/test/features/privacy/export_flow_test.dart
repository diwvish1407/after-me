import 'dart:async';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/platform/file_export.dart';
import 'package:afterme/core/security/app_lock/app_lock_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

/// Settings > Privacy and data > Export my data (USER_FLOWS.md §11, SECURITY.md §13):
/// the explanation first, then the password, the request at once, and the bytes straight
/// to the system's save dialog. "Saved" only after the system confirmed the write.
const _explain = 'The file holds your instructions as plain, readable text.';
const _saved = 'Saved. The file is where you chose to put it.';
const _cancelled =
    "Nothing was saved. You closed the save screen, so the file wasn't kept. "
    'Export again if you still want a copy.';
const _reason =
    'Exporting your data needs your password, because the file holds your '
    'instructions as readable text.';

Future<void> _openExport(WidgetTester tester, TestFakes fakes) =>
    openApp(tester, fakes: fakes, route: AppRoutes.settingsExport);

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Taps the export button (the sheet that may follow keeps a caret blinking, so this
/// pumps frames instead of settling).
Future<void> _tapExport(WidgetTester tester) async {
  final button = find.widgetWithText(FilledButton, 'Export my data');
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await _frames(tester);
}

/// Taps the button, then enters the password in the sheet that follows.
Future<void> _exportWithPassword(WidgetTester tester, TestFakes fakes) async {
  await _tapExport(tester);
  expect(find.text("Confirm it's you"), findsOneWidget);
  await typeInto(tester, 'Password', fakes.auth.password);
  await tapText(tester, 'Confirm');
  await _frames(tester);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Settings has the entry', (tester) async {
    final fakes = TestFakes();
    await openApp(tester, fakes: fakes, route: AppRoutes.settings);
    expect(find.text('Privacy and data'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Export my data'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tapText(tester, 'Export my data');
    await tester.pumpAndSettle();
    expect(find.textContaining(_explain), findsOneWidget);
  });

  testWidgets('explains what is in the file, that it is readable text and '
      'that the person chooses where it goes, before anything is asked or '
      'sent', (tester) async {
    final fakes = TestFakes();
    await _openExport(tester, fakes);
    expect(find.text('Keep this file safe'), findsOneWidget);
    expect(find.textContaining(_explain), findsOneWidget);
    expect(
      find.text("You choose where it is saved. AfterMe doesn't keep a copy."),
      findsOneWidget,
    );
    expect(
      find.text(
        "We'll ask for your password first. You can export up to 3 times an "
        'hour.',
      ),
      findsOneWidget,
    );
    expect(fakes.accountData.calls, isEmpty);
    expect(fakes.auth.calls, isNot(contains('reauth')));
    expect(fakes.exportGateway.saves, isEmpty);
  });

  testWidgets('the password, the request at once, the bytes to the save '
      'dialog, and Saved only after the system confirmed', (tester) async {
    final fakes = TestFakes();
    final dialog = Completer<void>();
    fakes.exportGateway.gate = dialog.future;
    await _openExport(tester, fakes);
    await _tapExport(tester);
    expect(find.text("Confirm it's you"), findsOneWidget);
    expect(find.text(_reason), findsOneWidget);
    await typeInto(tester, 'Password', fakes.auth.password);
    await tapText(tester, 'Confirm');
    await _frames(tester);

    // The system's save dialog is open: nothing is "saved" yet.
    expect(fakes.exportGateway.saves, hasLength(1));
    final save = fakes.exportGateway.saves.single;
    expect(save.bytes, fakes.accountData.exportBytes);
    expect(save.name, 'afterme-export.json');
    expect(save.mimeType, 'application/json');
    expect(find.text(_saved), findsNothing);
    expect(
      find.text('Choose where to save it, then come back here.'),
      findsOneWidget,
    );

    dialog.complete();
    await tester.pumpAndSettle();
    expect(find.text(_saved), findsOneWidget);
    expect(
      find.text('Choose where to save it, then come back here.'),
      findsNothing,
    );
    // One password, one confirmation spent, two requests: the one that asked for the
    // password, and the one that carried it.
    expect(fakes.auth.calls.where((c) => c == 'reauth'), hasLength(1));
    expect(fakes.accountData.calls, ['export', 'export']);
    // Nothing of the file was kept on the phone: only the session's own id is there.
    expect(fakes.secure.values, {SessionKeys.userId: 'user-1'});
  });

  testWidgets('the save dialog takes the app to the background without '
      'locking it', (tester) async {
    final fakes = TestFakes();
    final dialog = Completer<void>();
    fakes.exportGateway.gate = dialog.future;
    final container = await openApp(
      tester,
      fakes: fakes,
      route: AppRoutes.settingsExport,
    );
    final lock = container.read(appLockControllerProvider.notifier);
    await fakes.auth.reauth(password: fakes.auth.password);
    await lock.enable('test');
    await lock.setTimeout(AppLockTimeout.immediately);
    expect(container.read(appLockControllerProvider).enabled, isTrue);
    await _tapExport(tester);
    expect(fakes.exportGateway.saves, hasLength(1));

    // The system dialog is in front of the app.
    lock.didChangeLifecycle(AppLifecycleState.paused);
    lock.didChangeLifecycle(AppLifecycleState.resumed);
    expect(container.read(appLockControllerProvider).locked, isFalse);
    dialog.complete();
    await tester.pumpAndSettle();
    expect(find.text(_saved), findsOneWidget);
    expect(container.read(appLockControllerProvider).locked, isFalse);

    // Once it is over, going to the background locks again as it always did.
    lock.didChangeLifecycle(AppLifecycleState.paused);
    expect(container.read(appLockControllerProvider).locked, isTrue);
  });

  testWidgets('closing the password sheet exports nothing and says nothing', (
    tester,
  ) async {
    final fakes = TestFakes();
    await _openExport(tester, fakes);
    await _tapExport(tester);
    await tapText(tester, 'Cancel');
    await tester.pumpAndSettle();
    expect(fakes.exportGateway.saves, isEmpty);
    expect(find.text(_saved), findsNothing);
    expect(find.text(_cancelled), findsNothing);
    // The button is back and works.
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Export my data'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('a password confirmed less than a minute ago goes straight '
      'through; the export spends it, so the next one asks again', (
    tester,
  ) async {
    final fakes = TestFakes();
    await _openExport(tester, fakes);
    await fakes.auth.reauth(password: fakes.auth.password);
    fakes.clock.advance(const Duration(seconds: 30));
    await _tapExport(tester);
    expect(find.text("Confirm it's you"), findsNothing);
    expect(find.text(_saved), findsOneWidget);
    expect(fakes.accountData.calls, ['export']);

    await _tapExport(tester);
    expect(find.text("Confirm it's you"), findsOneWidget);
    expect(fakes.exportGateway.saves, hasLength(1));
  });

  testWidgets('a password confirmed more than a minute ago is asked for '
      'again', (tester) async {
    final fakes = TestFakes();
    await _openExport(tester, fakes);
    await fakes.auth.reauth(password: fakes.auth.password);
    fakes.clock.advance(const Duration(seconds: 61));
    await _tapExport(tester);
    expect(find.text("Confirm it's you"), findsOneWidget);
    expect(fakes.exportGateway.saves, isEmpty);
  });

  testWidgets('closing the save dialog says nothing was saved and that the '
      'file was not kept', (tester) async {
    final fakes = TestFakes();
    fakes.exportGateway.answers.add(FileExportResult.cancelled);
    await _openExport(tester, fakes);
    await _exportWithPassword(tester, fakes);
    expect(find.text(_cancelled), findsOneWidget);
    expect(find.text(_saved), findsNothing);
  });

  testWidgets('a write that failed says so and that no copy was kept', (
    tester,
  ) async {
    final fakes = TestFakes();
    fakes.exportGateway.answers.add(
      const FileExportException(FileExportError.failed),
    );
    await _openExport(tester, fakes);
    await _exportWithPassword(tester, fakes);
    expect(
      find.text(
        "The file couldn't be saved there, and AfterMe kept no copy. Try again "
        'and choose another place.',
      ),
      findsOneWidget,
    );
    expect(find.text(_saved), findsNothing);
  });

  testWidgets('no app that can save a file is said plainly', (tester) async {
    final fakes = TestFakes();
    fakes.exportGateway.answers.add(
      const FileExportException(FileExportError.unavailable),
    );
    await _openExport(tester, fakes);
    await _exportWithPassword(tester, fakes);
    expect(
      find.text(
        'There is no app on this phone that can save a file, so nothing was '
        'saved.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('an export too large for this phone is said calmly and the '
      'save dialog is never opened', (tester) async {
    final fakes = TestFakes();
    fakes.accountData.tooLarge = true;
    await _openExport(tester, fakes);
    await _exportWithPassword(tester, fakes);
    expect(
      find.textContaining('too large for this phone to handle'),
      findsOneWidget,
    );
    expect(fakes.exportGateway.saves, isEmpty);
    expect(find.text(_saved), findsNothing);
  });

  testWidgets('a lost connection says nothing was saved; the next try needs '
      'the password again because the first one was spent', (tester) async {
    final fakes = TestFakes();
    fakes.accountData.loseAnswer = true;
    await _openExport(tester, fakes);
    await _exportWithPassword(tester, fakes);
    expect(
      find.text(
        "We couldn't get your file, so nothing was saved. Try again when "
        "you're back online.",
      ),
      findsOneWidget,
    );
    expect(fakes.exportGateway.saves, isEmpty);

    // Back online: it works, with a new password.
    await _exportWithPassword(tester, fakes);
    expect(find.text(_saved), findsOneWidget);
    expect(find.textContaining("We couldn't get your file"), findsNothing);
    expect(fakes.exportGateway.saves, hasLength(1));
  });

  testWidgets('a server problem is worded as not confirmed too', (
    tester,
  ) async {
    final fakes = TestFakes();
    await _openExport(tester, fakes);
    await fakes.auth.reauth(password: fakes.auth.password);
    fakes.accountData.failures['export'] = [
      const ServerFailure(statusCode: 500),
    ];
    await _tapExport(tester);
    expect(find.textContaining("We couldn't get your file"), findsOneWidget);
  });

  testWidgets('the fourth export in an hour is refused in the app\'s words', (
    tester,
  ) async {
    final fakes = TestFakes();
    await _openExport(tester, fakes);
    for (var i = 0; i < 3; i++) {
      await _exportWithPassword(tester, fakes);
      expect(find.text(_saved), findsOneWidget);
    }
    await _exportWithPassword(tester, fakes);
    expect(find.textContaining('Try again in 40 minutes'), findsOneWidget);
    expect(find.text(_saved), findsNothing);
    expect(fakes.exportGateway.saves, hasLength(3));
  });

  testWidgets('the button is busy while the request is on its way and a '
      'second tap sends nothing', (tester) async {
    final fakes = TestFakes();
    final wait = Completer<void>();
    await _openExport(tester, fakes);
    await fakes.auth.reauth(password: fakes.auth.password);
    fakes.accountData.gate = wait.future;
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Export my data'),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Export my data'));
    await tester.pump();
    expect(find.text('Getting your file…'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
      isNull,
    );
    expect(fakes.accountData.calls, ['export']);
    wait.complete();
    await tester.pumpAndSettle();
    expect(find.text(_saved), findsOneWidget);
    expect(fakes.accountData.calls, ['export']);
  });

  testWidgets('leaving the screen while the file is on its way drops it: '
      'nothing is saved behind the person\'s back', (tester) async {
    final fakes = TestFakes();
    final wait = Completer<void>();
    final container = await openApp(
      tester,
      fakes: fakes,
      route: AppRoutes.settingsExport,
    );
    await fakes.auth.reauth(password: fakes.auth.password);
    fakes.accountData.gate = wait.future;
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Export my data'),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Export my data'));
    await tester.pump();
    container.read(routerProvider).go(AppRoutes.settings);
    await tester.pumpAndSettle();
    wait.complete();
    await tester.pumpAndSettle();
    expect(fakes.exportGateway.saves, isEmpty);
  });
}
