import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/platform/contact_picker.dart';
import 'package:afterme/core/security/app_lock/app_lock_controller.dart';
import 'package:afterme/core/security/app_lock/local_auth_gateway.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/contacts/presentation/contact_detail_screen.dart';
import 'package:afterme/features/contacts/presentation/contact_form.dart';
import 'package:afterme/features/contacts/presentation/edit_contact_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

TestFakes _fakes(List<TrustedContact> contacts, {String tier = 'premium'}) =>
    TestFakes()
      ..contacts = InMemoryContactsRepository(tier: tier, initial: contacts);

void main() {
  group('Add contact', () {
    testWidgets('validates on the device before anything is sent', (
      tester,
    ) async {
      final fakes = TestFakes();
      await openApp(tester, fakes: fakes, route: AppRoutes.peopleAdd);
      await tapText(tester, 'Save and send invitation');
      expect(fieldError(tester, 'Their name'), 'Please fill this in.');
      expect(fieldError(tester, 'Their email'), 'Please fill this in.');
      expect(find.text('Choose how you know them.'), findsOneWidget);

      await typeInto(tester, 'Their name', 'Mom');
      await typeInto(tester, 'Their email', 'not-an-email');
      await typeInto(tester, 'Their phone (optional)', '12');
      await tapText(tester, 'Mother');
      await tapText(tester, 'Save and send invitation');
      expect(fieldError(tester, 'Their email'), 'Enter a valid email address.');
      expect(fieldError(tester, 'Their phone (optional)'), isNotNull);
      expect(fakes.contacts.calls, isNot(contains('create')));

      await typeInto(tester, 'Their name', 'see example.com');
      await tapText(tester, 'Save and send invitation');
      expect(fieldError(tester, 'Their name'), isNotNull);
      await typeInto(tester, 'Their name', 'AfterMe');
      await tapText(tester, 'Save and send invitation');
      expect(fieldError(tester, 'Their name'), isNotNull);
    });

    testWidgets('typing clears the error of that field', (tester) async {
      await openApp(tester, route: AppRoutes.peopleAdd);
      await tapText(tester, 'Save and send invitation');
      expect(fieldError(tester, 'Their name'), isNotNull);
      await typeInto(tester, 'Their name', 'M');
      expect(fieldError(tester, 'Their name'), isNull);
    });

    testWidgets('explains the invitation before saving', (tester) async {
      await openApp(tester, route: AppRoutes.peopleAdd);
      expect(
        find.textContaining(
          'We will email them an invitation they must accept.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a successful save shows the contact as Pending', (
      tester,
    ) async {
      final fakes = TestFakes();
      await openApp(tester, fakes: fakes, route: AppRoutes.peopleAdd);
      await fillContactForm(
        tester,
        email: ' Mom@Example.COM ',
        phone: '+1 (415) 555-0123',
      );
      await tapText(tester, 'Save and send invitation');
      await tester.pumpAndSettle();
      expect(find.byType(ContactDetailScreen), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Waiting for them to accept.'), findsOneWidget);
      expect(snackText(tester), contains('mom@example.com'));
      final saved = fakes.contacts.contacts.single;
      expect(saved.displayName, 'Mom');
      expect(saved.email, 'mom@example.com');
      expect(saved.phoneE164, '+14155550123', reason: 'spaces are removed');
      expect(fakes.contacts.invitations[saved.id], 1);
    });

    testWidgets('Other asks for a description and sends it', (tester) async {
      final fakes = TestFakes();
      await openApp(tester, fakes: fakes, route: AppRoutes.peopleAdd);
      expect(find.text('How do you know them?'), findsNothing);
      await tapText(tester, 'Other');
      expect(find.text('How do you know them?'), findsOneWidget);
      await typeInto(tester, 'How do you know them?', 'x' * 41);
      await typeInto(tester, 'Their name', 'Sam');
      await typeInto(tester, 'Their email', 'sam@example.com');
      await tapText(tester, 'Save and send invitation');
      expect(
        fieldError(tester, 'How do you know them?'),
        'Use 40 characters or fewer.',
      );
      await typeInto(tester, 'How do you know them?', 'Neighbour upstairs');
      await tapText(tester, 'Save and send invitation');
      await tester.pumpAndSettle();
      expect(
        fakes.contacts.contacts.single.relationshipLabel,
        'Neighbour upstairs',
      );
      expect(find.text('Neighbour upstairs'), findsOneWidget);
    });

    testWidgets('the label is dropped when another relationship is chosen', (
      tester,
    ) async {
      final fakes = TestFakes();
      await openApp(tester, fakes: fakes, route: AppRoutes.peopleAdd);
      await tapText(tester, 'Other');
      await typeInto(tester, 'How do you know them?', 'Neighbour');
      await tapText(tester, 'Friend');
      expect(find.text('How do you know them?'), findsNothing);
      await typeInto(tester, 'Their name', 'Sam');
      await typeInto(tester, 'Their email', 'sam@example.com');
      await tapText(tester, 'Save and send invitation');
      await tester.pumpAndSettle();
      expect(fakes.contacts.contacts.single.relationshipLabel, isNull);
    });

    testWidgets('your own address is explained on the email field', (
      tester,
    ) async {
      final fakes = TestFakes();
      await openApp(tester, fakes: fakes, route: AppRoutes.peopleAdd);
      await fillContactForm(tester, email: 'Diwakar@example.com');
      await tapText(tester, 'Save and send invitation');
      await tester.pumpAndSettle();
      expect(
        fieldError(tester, 'Their email'),
        "That's your own email address. Choose someone else.",
      );
      expect(find.byType(ContactDetailScreen), findsNothing);
      await typeInto(tester, 'Their email', 'mom@example.com');
      expect(fieldError(tester, 'Their email'), isNull);
    });

    testWidgets('a duplicate is explained on the email field', (tester) async {
      final fakes = _fakes([testContact()]);
      await openApp(tester, fakes: fakes, route: AppRoutes.peopleAdd);
      await fillContactForm(tester, name: 'Mum', email: 'MOM@example.com');
      await tapText(tester, 'Save and send invitation');
      await tester.pumpAndSettle();
      expect(
        fieldError(tester, 'Their email'),
        "You've already added someone with this email address.",
      );
    });

    testWidgets('the plan limit from the server opens the explanation', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.contacts.limit = 5;
      await openApp(tester, fakes: fakes, route: AppRoutes.peopleAdd);
      fakes.contacts.limit = 0;
      fakes.contacts.tier = 'free';
      await fillContactForm(tester);
      await tapText(tester, 'Save and send invitation');
      await tester.pumpAndSettle();
      expect(
        find.text("More trusted contacts aren't available yet"),
        findsOneWidget,
      );
      await tapText(tester, 'Close');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Their name'))
            .controller!
            .text,
        'Mom',
        reason: 'the form is kept',
      );
    });

    testWidgets('server field errors are shown on their fields', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.contacts.failures['create'] = [
        const ValidationFailure(
          code: 'validation_failed',
          fieldErrors: [
            ApiFieldError(field: 'display_name', code: 'display_name_link'),
            ApiFieldError(field: 'email', code: 'something_new'),
            ApiFieldError(field: 'phone_e164', code: 'invalid_phone'),
          ],
        ),
      ];
      await openApp(tester, fakes: fakes, route: AppRoutes.peopleAdd);
      await fillContactForm(tester, phone: '+14155550123');
      await tapText(tester, 'Save and send invitation');
      await tester.pumpAndSettle();
      expect(fieldError(tester, 'Their name'), isNotNull);
      expect(fieldError(tester, 'Their email'), 'Enter a valid email address.');
      expect(fieldError(tester, 'Their phone (optional)'), isNotNull);
    });

    testWidgets('label and relationship errors from the server', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.contacts.failures['create'] = [
        const ValidationFailure(
          code: 'validation_failed',
          fieldErrors: [
            ApiFieldError(field: 'relationship_label', code: 'too_long'),
          ],
        ),
        const ValidationFailure(
          code: 'validation_failed',
          fieldErrors: [
            ApiFieldError(field: 'relationship_label', code: 'weird'),
            ApiFieldError(field: 'relationship', code: 'required'),
          ],
        ),
      ];
      await openApp(tester, fakes: fakes, route: AppRoutes.peopleAdd);
      await tapText(tester, 'Other');
      await fillContactForm(tester, relationship: 'Other');
      await typeInto(tester, 'How do you know them?', 'Pal');
      await tapText(tester, 'Save and send invitation');
      await tester.pumpAndSettle();
      expect(
        fieldError(tester, 'How do you know them?'),
        'Use 40 characters or fewer.',
      );
      await tapText(tester, 'Save and send invitation');
      await tester.pumpAndSettle();
      expect(
        fieldError(tester, 'How do you know them?'),
        "That description contains characters we can't use.",
      );
      expect(find.text('Choose how you know them.'), findsOneWidget);
    });

    testWidgets('unmapped validation problems and network errors are shown '
        'calmly and the form is kept', (tester) async {
      final fakes = TestFakes();
      fakes.contacts.failures['create'] = [
        const ValidationFailure(code: 'validation_failed'),
        const ValidationFailure(
          code: 'validation_failed',
          fieldErrors: [ApiFieldError(field: 'surprise', code: 'x')],
        ),
        const NetworkFailure(),
      ];
      await openApp(tester, fakes: fakes, route: AppRoutes.peopleAdd);
      await fillContactForm(tester);
      await tapText(tester, 'Save and send invitation');
      await tester.pumpAndSettle();
      expect(
        find.textContaining("Some details need another look"),
        findsOneWidget,
      );
      await tapText(tester, 'Save and send invitation');
      await tester.pumpAndSettle();
      expect(
        find.textContaining("Some details need another look"),
        findsOneWidget,
      );
      await tapText(tester, 'Save and send invitation');
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Their email'))
            .controller!
            .text,
        'mom@example.com',
      );
      await tapText(tester, 'Save and send invitation');
      await tester.pumpAndSettle();
      expect(find.byType(ContactDetailScreen), findsOneWidget);
    });

    testWidgets('picks from the system picker without any permission', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.picker.result = const PickedContact(
        name: 'Brother',
        email: 'bro@example.com',
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.peopleAdd);
      await tapText(tester, 'Pick from my contacts');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Their name'))
            .controller!
            .text,
        'Brother',
      );
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Their email'))
            .controller!
            .text,
        'bro@example.com',
      );
      fakes.picker.result = const PickedContact(
        name: '',
        email: 'x@example.com',
      );
      await tapText(tester, 'Pick from my contacts');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Their name'))
            .controller!
            .text,
        'Brother',
        reason: 'an empty picked name keeps what was typed',
      );
      fakes.picker.unavailable = true;
      await tapText(tester, 'Pick from my contacts');
      await tester.pumpAndSettle();
      expect(
        find.textContaining("couldn't open your contacts"),
        findsOneWidget,
      );
    });

    testWidgets('the picker does not count as leaving the app', (tester) async {
      final fakes = TestFakes();
      fakes.prefs = freshPreferences({
        'afterme.onboardingUserId': 'user-1',
        'afterme.onboardingCompleted': true,
        'afterme.appLockEnabled': true,
        'afterme.appLockTimeoutMinutes': 0,
      });
      fakes.localAuth.outcomes.add(AuthOutcome.canceled);
      fakes.picker.result = const PickedContact(
        name: 'B',
        email: 'b@example.com',
      );
      final container = await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedIn,
      );
      await container.read(appLockControllerProvider.notifier).unlock('r');
      await tester.pumpAndSettle();
      container.read(routerProvider).go(AppRoutes.peopleAdd);
      await tester.pumpAndSettle();
      await tapText(tester, 'Pick from my contacts');
      await tester.pumpAndSettle();
      expect(container.read(appLockControllerProvider).locked, isFalse);
    });
  });

  group('Edit contact', () {
    testWidgets('shows the saved values and sends only what changed', (
      tester,
    ) async {
      final fakes = _fakes([testContact(phone: '+14155550123')]);
      await openApp(tester, fakes: fakes, route: AppRoutes.contactEdit('c1'));
      expect(find.byType(EditContactScreen), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Their name'))
            .controller!
            .text,
        'Mom',
      );
      expect(
        find.textContaining('We will email them an invitation'),
        findsNothing,
      );
      expect(find.textContaining('Changing the email address'), findsNothing);
      await typeInto(tester, 'Their name', 'Mum');
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(fakes.contacts.contacts.single.displayName, 'Mum');
      expect(fakes.contacts.contacts.single.email, 'mom@example.com');
      expect(fakes.contacts.invitations, isEmpty, reason: 'no re-invitation');
      expect(snackText(tester), 'Changes saved.');
      expect(find.byType(EditContactScreen), findsNothing);
    });

    testWidgets('changing the email warns, re-invites and resets the status', (
      tester,
    ) async {
      final fakes = _fakes([testContact()]);
      await openApp(tester, fakes: fakes, route: AppRoutes.contactEdit('c1'));
      await typeInto(tester, 'Their email', 'mum@example.com');
      expect(
        find.textContaining(
          'sends a new invitation to the new address. They will need to accept again',
        ),
        findsOneWidget,
      );
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      final saved = fakes.contacts.contacts.single;
      expect(saved.email, 'mum@example.com');
      expect(saved.verificationStatus, VerificationStatus.pending);
      expect(fakes.contacts.invitations['c1'], 1);
      expect(snackText(tester), contains('mum@example.com'));
    });

    testWidgets('typing the same address in other letters is not a change', (
      tester,
    ) async {
      final fakes = _fakes([testContact()]);
      await openApp(tester, fakes: fakes, route: AppRoutes.contactEdit('c1'));
      await typeInto(tester, 'Their email', ' MOM@example.com ');
      expect(find.textContaining('Changing the email address'), findsNothing);
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(fakes.contacts.calls, isNot(contains('update')));
      expect(find.byType(EditContactScreen), findsNothing);
    });

    testWidgets(
      'clearing the phone sends null; changing relationship and label',
      (tester) async {
        final fakes = _fakes([
          testContact(
            phone: '+14155550123',
            relationship: ContactRelationship.other,
            label: 'Neighbour',
          ),
        ]);
        await openApp(tester, fakes: fakes, route: AppRoutes.contactEdit('c1'));
        expect(
          tester
              .widget<TextField>(
                find.widgetWithText(TextField, 'How do you know them?'),
              )
              .controller!
              .text,
          'Neighbour',
        );
        await typeInto(tester, 'Their phone (optional)', '');
        await typeInto(tester, 'How do you know them?', 'Upstairs neighbour');
        await tapText(tester, 'Save changes');
        await tester.pumpAndSettle();
        final saved = fakes.contacts.contacts.single;
        expect(saved.phoneE164, isNull);
        expect(saved.relationshipLabel, 'Upstairs neighbour');
      },
    );

    testWidgets('choosing another relationship removes the description', (
      tester,
    ) async {
      final fakes = _fakes([
        testContact(
          relationship: ContactRelationship.other,
          label: 'Neighbour',
        ),
      ]);
      await openApp(tester, fakes: fakes, route: AppRoutes.contactEdit('c1'));
      await tapText(tester, 'Friend');
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      final saved = fakes.contacts.contacts.single;
      expect(saved.relationship, ContactRelationship.friend);
      expect(saved.relationshipLabel, isNull);
    });

    testWidgets('a duplicate address is explained on the field', (
      tester,
    ) async {
      final fakes = _fakes([
        testContact(),
        testContact(
          id: 'c2',
          name: 'Dad',
          email: 'dad@example.com',
          priority: 2,
        ),
      ]);
      await openApp(tester, fakes: fakes, route: AppRoutes.contactEdit('c2'));
      await typeInto(tester, 'Their email', 'mom@example.com');
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      expect(
        fieldError(tester, 'Their email'),
        "You've already added someone with this email address.",
      );
    });

    testWidgets('an unknown contact is a calm not-found page', (tester) async {
      await openApp(tester, route: AppRoutes.contactEdit('nope'));
      expect(find.textContaining("couldn't find that"), findsOneWidget);
    });
  });

  group('Edit patch', () {
    final contact = testContact(
      phone: '+14155550123',
      relationship: ContactRelationship.other,
      label: 'Neighbour',
    );
    ContactFormValues values({
      String name = 'Mom',
      ContactRelationship relationship = ContactRelationship.other,
      String? label = 'Neighbour',
      String email = 'mom@example.com',
      String? phone = '+14155550123',
    }) => ContactFormValues(
      name: name,
      relationship: relationship,
      label: label,
      email: email,
      phone: phone,
    );

    test('nothing changed means no request', () {
      expect(contactPatchFor(contact, values()), isNull);
    });

    test('each field on its own', () {
      expect(contactPatchFor(contact, values(name: 'Mum'))!.toJson(), {
        'display_name': 'Mum',
      });
      expect(
        contactPatchFor(contact, values(email: 'a@example.com'))!.toJson(),
        {'email': 'a@example.com'},
      );
      expect(contactPatchFor(contact, values(phone: null))!.toJson(), {
        'phone_e164': null,
      });
      expect(
        contactPatchFor(contact, values(phone: '+4915112345678'))!.toJson(),
        {'phone_e164': '+4915112345678'},
      );
      expect(contactPatchFor(contact, values(label: null))!.toJson(), {
        'relationship_label': null,
      });
      expect(contactPatchFor(contact, values(label: 'Pal'))!.toJson(), {
        'relationship_label': 'Pal',
      });
      expect(
        contactPatchFor(
          contact,
          values(relationship: ContactRelationship.friend, label: 'ignored'),
        )!.toJson(),
        {'relationship': 'friend', 'relationship_label': null},
      );
    });

    test('a different relationship without any label sends no label', () {
      final plain = testContact();
      expect(
        contactPatchFor(
          plain,
          values(
            relationship: ContactRelationship.friend,
            label: null,
            phone: null,
          ),
        )!.toJson(),
        {'relationship': 'friend'},
      );
    });
  });
}
