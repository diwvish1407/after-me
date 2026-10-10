import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/contacts/application/contacts_controller.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/onboarding/application/setup_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/test_app.dart';

const _draft = ContactDraft(
  name: 'Mom',
  relationship: ContactRelationship.mother,
  email: 'mom@example.com',
);

ProviderContainer _container(
  TestFakes fakes, {
  AuthStatus status = AuthStatus.signedIn,
}) {
  final container = ProviderContainer.test(
    retry: (retryCount, error) => null,
    overrides: testOverrides(authStatus: status, fakes: fakes),
  );
  container
    ..listen(contactsControllerProvider, (_, _) {})
    ..listen(setupControllerProvider, (_, _) {});
  return container;
}

void main() {
  group('ContactsController', () {
    test('loads the list in the server order and signs out empty', () async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(
        tier: 'premium',
        initial: [
          testContact(id: 'b', name: 'Bro', priority: 2),
          testContact(id: 'a', priority: 1),
        ],
      );
      final container = _container(fakes);
      final list = await container.read(contactsControllerProvider.future);
      expect(list.map((c) => c.id), ['a', 'b']);

      (container.read(authControllerProvider.notifier) as FixedAuthController)
          .set(AuthStatus.signedOut);
      expect(await container.read(contactsControllerProvider.future), isEmpty);
    });

    test('a failed first load is an AppFailure; reload recovers', () async {
      final fakes = TestFakes();
      fakes.contacts.failures['list'] = [const NetworkFailure()];
      final container = _container(fakes);
      await expectLater(
        container.read(contactsControllerProvider.future),
        throwsA(isA<NetworkFailure>()),
      );
      expect(
        container.read(contactsControllerProvider).error,
        isA<NetworkFailure>(),
      );
      final controller = container.read(contactsControllerProvider.notifier);
      expect(await controller.reload(), isNull);
      expect(container.read(contactsControllerProvider).value, isEmpty);
    });

    test(
      'a failed reload keeps the list on screen and returns the failure',
      () async {
        final fakes = TestFakes();
        fakes.contacts = InMemoryContactsRepository(
          tier: 'premium',
          initial: [testContact()],
        );
        final container = _container(fakes);
        await container.read(contactsControllerProvider.future);
        fakes.contacts.failures['list'] = [
          const ServerFailure(statusCode: 503),
        ];
        final failure = await container
            .read(contactsControllerProvider.notifier)
            .reload();
        expect(failure, isA<ServerFailure>());
        expect(container.read(contactsControllerProvider).value, hasLength(1));
      },
    );

    test('create adds the contact and refreshes the entitlements', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      await container.read(contactsControllerProvider.future);
      var before = await container.read(entitlementsProvider.future);
      expect(before.usage.contacts, 0);

      final created = await container
          .read(contactsControllerProvider.notifier)
          .addContact(_draft);
      expect(created.verificationStatus, VerificationStatus.pending);
      expect(container.read(contactsControllerProvider).value, [created]);
      before = await container.read(entitlementsProvider.future);
      expect(before.usage.contacts, 1, reason: 'usage is read again');
      expect(before.contactsAtLimit, isTrue);
    });

    test(
      'the free limit, duplicates and the own email are server failures',
      () async {
        final fakes = TestFakes();
        final container = _container(fakes);
        final controller = container.read(contactsControllerProvider.notifier);
        await container.read(contactsControllerProvider.future);
        await controller.addContact(_draft);

        await expectLater(
          controller.addContact(
            const ContactDraft(
              name: 'Dad',
              relationship: ContactRelationship.father,
              email: 'dad@example.com',
            ),
          ),
          throwsA(
            isA<PlanLimitFailure>()
                .having((f) => f.limit, 'limit', 1)
                .having((f) => f.current, 'current', 1)
                .having((f) => f.resource, 'resource', 'contacts'),
          ),
        );

        fakes.contacts.limit = 5;
        await expectLater(
          controller.addContact(
            const ContactDraft(
              name: 'Mom again',
              relationship: ContactRelationship.mother,
              email: ' MOM@example.com ',
            ),
          ),
          throwsA(isA<ContactDuplicateFailure>()),
        );
        await expectLater(
          controller.addContact(
            const ContactDraft(
              name: 'Me',
              relationship: ContactRelationship.friend,
              email: 'Diwakar@Example.com',
            ),
          ),
          throwsA(isA<CannotBeOwnEmailFailure>()),
        );
        expect(container.read(contactsControllerProvider).value, hasLength(1));
      },
    );

    test(
      'update replaces the contact; a new email resets it to pending',
      () async {
        final fakes = TestFakes();
        fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
        final container = _container(fakes);
        final controller = container.read(contactsControllerProvider.notifier);
        await container.read(contactsControllerProvider.future);

        var updated = await controller.updateContact(
          'c1',
          const ContactPatch(name: 'Mum'),
        );
        expect(updated.displayName, 'Mum');
        expect(updated.verificationStatus, VerificationStatus.verified);

        updated = await controller.updateContact(
          'c1',
          const ContactPatch(email: 'NEW@example.com'),
        );
        expect(updated.email, 'new@example.com');
        expect(updated.verificationStatus, VerificationStatus.pending);
        expect(updated.verifiedAt, isNull);
        expect(fakes.contacts.invitations['c1'], 1);
        expect(
          container.read(contactsControllerProvider).value!.single.email,
          'new@example.com',
        );

        await expectLater(
          controller.updateContact('missing', const ContactPatch(name: 'x')),
          throwsA(isA<NotFoundFailure>()),
        );
      },
    );

    test('remove drops the contact only after the server confirmed', () async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(
        tier: 'premium',
        initial: [
          testContact(),
          testContact(id: 'c2', name: 'Bro', priority: 2),
        ],
      );
      final container = _container(fakes);
      final controller = container.read(contactsControllerProvider.notifier);
      await container.read(contactsControllerProvider.future);
      fakes.contacts.failures['delete'] = [const NetworkFailure()];
      await expectLater(
        controller.removeContact('c1'),
        throwsA(isA<NetworkFailure>()),
      );
      expect(container.read(contactsControllerProvider).value, hasLength(2));
      await controller.removeContact('c1');
      expect(
        container.read(contactsControllerProvider).value!.map((c) => c.id),
        ['c2'],
      );
    });

    test('resend queues the invitation and refreshes the history', () async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(
        initial: [testContact(status: VerificationStatus.pending)],
      );
      final container = _container(fakes);
      final controller = container.read(contactsControllerProvider.notifier);
      await container.read(contactsControllerProvider.future);
      await controller.resendInvitation('c1');
      expect(
        container
            .read(contactsControllerProvider)
            .value!
            .single
            .invitationSendCount,
        2,
      );
    });

    test('resend keeps going when only the re-read fails; refused resends are typed', () async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(
        tier: 'premium',
        initial: [
          testContact(status: VerificationStatus.pending),
          testContact(id: 'c2', name: 'Bro', priority: 2),
        ],
      );
      final container = _container(fakes);
      final controller = container.read(contactsControllerProvider.notifier);
      await container.read(contactsControllerProvider.future);
      fakes.contacts.failures['get'] = [const NetworkFailure()];
      await controller.resendInvitation('c1');
      expect(fakes.contacts.invitations['c1'], 1);

      await expectLater(
        controller.resendInvitation('c2'),
        throwsA(isA<InvalidStateFailure>()),
      );
      fakes.contacts.failures['resendInvitation'] = [
        const RateLimitedFailure(retryAfter: Duration(hours: 2)),
      ];
      await expectLater(
        controller.resendInvitation('c1'),
        throwsA(isA<RateLimitedFailure>()),
      );
    });

    test('non-AppFailure errors become UnknownFailure', () async {
      final fakes = TestFakes()..contacts = _Broken();
      final container = _container(fakes);
      await expectLater(
        container.read(contactsControllerProvider.future),
        throwsA(isA<UnknownFailure>()),
      );
    });
  });

  group('sortContacts', () {
    test('orders by priority, then creation time, then the given order', () {
      final a = testContact(id: 'a', priority: 2);
      final b = testContact(id: 'b')
          .copyWith(createdAt: DateTime.utc(2026, 10, 9));
      final c = testContact(id: 'c');
      final d = testContact(id: 'd').copyWith(createdAt: null);
      final e = testContact(id: 'e').copyWith(createdAt: null);
      expect(sortContacts([a, b, c]).map((x) => x.id), ['c', 'b', 'a']);
      expect(sortContacts([e, d]).map((x) => x.id), ['e', 'd']);
    });
  });

  group('entitlementsProvider', () {
    test('reads the limits; a failure is an AppFailure', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      final e = await container.read(entitlementsProvider.future);
      expect(e.limits.contacts, 1);
      expect(e.tier, 'free');

      fakes.contacts.failures['entitlements'] = [const ServerFailure()];
      container.invalidate(entitlementsProvider);
      await expectLater(
        container.read(entitlementsProvider.future),
        throwsA(isA<ServerFailure>()),
      );
    });

    test('is not read when signed out', () async {
      final container = _container(TestFakes(), status: AuthStatus.signedOut);
      await expectLater(
        container.read(entitlementsProvider.future),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('peopleReadiness', () {
    final accepted = testContact(id: 'a');
    final pending = testContact(
      id: 'p',
      status: VerificationStatus.pending,
      priority: 2,
    );
    final declined = testContact(
      id: 'd',
      status: VerificationStatus.declined,
      priority: 3,
    );

    test('nothing to say without contacts or when everybody accepted', () {
      expect(peopleReadiness(const []), PeopleReadiness.ready);
      expect(peopleReadiness([accepted]), PeopleReadiness.ready);
    });

    test('nobody accepted yet', () {
      expect(peopleReadiness([pending]), PeopleReadiness.nobodyAccepted);
    });

    test('unreachable contacts come first', () {
      expect(peopleReadiness([pending, declined]), PeopleReadiness.unreachable);
      expect(peopleReadiness([declined]), PeopleReadiness.unreachable);
      expect(unreachableCount([pending, declined, accepted]), 1);
    });

    test('with someone accepted only contacts the plan depends on count', () {
      expect(peopleReadiness([accepted, pending]), PeopleReadiness.ready);
      expect(
        peopleReadiness([accepted, pending], planContactIds: {'p'}),
        PeopleReadiness.planWaiting,
      );
      expect(
        peopleReadiness([accepted, pending, declined], planContactIds: {'d'}),
        PeopleReadiness.unreachable,
      );
      expect(
        peopleReadiness([accepted, declined]),
        PeopleReadiness.ready,
        reason: 'not in the plan, and somebody can be told',
      );
    });
  });

  group('SetupController follows the contacts', () {
    test('adding through the setup controller and through the contacts '
        'controller both reach the checklist', () async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(tier: 'premium');
      final container = _container(fakes);
      await container.read(setupControllerProvider.future);
      await container.read(setupControllerProvider.notifier).addContact(_draft);
      expect(container.read(setupControllerProvider).value!.hasContact, isTrue);

      await container
          .read(contactsControllerProvider.notifier)
          .addContact(
            const ContactDraft(
              name: 'Dad',
              relationship: ContactRelationship.father,
              email: 'dad@example.com',
            ),
          );
      expect(
        container.read(setupControllerProvider).value!.contacts,
        hasLength(2),
      );
      await container
          .read(contactsControllerProvider.notifier)
          .removeContact('contact-1');
      await container
          .read(contactsControllerProvider.notifier)
          .removeContact('contact-2');
      expect(
        container.read(setupControllerProvider).value!.hasContact,
        isFalse,
      );
      await container.read(setupControllerProvider.notifier).refresh();
    });
  });
}

class _Broken extends InMemoryContactsRepository {
  @override
  Future<List<TrustedContact>> list() async => throw StateError('boom');
}
