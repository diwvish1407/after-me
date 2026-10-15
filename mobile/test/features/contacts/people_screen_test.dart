import 'dart:async';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/design_system/design_system.dart';
import 'package:afterme/features/contacts/application/contacts_controller.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/contacts/presentation/add_contact_screen.dart';
import 'package:afterme/features/contacts/presentation/contact_detail_screen.dart';
import 'package:afterme/features/contacts/presentation/people_screen.dart';
import 'package:afterme/features/onboarding/application/setup_controller.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/no_purchase.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

TestFakes _fakes(
  List<TrustedContact> contacts, {
  String tier = 'premium',
  int? limit,
}) => TestFakes()
  ..contacts = InMemoryContactsRepository(
    tier: tier,
    limit: limit,
    initial: contacts,
  );

void main() {
  group('People: states', () {
    testWidgets('empty: the question, the explanation and Add contact', (
      tester,
    ) async {
      await openApp(tester);
      expect(find.byType(PeopleScreen), findsOneWidget);
      expect(
        find.text("Who should know if you can't be reached?"),
        findsOneWidget,
      );
      expect(
        find.textContaining('nothing is ever sent to them'),
        findsOneWidget,
      );
      await tapText(tester, 'Add contact');
      await tester.pumpAndSettle();
      expect(find.byType(AddContactScreen), findsOneWidget);
    });

    testWidgets('loading shows a progress indicator', (tester) async {
      final gate = Completer<void>();
      final fakes = TestFakes()..contacts.listGate = gate.future;
      await openApp(tester, fakes: fakes, settle: false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('an error is calm and Try again recovers', (tester) async {
      final fakes = TestFakes();
      fakes.contacts.failures['list'] = [const NetworkFailure()];
      await openApp(tester, fakes: fakes);
      expect(find.textContaining("You're offline"), findsOneWidget);
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsNothing);
      expect(
        find.text("Who should know if you can't be reached?"),
        findsOneWidget,
      );
    });

    testWidgets('rows show name, relationship, chip and explanation in the '
        "server's order", (tester) async {
      final fakes = _fakes([
        testContact(),
        testContact(
          id: 'c2',
          name: 'Sam',
          relationship: ContactRelationship.other,
          label: 'Neighbour upstairs',
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
        testContact(
          id: 'c4',
          name: 'Ann',
          relationship: ContactRelationship.colleague,
          email: 'ann@example.com',
          priority: 4,
          status: VerificationStatus.optedOut,
        ),
        testContact(
          id: 'c5',
          name: 'Joe',
          relationship: ContactRelationship.neighbor,
          email: 'joe@example.com',
          priority: 5,
          status: VerificationStatus.bounced,
        ),
      ]);
      await openApp(tester, fakes: fakes);
      for (final text in [
        'Mom',
        'Mother',
        'Accepted',
        "They accepted and can be told if you can't be reached.",
        'Sam',
        'Neighbour upstairs',
        'Pending',
        'Waiting for them to accept.',
        'Declined',
        "They said no, so we won't contact them.",
        'Opted out',
        'They asked us not to contact them.',
        'Email could not be delivered',
        "We couldn't deliver the invitation to this address.",
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      final names = ['Mom', 'Sam', 'Dad', 'Ann', 'Joe'];
      final tops = [
        for (final name in names) tester.getTopLeft(find.text(name)).dy,
      ];
      expect([...tops]..sort(), tops, reason: 'same order as the server');
    });

    testWidgets('a row reads as one button with its status', (tester) async {
      final handle = tester.ensureSemantics();
      await openApp(tester, fakes: _fakes([testContact()]));
      expect(
        find.bySemanticsLabel(
          "Mom, Mother. Accepted. They accepted and can be told if you can't be reached.",
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('tapping a row opens the contact', (tester) async {
      await openApp(tester, fakes: _fakes([testContact()]));
      await tapText(tester, 'Mom');
      await tester.pumpAndSettle();
      expect(find.byType(ContactDetailScreen), findsOneWidget);
    });

    testWidgets('pull to refresh reads the list again; a failure keeps it', (
      tester,
    ) async {
      final fakes = _fakes([testContact()]);
      await openApp(tester, fakes: fakes);
      expect(fakes.contacts.calls.where((c) => c == 'list'), hasLength(1));
      fakes.contacts.respond('c1', VerificationStatus.declined);
      await tester.fling(
        find.byType(Scrollable).first,
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(fakes.contacts.calls.where((c) => c == 'list'), hasLength(2));
      expect(find.text('Declined'), findsOneWidget);

      fakes.contacts.failures['list'] = [const NetworkFailure()];
      await tester.fling(
        find.byType(Scrollable).first,
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(snackText(tester), contains("You're offline"));
      expect(find.text('Mom'), findsOneWidget, reason: 'the list stays');
    });

    testWidgets('pull to refresh also works when the list is short or empty', (
      tester,
    ) async {
      final fakes = TestFakes();
      await openApp(tester, fakes: fakes);
      await fakes.contacts.create(
        const ContactDraft(
          name: 'Mom',
          relationship: ContactRelationship.mother,
          email: 'mom@example.com',
        ),
      );
      await tester.fling(
        find.byType(Scrollable).first,
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.text('Mom'), findsOneWidget);
    });
  });

  group('People: readiness hints (USER_FLOWS §4)', () {
    testWidgets('nobody has accepted yet', (tester) async {
      await openApp(
        tester,
        fakes: _fakes([testContact(status: VerificationStatus.pending)]),
      );
      expect(
        find.text(
          'Nobody has accepted yet. Until someone does, no one can be told if you miss a check-in.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the plan depends on someone who has not accepted', (
      tester,
    ) async {
      final fakes = _fakes([
        testContact(),
        testContact(
          id: 'c2',
          name: 'Sam',
          priority: 2,
          status: VerificationStatus.pending,
        ),
      ]);
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
      );
      await container
          .read(setupControllerProvider.notifier)
          .savePlan(
            const PlanDraft(
              graceMinutes: 180,
              stages: [
                PlanStageDraft(offsetMinutes: 180, contactIds: ['c1', 'c2']),
              ],
            ),
          );
      container.read(routerProvider).go(AppRoutes.people);
      await tester.pumpAndSettle();
      expect(
        find.textContaining("haven't accepted yet. They can only be told"),
        findsOneWidget,
      );
    });

    testWidgets('somebody cannot be reached', (tester) async {
      await openApp(
        tester,
        fakes: _fakes([
          testContact(status: VerificationStatus.declined),
          testContact(
            id: 'c2',
            name: 'Sam',
            priority: 2,
            status: VerificationStatus.bounced,
          ),
        ]),
      );
      expect(
        find.textContaining("2 trusted contacts can't be reached right now."),
        findsOneWidget,
      );
    });

    testWidgets('one unreachable contact is worded in the singular', (
      tester,
    ) async {
      await openApp(
        tester,
        fakes: _fakes([testContact(status: VerificationStatus.optedOut)]),
      );
      expect(
        find.textContaining("One trusted contact can't be reached right now."),
        findsOneWidget,
      );
    });

    testWidgets('no hint when somebody accepted and the plan is fine', (
      tester,
    ) async {
      await openApp(tester, fakes: _fakes([testContact()]));
      expect(find.textContaining('Nobody has accepted'), findsNothing);
      expect(find.textContaining("can't be reached right now"), findsNothing);
    });
  });

  group('People: adding and the free-plan limit', () {
    testWidgets('Add opens the form while there is room', (tester) async {
      await openApp(tester, fakes: _fakes([testContact()]));
      await tapText(tester, 'Add contact');
      await tester.pumpAndSettle();
      expect(find.byType(AddContactScreen), findsOneWidget);
    });

    testWidgets('the app bar action does the same', (tester) async {
      await openApp(tester, fakes: _fakes([testContact()]));
      await tester.tap(find.byTooltip('Add contact'));
      await tester.pumpAndSettle();
      expect(find.byType(AddContactScreen), findsOneWidget);
    });

    testWidgets(
      'at the free limit Add explains the limit and offers Close only',
      (tester) async {
        final fakes = _fakes([testContact()], tier: 'free');
        await openApp(tester, fakes: fakes);
        await tapText(tester, 'Add contact');
        await tester.pumpAndSettle();
        expect(find.byType(AddContactScreen), findsNothing);
        expect(
          find.text("More trusted contacts aren't available yet"),
          findsOneWidget,
        );
        expect(
          find.textContaining('The free plan includes 1 trusted contact.'),
          findsOneWidget,
        );
        expect(find.text('Close'), findsOneWidget);
        expect(find.textContaining('Buy'), findsNothing);
        expect(find.textContaining('Subscribe'), findsNothing);
        expectNoPurchaseOffer(
          within: find.byType(BottomSheet),
          allowedButtons: {'Close'},
        );
        await tapText(tester, 'Close');
        await tester.pumpAndSettle();
        expect(find.text('Close'), findsNothing);
        expect(find.byType(PeopleScreen), findsOneWidget);
      },
    );

    testWidgets('the same sheet from the empty state when the limit is 0', (
      tester,
    ) async {
      final fakes = TestFakes()..contacts.limit = 0;
      await openApp(tester, fakes: fakes);
      await tapText(tester, 'Add contact');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The free plan includes 0 trusted contacts.'),
        findsOneWidget,
      );
    });

    testWidgets('unknown limits: Add still opens, the server decides', (
      tester,
    ) async {
      final fakes = _fakes([testContact()], tier: 'free');
      fakes.contacts.failures['entitlements'] = [const NetworkFailure()];
      await openApp(tester, fakes: fakes);
      await tapText(tester, 'Add contact');
      await tester.pumpAndSettle();
      expect(find.byType(AddContactScreen), findsOneWidget);
    });

    testWidgets('the top tier at its limit gets the plain explanation', (
      tester,
    ) async {
      final fakes = _fakes([testContact()], limit: 1);
      await openApp(tester, fakes: fakes);
      await tapText(tester, 'Add contact');
      await tester.pumpAndSettle();
      expect(
        find.textContaining("You've reached the most trusted contacts"),
        findsOneWidget,
      );
      expect(find.textContaining('Premium'), findsNothing);
    });

    testWidgets('loading the list again after adding refreshes the limit', (
      tester,
    ) async {
      final fakes = _fakes([], tier: 'free');
      final container = await openApp(tester, fakes: fakes);
      await container
          .read(contactsControllerProvider.notifier)
          .addContact(
            const ContactDraft(
              name: 'Mom',
              relationship: ContactRelationship.mother,
              email: 'mom@example.com',
            ),
          );
      await tester.pumpAndSettle();
      await tapText(tester, 'Add contact');
      await tester.pumpAndSettle();
      expect(
        find.text("More trusted contacts aren't available yet"),
        findsOneWidget,
      );
    });
  });

  group('People: a contact answers out of band', () {
    // The invitation is answered on the web, where this app cannot see it. Home's counts
    // said "1 of 1 accepted" while People kept saying "Pending".
    Finder tab(String label) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );

    List<TrustedContact> many() => [
      for (var i = 1; i <= 8; i++)
        testContact(
          id: 'c$i',
          name: 'Contact $i',
          email: 'c$i@example.com',
          priority: i,
          status: VerificationStatus.pending,
        ),
    ];

    testWidgets('the list is read again when the tab comes back: no spinner, '
        'the scroll position stays, the new status shows', (tester) async {
      final fakes = _fakes(many());
      await openApp(tester, fakes: fakes, size: const Size(390, 600));
      expect(find.text('Pending'), findsWidgets);

      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      double offset() => tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels;
      final before = offset();
      expect(before, greaterThan(0));

      // Away to Home, and the contact accepts meanwhile.
      await tester.tap(tab('Home'));
      await tester.pumpAndSettle();
      fakes.contacts.respond('c1', VerificationStatus.verified);
      fakes.contacts.respond('c2', VerificationStatus.verified);

      // Back, with the answer held: the old list is what is on screen meanwhile.
      final gate = Completer<void>();
      fakes.contacts.listGate = gate.future;
      final calls = fakes.contacts.calls.where((c) => c == 'list').length;
      await tester.tap(tab('People'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LoadingView), findsNothing);
      expect(
        fakes.contacts.calls.where((c) => c == 'list').length,
        calls + 1,
        reason: 'read again, once',
      );

      gate.complete();
      await tester.pumpAndSettle();
      expect(offset(), before, reason: 'it did not jump');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PeopleScreen)),
      );
      expect(
        container
            .read(contactsControllerProvider)
            .value!
            .where((c) => c.isAccepted)
            .map((c) => c.id),
        ['c1', 'c2'],
      );
    });

    testWidgets('the first build does not read twice', (tester) async {
      final fakes = _fakes(many());
      await openApp(tester, fakes: fakes);
      expect(fakes.contacts.calls.where((c) => c == 'list'), hasLength(1));
    });

    testWidgets('a status that changed while the tab was hidden is what the '
        'chip says when it is back', (tester) async {
      final fakes = _fakes([testContact(status: VerificationStatus.pending)]);
      await openApp(tester, fakes: fakes);
      expect(find.text('Pending'), findsWidgets);
      expect(find.text('Accepted'), findsNothing);

      await tester.tap(tab('Home'));
      await tester.pumpAndSettle();
      fakes.contacts.respond('c1', VerificationStatus.verified);
      await tester.tap(tab('People'));
      await tester.pumpAndSettle();

      expect(find.text('Accepted'), findsWidgets);
      expect(find.text('Pending'), findsNothing);
    });
  });
}
