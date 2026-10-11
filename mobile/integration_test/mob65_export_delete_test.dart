// MOB-65: export and delete (TEST_PLAN §6).
//
// Export: the screen, the password, the real `POST /v1/me/export`. The file is handed to
// Android's Storage Access Framework picker, which is system UI and is not driven here:
// the picker is replaced by a gateway that records the bytes and answers "saved". What
// the app shows before and after that hand-off, and the bytes it received from the real
// server, are asserted. The real picker remains a manual check.
//
// Delete: type DELETE, the password, the closed-account screen with the purge date, then
// sign-in, which must now fail.
import 'dart:convert';
import 'dart:typed_data';

import 'package:afterme/core/platform/file_export.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import 'support/backend.dart';
import 'support/harness.dart';
import 'support/journeys.dart';

/// Stands in for the system's save dialog: keeps what it is given and says "saved".
class RecordingExportGateway implements FileExportGateway {
  Uint8List? bytes;
  String? name;
  String? mimeType;
  int calls = 0;

  @override
  Future<FileExportResult> save({
    required Uint8List bytes,
    required String suggestedName,
    String mimeType = 'application/json',
  }) async {
    calls++;
    this.bytes = bytes;
    name = suggestedName;
    this.mimeType = mimeType;
    return FileExportResult.saved;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final backend = Backend.fromEnvironment();
  tearDownAll(backend.close);

  integrationTest('MOB-65 export and delete the account', backend, (h) async {
    final gateway = RecordingExportGateway();
    final account = await signUpAndActivate(
      h,
      overrides: [fileExportGatewayProvider.overrideWithValue(gateway)],
    );

    // --- export, up to and after the hand-off to the system's save dialog ----------
    await h.tapTab(l10n.navSettings);
    await h.tapText(l10n.settingsExport);
    await h.waitForText(l10n.exportWarningTitle);
    await h.expectPresent(
      find.text(l10n.exportNeedsPassword),
      'the note that the password is asked for',
    );
    await h.tapButton(l10n.exportButton);
    await h.waitForText(l10n.reauthTitle);
    await h.expectPresent(
      find.text(l10n.reauthReasonExportData),
      'the reason the password is asked for',
    );
    await h.typeInto(l10n.fieldPassword, account.password);
    await h.tapButton(l10n.reauthConfirm);
    await h.waitForText(l10n.exportSaved, timeout: const Duration(seconds: 30));
    expect(gateway.calls, 1, reason: 'the file was handed over once');
    expect(gateway.mimeType, 'application/json');
    final export =
        jsonDecode(utf8.decode(gateway.bytes!)) as Map<String, dynamic>;
    final exported = export['account'] as Map<String, dynamic>;
    expect(exported['email'], account.email);
    final contacts = export['contacts'] as List<dynamic>;
    expect(contacts, hasLength(1));
    expect(
      (contacts.single as Map<String, dynamic>)['display_name'],
      TestAccount.contactName,
    );

    // --- delete -------------------------------------------------------------------------
    await h.tester.pageBack();
    await h.pump(const Duration(milliseconds: 500));
    await h.tapText(l10n.settingsDelete);
    await h.waitForText(l10n.deleteTitle);
    // The button stays off until the word matches exactly.
    await h.typeInto(l10n.deleteConfirmLabel, 'delete');
    await h.expectPresent(
      find.byWidgetPredicate(
        (w) => w is ButtonStyleButton && w.onPressed == null,
      ),
      'a disabled delete button before DELETE is typed exactly',
    );
    await h.typeInto(l10n.deleteConfirmLabel, 'DELETE');
    await h.tapButton(l10n.deleteButton);
    await h.waitForText(l10n.reauthTitle);
    await h.expectPresent(
      find.text(l10n.reauthReasonDeleteAccount),
      'the reason the password is asked for',
    );
    await h.typeInto(l10n.fieldPassword, account.password);
    await h.tapButton(l10n.reauthConfirm);

    // The closed-account screen, with the purge date the server gave.
    await h.waitForText(
      l10n.accountClosedTitle,
      timeout: const Duration(seconds: 30),
    );
    await h.expectAbsent(find.byType(HomeScreen), 'Home (the session is gone)');
    // "The rest of your information is removed by <date>."
    final prefix = l10n.accountClosedPurge('\u0000').split('\u0000').first;
    final purgeFinder = find.textContaining(prefix);
    await h.expectPresent(purgeFinder, 'the purge date');
    final purgeText = (h.tester.widget(purgeFinder.first) as Text).data!;
    final dateText = purgeText
        .substring(prefix.length)
        .replaceAll(RegExp(r'\.$'), '')
        .trim();
    final purgeDate = DateFormat.yMMMMEEEEd('en').parse(dateText);
    final serverNow = (await backend.clock()).serverTime;
    final days = purgeDate.difference(serverNow).inDays;
    expect(
      days,
      inInclusiveRange(29, 31),
      reason: 'purge date "$dateText" should be 30 days after server time',
    );

    // Continue goes to sign-in; the same credentials no longer work.
    await h.tapButton(l10n.accountClosedContinue);
    await h.waitForText(l10n.signInHeading);
    await h.typeInto(l10n.fieldEmail, account.email);
    await h.typeInto(l10n.fieldPassword, account.password);
    await h.tapButton(l10n.signInSubmit);
    await h.waitForText(
      l10n.signInWrongDetails,
      timeout: const Duration(seconds: 30),
    );
    await h.expectAbsent(find.byType(HomeScreen), 'Home after the sign-in');
    final status = await backend.loginStatus(account.email, account.password);
    expect(status, isNot(200), reason: 'the server must refuse the login');
    expect(status, anyOf(401, 403), reason: 'refused, not a server error');
  });
}
