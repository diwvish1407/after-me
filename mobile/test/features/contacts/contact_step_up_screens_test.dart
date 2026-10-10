import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/design_system/design_system.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/contacts/presentation/contact_detail_screen.dart';
import 'package:afterme/features/contacts/presentation/edit_contact_screen.dart';
import 'package:afterme/features/contacts/presentation/people_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

/// Taking someone who is told out of a safety net that is on needs the password
/// (SECURITY.md §7, 403 `reauth_required`): removing them, or changing their email
/// address. The sheet says why and the very same request is sent again once. Someone who
/// is in no stage, and everything while check-ins are off (onboarding), never asks.
/// Switching a contact off (`is_active` false) has no control in the app yet; the
/// controller test covers it.

const _removeReason =
    'Removing a trusted contact from your plan needs your password because it changes who is told.';
const _emailReason =
    'Changing the email address of someone in your plan needs your password because it changes who is told.';

/// Check-ins are on (or, with [on] false, off as during onboarding). Mom (c1) is told at
/// stage 1; Bro (c2) is in no stage.
TestFakes _active({bool on = true}) {
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
      ),
    ],
  );
  fakes.plan.seedStandard(['c1']);
  if (on) {
    fakes.server.activateNow();
  }
  return fakes;
}

/// A few frames. `pumpAndSettle` cannot be used while a button shows its busy spinner
/// behind the password sheet: an indeterminate indicator never settles.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

int _calls(TestFakes fakes, String method) =>
    fakes.contacts.calls.where((c) => c == method).length;

int _reauths(TestFakes fakes) =>
    fakes.auth.calls.where((c) => c == 'reauth').length;

/// Detail page of [id]: Remove, then the confirmation sheet's Remove.
Future<void> _remove(WidgetTester tester, TestFakes fakes, String id) async {
  await openApp(tester, fakes: fakes, route: AppRoutes.contactDetail(id));
  await tapText(tester, 'Remove');
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
  await _frames(tester);
}

Future<void> _confirmPassword(WidgetTester tester, String password) async {
  await typeInto(tester, 'Password', password);
  await tapText(tester, 'Confirm');
  await _frames(tester);
}

void main() {
  group('Removing a contact', () {
    testWidgets('who is in a stage asks for the password, says why, then '
        'removes them once', (tester) async {
      final fakes = _active();
      await _remove(tester, fakes, 'c1');

      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(find.text(_removeReason), findsOneWidget);
      expect(fakes.contacts.contacts, hasLength(2), reason: 'not removed yet');
      expect(_calls(fakes, 'delete'), 1);

      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();

      expect(find.text("Confirm it's you"), findsNothing);
      expect(_calls(fakes, 'delete'), 2);
      expect(_reauths(fakes), 1);
      expect(fakes.contacts.contacts.map((c) => c.id), ['c2']);
      expect(snackText(tester), 'Mom was removed.');
      expect(find.byType(PeopleScreen), findsOneWidget);
      expect(find.byType(ContactDetailScreen), findsNothing);
    });

    testWidgets('closing the sheet keeps the contact and says nothing', (
      tester,
    ) async {
      final fakes = _active();
      await _remove(tester, fakes, 'c1');
      expect(find.text("Confirm it's you"), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await _frames(tester);

      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.contacts.contacts, hasLength(2));
      expect(_calls(fakes, 'delete'), 1, reason: 'not sent again');
      expect(_reauths(fakes), 0);
      expect(snackText(tester), isNull);
      expect(find.byType(FailureNotice), findsNothing);
      expect(find.byType(ContactDetailScreen), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Remove'))
            .onPressed,
        isNotNull,
        reason: 'not stuck busy',
      );
    });

    testWidgets('a wrong password stays in the sheet and removes nobody', (
      tester,
    ) async {
      final fakes = _active();
      await _remove(tester, fakes, 'c1');

      await _confirmPassword(tester, 'not the password');
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(
        find.text("That password didn't match. Try again."),
        findsOneWidget,
      );
      expect(fakes.contacts.contacts, hasLength(2));
      expect(_calls(fakes, 'delete'), 1);
      expect(find.byType(FailureNotice), findsNothing);

      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();
      expect(fakes.contacts.contacts.map((c) => c.id), ['c2']);
      expect(_calls(fakes, 'delete'), 2);
    });

    testWidgets('who is in no stage is removed without a password', (
      tester,
    ) async {
      final fakes = _active();
      await _remove(tester, fakes, 'c2');
      await tester.pumpAndSettle();

      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.contacts.contacts.map((c) => c.id), ['c1']);
      expect(_calls(fakes, 'delete'), 1);
      expect(_reauths(fakes), 0);
      expect(snackText(tester), 'Bro was removed.');
    });

    testWidgets('while check-ins are off (onboarding) nobody asks, even for '
        'someone who is in a stage', (tester) async {
      final fakes = _active(on: false);
      await _remove(tester, fakes, 'c1');
      await tester.pumpAndSettle();

      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.contacts.contacts.map((c) => c.id), ['c2']);
      expect(_reauths(fakes), 0);
    });

    testWidgets('with a recent password no sheet is needed', (tester) async {
      final fakes = _active();
      fakes.auth.reauthenticated = true;
      await _remove(tester, fakes, 'c1');
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.contacts.contacts.map((c) => c.id), ['c2']);
      expect(_calls(fakes, 'delete'), 1);
    });

    testWidgets('another failure after the password is shown calmly', (
      tester,
    ) async {
      final fakes = _active();
      fakes.contacts.failures['delete'] = [
        const ForbiddenFailure(code: 'reauth_required'),
        const NetworkFailure(),
      ];
      await _remove(tester, fakes, 'c1');
      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(fakes.contacts.contacts, hasLength(2));
      expect(find.byType(ContactDetailScreen), findsOneWidget);
    });
  });

  group('Changing the email address of a contact', () {
    Future<void> editEmail(
      WidgetTester tester,
      TestFakes fakes,
      String id, {
      String email = 'mum@example.com',
    }) async {
      await openApp(tester, fakes: fakes, route: AppRoutes.contactEdit(id));
      await typeInto(tester, 'Their email', email);
      await tapText(tester, 'Save changes');
      await _frames(tester);
    }

    testWidgets('who is in a stage asks for the password, says why, then '
        'saves the same change once', (tester) async {
      final fakes = _active();
      await editEmail(tester, fakes, 'c1');

      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(find.text(_emailReason), findsOneWidget);
      expect(fakes.contacts.contacts.first.email, 'mom@example.com');
      expect(fakes.contacts.invitations, isEmpty);
      expect(_calls(fakes, 'update'), 1);

      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();

      expect(find.text("Confirm it's you"), findsNothing);
      expect(_calls(fakes, 'update'), 2);
      expect(_reauths(fakes), 1);
      final saved = fakes.contacts.contacts.first;
      expect(saved.email, 'mum@example.com');
      expect(saved.verificationStatus, VerificationStatus.pending);
      expect(fakes.contacts.invitations['c1'], 1, reason: 'invited once');
      expect(snackText(tester), contains('mum@example.com'));
      expect(find.byType(EditContactScreen), findsNothing);
    });

    testWidgets('closing the sheet leaves the form as it was, saves nothing '
        'and says nothing', (tester) async {
      final fakes = _active();
      await editEmail(tester, fakes, 'c1');
      expect(find.text("Confirm it's you"), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await _frames(tester);

      expect(find.text("Confirm it's you"), findsNothing);
      expect(find.byType(EditContactScreen), findsOneWidget);
      expect(fakes.contacts.contacts.first.email, 'mom@example.com');
      expect(_calls(fakes, 'update'), 1, reason: 'not sent again');
      expect(_reauths(fakes), 0);
      expect(snackText(tester), isNull);
      expect(find.byType(FailureNotice), findsNothing);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Their email'))
            .controller!
            .text,
        'mum@example.com',
        reason: 'the edit is still there',
      );
      expect(find.textContaining('Changing the email address'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save changes'),
            )
            .onPressed,
        isNotNull,
        reason: 'not stuck busy',
      );
    });

    testWidgets('a wrong password stays in the sheet and saves nothing', (
      tester,
    ) async {
      final fakes = _active();
      await editEmail(tester, fakes, 'c1');

      await _confirmPassword(tester, 'not the password');
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(
        find.text("That password didn't match. Try again."),
        findsOneWidget,
      );
      expect(fakes.contacts.contacts.first.email, 'mom@example.com');
      expect(_calls(fakes, 'update'), 1);

      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();
      expect(fakes.contacts.contacts.first.email, 'mum@example.com');
      expect(_calls(fakes, 'update'), 2);
    });

    testWidgets('an address the server refuses after the password is shown '
        'on the field', (tester) async {
      final fakes = _active();
      fakes.contacts.failures['update'] = [
        const ForbiddenFailure(code: 'reauth_required'),
        const CannotBeOwnEmailFailure(),
      ];
      await editEmail(tester, fakes, 'c1', email: 'diwakar@example.com');
      await _confirmPassword(tester, fakes.auth.password);
      await tester.pumpAndSettle();

      expect(find.text("Confirm it's you"), findsNothing);
      expect(find.byType(EditContactScreen), findsOneWidget);
      expect(fieldError(tester, 'Their email'), isNotNull);
      expect(fakes.contacts.contacts.first.email, 'mom@example.com');
    });

    testWidgets('a name or a phone number alone never asks', (tester) async {
      final fakes = _active();
      await openApp(tester, fakes: fakes, route: AppRoutes.contactEdit('c1'));
      await typeInto(tester, 'Their name', 'Mum');
      await typeInto(tester, 'Their phone (optional)', '+14155550123');
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();

      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.contacts.contacts.first.displayName, 'Mum');
      expect(fakes.contacts.contacts.first.email, 'mom@example.com');
      expect(_reauths(fakes), 0);
      expect(find.byType(EditContactScreen), findsNothing);
    });

    testWidgets('who is in no stage may be given another address freely', (
      tester,
    ) async {
      final fakes = _active();
      await editEmail(tester, fakes, 'c2', email: 'brother@example.com');
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.contacts.contacts.last.email, 'brother@example.com');
      expect(_reauths(fakes), 0);
    });

    testWidgets('while check-ins are off (onboarding) nobody asks', (
      tester,
    ) async {
      final fakes = _active(on: false);
      await editEmail(tester, fakes, 'c1');
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.contacts.contacts.first.email, 'mum@example.com');
      expect(_reauths(fakes), 0);
    });
  });
}
