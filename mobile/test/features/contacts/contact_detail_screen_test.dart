import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/features/contacts/application/contacts_controller.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/contacts/presentation/contact_detail_screen.dart';
import 'package:afterme/features/contacts/presentation/contact_labels.dart';
import 'package:afterme/features/contacts/presentation/contact_limit_sheet.dart';
import 'package:afterme/features/contacts/presentation/contact_status_chip.dart';
import 'package:afterme/features/contacts/presentation/edit_contact_screen.dart';
import 'package:afterme/features/contacts/presentation/people_screen.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

TestFakes _fakes(List<TrustedContact> contacts) => TestFakes()
  ..contacts = InMemoryContactsRepository(tier: 'premium', initial: contacts);

Finder _resendButton() =>
    find.widgetWithText(OutlinedButton, 'Resend invitation');

bool _resendEnabled(WidgetTester tester) =>
    tester.widget<OutlinedButton>(_resendButton()).onPressed != null;

Future<ProviderContainer> _openDetail(WidgetTester tester, TestFakes fakes) =>
    openApp(tester, fakes: fakes, route: AppRoutes.contactDetail('c1'));

void main() {
  final l10n = AppLocalizationsEn();

  group('Contact detail: status and explanation', () {
    for (final status in VerificationStatus.values) {
      testWidgets('${status.name}: chip, explanation and next action', (
        tester,
      ) async {
        await _openDetail(tester, _fakes([testContact(status: status)]));
        expect(find.byType(ContactDetailScreen), findsOneWidget);
        expect(find.text(statusLabel(l10n, status)), findsOneWidget);
        expect(find.text(statusExplanation(l10n, status)), findsOneWidget);
        expect(find.text(statusNextAction(l10n, status)), findsOneWidget);
        expect(find.text('Mom'), findsOneWidget);
        expect(find.text('Mother'), findsOneWidget);
        expect(find.text('mom@example.com'), findsOneWidget);
        expect(
          find.text(
            'People must accept your invitation before they can be notified. They can change their mind at any time.',
          ),
          findsOneWidget,
        );
      });
    }

    testWidgets('shows the phone and the "Other" description', (tester) async {
      await _openDetail(
        tester,
        _fakes([
          testContact(
            relationship: ContactRelationship.other,
            label: 'Neighbour upstairs',
            phone: '+14155550123',
          ),
        ]),
      );
      expect(find.text('Neighbour upstairs'), findsOneWidget);
      expect(find.text('+14155550123'), findsOneWidget);
    });

    testWidgets('"Other" without a description says Other', (tester) async {
      await _openDetail(
        tester,
        _fakes([testContact(relationship: ContactRelationship.other)]),
      );
      expect(find.text('Other'), findsOneWidget);
    });

    testWidgets('invitation history: last sent, how often, accepted', (
      tester,
    ) async {
      await _openDetail(tester, _fakes([testContact(sendCount: 3)]));
      expect(find.text('Invitation'), findsOneWidget);
      expect(find.textContaining('Last sent'), findsOneWidget);
      expect(find.text('Sent 3 times'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^Accepted .*Oct 8')), findsOneWidget);
    });

    testWidgets('sent once; and an invitation that has not gone out', (
      tester,
    ) async {
      await _openDetail(
        tester,
        _fakes([testContact(status: VerificationStatus.pending)]),
      );
      expect(find.text('Sent once'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^Accepted .*Oct')), findsNothing);
    });

    testWidgets('an invitation that has not gone out yet says so', (
      tester,
    ) async {
      final contact = testContact(
        status: VerificationStatus.pending,
        sendCount: 0,
      ).copyWith(invitationSentAt: null);
      await _openDetail(tester, _fakes([contact]));
      expect(find.text("The invitation hasn't gone out yet."), findsOneWidget);
      expect(find.textContaining('Last sent'), findsNothing);
    });

    testWidgets('an unknown contact is a calm not-found page', (tester) async {
      await openApp(tester, route: AppRoutes.contactDetail('nope'));
      expect(find.textContaining("couldn't find that"), findsOneWidget);
    });

    testWidgets('a failed load shows Try again', (tester) async {
      final fakes = _fakes([testContact()]);
      fakes.contacts.failures['list'] = [const NetworkFailure()];
      await _openDetail(tester, fakes);
      expect(find.textContaining("You're offline"), findsOneWidget);
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.text('Mom'), findsOneWidget);
    });
  });

  group('Contact detail: Resend invitation', () {
    testWidgets('works while pending and refreshes the history', (
      tester,
    ) async {
      final fakes = _fakes([testContact(status: VerificationStatus.pending)]);
      await _openDetail(tester, fakes);
      expect(_resendEnabled(tester), isTrue);
      await tapText(tester, 'Resend invitation');
      await tester.pumpAndSettle();
      expect(fakes.contacts.invitations['c1'], 1);
      expect(snackText(tester), "We're sending the invitation again.");
      expect(find.text('Sent 2 times'), findsOneWidget);
    });

    testWidgets('works for a bounced address', (tester) async {
      await _openDetail(
        tester,
        _fakes([testContact(status: VerificationStatus.bounced)]),
      );
      expect(_resendEnabled(tester), isTrue);
    });

    for (final (status, reason) in [
      (
        VerificationStatus.verified,
        "They've already accepted, so there's nothing to resend.",
      ),
      (
        VerificationStatus.declined,
        "They declined, so we won't send another invitation.",
      ),
      (
        VerificationStatus.optedOut,
        "They asked not to be contacted, so we won't send anything.",
      ),
    ]) {
      testWidgets('is off for ${status.name}, with the reason', (tester) async {
        final fakes = _fakes([testContact(status: status)]);
        await _openDetail(tester, fakes);
        expect(_resendEnabled(tester), isFalse);
        expect(find.text(reason), findsOneWidget);
        await tester.tap(_resendButton(), warnIfMissed: false);
        await tester.pump();
        expect(fakes.contacts.calls, isNot(contains('resendInvitation')));
      });
    }

    testWidgets('a rate limit shows when to try again and turns the button off '
        'until then', (tester) async {
      final fakes = _fakes([testContact(status: VerificationStatus.pending)]);
      fakes.contacts.failures['resendInvitation'] = [
        const RateLimitedFailure(retryAfter: Duration(hours: 5, minutes: 30)),
      ];
      final container = await _openDetail(tester, fakes);
      await tapText(tester, 'Resend invitation');
      await tester.pumpAndSettle();
      expect(
        find.text(
          "You've sent several invitations recently. Try again in about 6 hours.",
        ),
        findsOneWidget,
      );
      expect(_resendEnabled(tester), isFalse);

      fakes.clock.advance(const Duration(hours: 6));
      await container.read(contactsControllerProvider.notifier).reload();
      await tester.pumpAndSettle();
      expect(_resendEnabled(tester), isTrue);
      expect(find.textContaining('Try again in about'), findsNothing);
    });

    testWidgets('rate limit wording: minutes, days and unknown', (
      tester,
    ) async {
      expect(
        resendWaitReason(l10n, const Duration(seconds: 20)),
        "You've sent several invitations recently. Try again in 1 minute.",
      );
      expect(
        resendWaitReason(l10n, const Duration(minutes: 45)),
        "You've sent several invitations recently. Try again in 45 minutes.",
      );
      expect(
        resendWaitReason(l10n, const Duration(hours: 1)),
        "You've sent several invitations recently. Try again in 60 minutes.",
      );
      expect(
        resendWaitReason(l10n, const Duration(hours: 30)),
        "You've sent several invitations recently. Try again in about 2 days.",
      );
      expect(
        resendWaitReason(l10n, null),
        "You've sent several invitations recently. Try again later.",
      );
      expect(
        resendWaitReason(l10n, Duration.zero),
        "You've sent several invitations recently. Try again later.",
      );
    });

    testWidgets('a rate limit without a time says "later"', (tester) async {
      final fakes = _fakes([testContact(status: VerificationStatus.pending)]);
      fakes.contacts.failures['resendInvitation'] = [
        const RateLimitedFailure(),
      ];
      await _openDetail(tester, fakes);
      await tapText(tester, 'Resend invitation');
      await tester.pumpAndSettle();
      expect(
        find.text("You've sent several invitations recently. Try again later."),
        findsOneWidget,
      );
      expect(_resendEnabled(tester), isFalse);
    });

    testWidgets('if they answered meanwhile the latest status is shown', (
      tester,
    ) async {
      final fakes = _fakes([testContact(status: VerificationStatus.pending)]);
      await _openDetail(tester, fakes);
      fakes.contacts.respond('c1', VerificationStatus.declined);
      await tapText(tester, 'Resend invitation');
      await tester.pumpAndSettle();
      expect(
        find.textContaining("isn't possible for this contact"),
        findsOneWidget,
      );
      expect(find.text('Declined'), findsOneWidget);
      expect(_resendEnabled(tester), isFalse);
    });

    testWidgets('other failures are shown calmly', (tester) async {
      final fakes = _fakes([testContact(status: VerificationStatus.pending)]);
      fakes.contacts.failures['resendInvitation'] = [const NetworkFailure()];
      await _openDetail(tester, fakes);
      await tapText(tester, 'Resend invitation');
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(_resendEnabled(tester), isTrue, reason: 'they can try again');
    });
  });

  group('Contact detail: Edit and Remove', () {
    testWidgets('Edit opens the edit form', (tester) async {
      await _openDetail(tester, _fakes([testContact()]));
      await tapText(tester, 'Edit');
      await tester.pumpAndSettle();
      expect(find.byType(EditContactScreen), findsOneWidget);
    });

    testWidgets('Remove asks first; Cancel keeps the contact', (tester) async {
      final fakes = _fakes([testContact()]);
      await _openDetail(tester, fakes);
      await tapText(tester, 'Remove');
      await tester.pumpAndSettle();
      expect(find.text('Remove Mom?'), findsOneWidget);
      expect(find.text('Mom will no longer be notified.'), findsOneWidget);
      await tapText(tester, 'Cancel');
      await tester.pumpAndSettle();
      expect(fakes.contacts.contacts, hasLength(1));
      expect(find.byType(ContactDetailScreen), findsOneWidget);
    });

    testWidgets('confirming removes the contact and returns to the list', (
      tester,
    ) async {
      final fakes = _fakes([testContact()]);
      await openApp(tester, fakes: fakes);
      await tapText(tester, 'Mom');
      await tester.pumpAndSettle();
      await tapText(tester, 'Remove');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(fakes.contacts.contacts, isEmpty);
      expect(find.byType(PeopleScreen), findsOneWidget);
      expect(find.byType(ContactDetailScreen), findsNothing);
      expect(snackText(tester), 'Mom was removed.');
      expect(
        find.text("Who should know if you can't be reached?"),
        findsOneWidget,
      );
    });

    testWidgets('says when instructions would no longer be received', (
      tester,
    ) async {
      await _openDetail(tester, _fakes([testContact(receivesInstructions: 2)]));
      await tapText(tester, 'Remove');
      await tester.pumpAndSettle();
      expect(
        find.text(
          "Mom will no longer be notified and won't receive 2 instructions.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('a failed removal keeps the contact and says why', (
      tester,
    ) async {
      final fakes = _fakes([testContact()]);
      fakes.contacts.failures['delete'] = [const NetworkFailure()];
      await _openDetail(tester, fakes);
      await tapText(tester, 'Remove');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(fakes.contacts.contacts, hasLength(1));
      expect(find.byType(ContactDetailScreen), findsOneWidget);
    });
  });

  group('Status chip', () {
    testWidgets('is never colour-only: a word, a distinct icon and a label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      for (final status in VerificationStatus.values) {
        await tester.pumpWidget(wrapForTest(ContactStatusChip(status: status)));
        final word = statusLabel(l10n, status);
        expect(find.text(word), findsOneWidget);
        expect(find.byIcon(statusIcon(status)), findsOneWidget);
        expect(find.bySemanticsLabel('Status: $word'), findsOneWidget);
      }
      expect(
        {for (final s in VerificationStatus.values) statusIcon(s)},
        hasLength(VerificationStatus.values.length),
        reason: 'every status has its own shape',
      );
      handle.dispose();
    });
  });

  group('Plan limit sheet', () {
    Future<void> open(
      WidgetTester tester, {
      int? limit,
      bool free = true,
    }) async {
      await tester.pumpWidget(
        wrapForTest(
          Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showContactLimitSheet(context, limit: limit, free: free),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('free plan: one contact, more are Premium, Close only', (
      tester,
    ) async {
      await open(tester);
      expect(
        find.text('More trusted contacts are part of Premium'),
        findsOneWidget,
      );
      expect(
        find.textContaining('The free plan allows 1 trusted contact.'),
        findsOneWidget,
      );
      expect(find.byType(FilledButton), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Close'), findsNothing);
    });

    testWidgets('a limit other than one is worded in the plural', (
      tester,
    ) async {
      await open(tester, limit: 3);
      expect(
        find.textContaining('The free plan allows 3 trusted contacts.'),
        findsOneWidget,
      );
    });

    testWidgets('the top tier gets the plain limit text', (tester) async {
      await open(tester, free: false);
      expect(find.textContaining('(25)'), findsOneWidget);
    });
  });
}
