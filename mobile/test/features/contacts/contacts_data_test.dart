import 'dart:convert';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/contacts_wire.dart';
import '../../helpers/fake_http_adapter.dart';
import '../../helpers/in_memory_contacts_repository.dart';

Map<String, Object?> _contactJson({
  String status = 'verified',
  String relationship = 'mother',
  Map<String, Object?> extra = const {},
}) => <String, Object?>{
  'id': 'c1',
  'display_name': 'Mom',
  'relationship': relationship,
  'relationship_label': null,
  'email': 'mom@example.com',
  'phone_e164': null,
  'priority': 1,
  'verification_status': status,
  'verified_at': '2026-10-08T11:00:00Z',
  'is_active': true,
  'invitation_sent_at': '2026-10-08T10:30:00Z',
  'invitation_send_count': 1,
  'notified_at_stages': <int>[],
  'receives_instructions': 0,
  'created_at': '2026-10-08T10:30:00Z',
  'updated_at': '2026-10-08T10:30:00Z',
  ...extra,
};

void main() {
  group('TrustedContact', () {
    test('parses the contact object of the contract', () {
      final contact = TrustedContact.fromJson(_contactJson());
      expect(contact.id, 'c1');
      expect(contact.displayName, 'Mom');
      expect(contact.relationship, ContactRelationship.mother);
      expect(contact.verificationStatus, VerificationStatus.verified);
      expect(contact.verifiedAt, DateTime.utc(2026, 10, 8, 11));
      expect(contact.invitationSentAt, DateTime.utc(2026, 10, 8, 10, 30));
      expect(contact.invitationSendCount, 1);
      expect(contact.notifiedAtStages, isEmpty);
      expect(contact.receivesInstructions, 0);
      expect(contact.isActive, isTrue);
      expect(contact.priority, 1);
      expect(contact.isAccepted, isTrue);
      expect(contact.isUnreachable, isFalse);
      expect(contact.canResendInvitation, isFalse);
    });

    test('every status and relationship value has its wire name', () {
      const statuses = {
        'pending': VerificationStatus.pending,
        'verified': VerificationStatus.verified,
        'declined': VerificationStatus.declined,
        'opted_out': VerificationStatus.optedOut,
        'bounced': VerificationStatus.bounced,
      };
      statuses.forEach((wire, status) {
        expect(
          TrustedContact.fromJson(_contactJson(status: wire))
              .verificationStatus,
          status,
        );
      });
      for (final relationship in ContactRelationship.values) {
        expect(
          TrustedContact.fromJson(_contactJson(relationship: relationship.name))
              .relationship,
          relationship,
        );
      }
      expect(ContactRelationship.values.map((r) => r.name), [
        'mother',
        'father',
        'parent',
        'spouse',
        'partner',
        'sibling',
        'child',
        'relative',
        'friend',
        'neighbor',
        'employer',
        'colleague',
        'other',
      ]);
    });

    test('an unknown status is never read as accepted; an unknown '
        'relationship is "other"', () {
      final contact = TrustedContact.fromJson(
        _contactJson(status: 'something_new', relationship: 'cousin'),
      );
      expect(contact.verificationStatus, VerificationStatus.pending);
      expect(contact.relationship, ContactRelationship.other);
    });

    test('status helpers follow the resend and readiness rules', () {
      TrustedContact with_(VerificationStatus s) => testContact(status: s);
      expect(with_(VerificationStatus.pending).canResendInvitation, isTrue);
      expect(with_(VerificationStatus.bounced).canResendInvitation, isTrue);
      expect(with_(VerificationStatus.declined).canResendInvitation, isFalse);
      expect(with_(VerificationStatus.optedOut).canResendInvitation, isFalse);
      expect(with_(VerificationStatus.verified).canResendInvitation, isFalse);
      expect(with_(VerificationStatus.declined).isUnreachable, isTrue);
      expect(with_(VerificationStatus.optedOut).isUnreachable, isTrue);
      expect(with_(VerificationStatus.bounced).isUnreachable, isTrue);
      expect(with_(VerificationStatus.pending).isUnreachable, isFalse);
    });

    test('missing optional members get safe defaults', () {
      final contact = TrustedContact.fromJson({
        'id': 'x',
        'display_name': 'X',
        'relationship': 'friend',
        'email': 'x@example.com',
        'verification_status': 'pending',
      });
      expect(contact.invitationSendCount, 0);
      expect(contact.invitationSentAt, isNull);
      expect(contact.notifiedAtStages, isEmpty);
      expect(contact.isActive, isTrue);
      expect(contact.phoneE164, isNull);
    });

    test('a malformed contact is rejected and the text form is redacted', () {
      expect(() => TrustedContact.fromJson({'id': 1}), throwsA(isA<Object>()));
      expect(testContact().toString(), isNot(contains('Mom')));
      expect(testContact().toString(), isNot(contains('example.com')));
    });
  });

  group('Entitlements', () {
    test('parses limits and usage', () {
      final e = Entitlements.fromJson({
        'tier': 'free',
        'limits': {
          'contacts': 1,
          'instructions': 3,
          'stages': 2,
          'custom_offsets': false,
        },
        'usage': {'contacts': 1, 'instructions': 0, 'stages': 0},
      });
      expect(e.isFree, isTrue);
      expect(e.limits.contacts, 1);
      expect(e.limits.customOffsets, isFalse);
      expect(e.usage.contacts, 1);
      expect(e.contactsAtLimit, isTrue);
    });

    test('premium has room until 25', () {
      final e = Entitlements.fromJson({
        'tier': 'premium',
        'limits': {
          'contacts': 25,
          'instructions': 200,
          'stages': 10,
          'custom_offsets': true,
        },
        'usage': {'contacts': 3},
      });
      expect(e.isFree, isFalse);
      expect(e.contactsAtLimit, isFalse);
      expect(e.limits.customOffsets, isTrue);
    });
  });

  group('request bodies', () {
    test(
      'a new contact sends the trimmed fields; the label only for other',
      () {
        expect(
          const ContactDraft(
            name: ' Sam ',
            relationship: ContactRelationship.other,
            relationshipLabel: ' Neighbour ',
            email: ' Sam@Example.com ',
            phone: '+14155550123',
          ).toJson(),
          {
            'display_name': 'Sam',
            'relationship': 'other',
            'relationship_label': 'Neighbour',
            'email': 'Sam@Example.com',
            'phone_e164': '+14155550123',
          },
        );
        expect(
          const ContactDraft(
            name: 'Mom',
            relationship: ContactRelationship.mother,
            relationshipLabel: 'ignored',
            email: 'mom@example.com',
            phone: ' ',
          ).toJson(),
          {
            'display_name': 'Mom',
            'relationship': 'mother',
            'email': 'mom@example.com',
          },
        );
      },
    );

    test('a patch sends only what is set; clears send an explicit null', () {
      expect(const ContactPatch().isEmpty, isTrue);
      expect(const ContactPatch(name: ' Sam ').toJson(), {
        'display_name': 'Sam',
      });
      expect(
        const ContactPatch(
          relationship: ContactRelationship.friend,
          clearRelationshipLabel: true,
          email: 'a@example.com',
          clearPhone: true,
          priority: 2,
          isActive: false,
        ).toJson(),
        {
          'relationship': 'friend',
          'relationship_label': null,
          'email': 'a@example.com',
          'phone_e164': null,
          'priority': 2,
          'is_active': false,
        },
      );
      expect(
        const ContactPatch(
          relationshipLabel: ' Pal ',
          phone: '+14155550123',
        ).toJson(),
        {'relationship_label': 'Pal', 'phone_e164': '+14155550123'},
      );
    });
  });

  group('DioContactsRepository', () {
    test('list: GET /v1/contacts, in the order the server sent', () async {
      final wire = await contactsWire(
        always(
          FakeReply.json(200, {
            'items': [
              _contactJson(),
              _contactJson(extra: {'id': 'c2', 'priority': 2}),
            ],
          }),
        ),
      );
      final items = await wire.repository.list();
      expect(items.map((c) => c.id), ['c1', 'c2']);
      expect(wire.request.method, 'GET');
      expect(wire.request.path, '/v1/contacts');
      expect(wire.request.bearer, isNotNull);
      expect(wire.request.header('Idempotency-Key'), isNull);
    });

    test(
      'create: POST /v1/contacts with the draft body; no retry key',
      () async {
        final wire = await contactsWire(
          always(FakeReply.json(201, _contactJson(status: 'pending'))),
        );
        final created = await wire.repository.create(
          const ContactDraft(
            name: 'Mom',
            relationship: ContactRelationship.mother,
            email: 'mom@example.com',
          ),
        );
        expect(created.verificationStatus, VerificationStatus.pending);
        expect(wire.request.method, 'POST');
        expect(wire.request.path, '/v1/contacts');
        expect(wire.body, {
          'display_name': 'Mom',
          'relationship': 'mother',
          'email': 'mom@example.com',
        });
        expect(wire.request.header('Idempotency-Key'), isNull);
      },
    );

    test('get, update, delete and resend use the contact path', () async {
      var wire = await contactsWire(
        always(FakeReply.json(200, _contactJson())),
      );
      await wire.repository.get('c 1/x');
      expect(wire.request.path, '/v1/contacts/c%201%2Fx');

      wire = await contactsWire(always(FakeReply.json(200, _contactJson())));
      await wire.repository.update('c1', const ContactPatch(name: 'Mum'));
      expect(wire.request.method, 'PATCH');
      expect(wire.request.path, '/v1/contacts/c1');
      expect(wire.body, {'display_name': 'Mum'});

      wire = await contactsWire(always(const FakeReply.json(204)));
      await wire.repository.delete('c1');
      expect(wire.request.method, 'DELETE');
      expect(wire.request.path, '/v1/contacts/c1');

      wire = await contactsWire(
        always(const FakeReply.json(202, {'status': 'queued'})),
      );
      await wire.repository.resendInvitation('c1');
      expect(wire.request.method, 'POST');
      expect(wire.request.path, '/v1/contacts/c1/invitation');
    });

    test('entitlements: GET /v1/me/entitlements', () async {
      final wire = await contactsWire(
        always(
          const FakeReply.json(200, {
            'tier': 'free',
            'limits': {
              'contacts': 1,
              'instructions': 3,
              'stages': 2,
              'custom_offsets': false,
            },
            'usage': {'contacts': 0, 'instructions': 0, 'stages': 0},
          }),
        ),
      );
      final e = await wire.repository.entitlements();
      expect(e.limits.contacts, 1);
      expect(wire.request.path, '/v1/me/entitlements');
    });

    test('reads are retried after a network blip; writes never are', () async {
      var reads = 0;
      var wire = await contactsWire((request, index) {
        reads++;
        return reads == 1
            ? const FakeReply.networkError()
            : const FakeReply.json(200, {'items': <Object>[]});
      });
      expect(await wire.repository.list(), isEmpty);
      expect(wire.adapter.requests, hasLength(2));

      wire = await contactsWire(always(const FakeReply.networkError()));
      await expectLater(
        wire.repository.create(
          const ContactDraft(
            name: 'Mom',
            relationship: ContactRelationship.mother,
            email: 'mom@example.com',
          ),
        ),
        throwsA(isA<NetworkFailure>()),
      );
      expect(
        wire.adapter.requests,
        hasLength(1),
        reason: 'a write is not repeated',
      );
    });

    group('failures become typed AppFailure cases', () {
      Future<AppFailure> failure(FakeReply reply) async {
        final wire = await contactsWire(always(reply));
        try {
          await wire.repository.create(
            const ContactDraft(
              name: 'Mom',
              relationship: ContactRelationship.mother,
              email: 'mom@example.com',
            ),
          );
        } on AppFailure catch (f) {
          return f;
        }
        fail('expected a failure');
      }

      test(
        '403 plan_limit_reached carries limit, current and resource',
        () async {
          final f = await failure(
            FakeReply.problem(
              403,
              'plan_limit_reached',
              extra: {'limit': 1, 'current': 1, 'resource': 'contacts'},
            ),
          );
          expect(f, isA<PlanLimitFailure>());
          expect(f, isA<ForbiddenFailure>());
          f as PlanLimitFailure;
          expect(f.limit, 1);
          expect(f.current, 1);
          expect(f.resource, 'contacts');
          expect(f.code, 'plan_limit_reached');
        },
      );

      test('403 reauth_required on a removal or a change keeps its code and '
          'is not repeated', () async {
        for (final call in <Future<Object?> Function(ContactsWire)>[
          (w) => w.repository.delete('c-1'),
          (w) =>
              w.repository.update('c-1', const ContactPatch(email: 'a@b.co')),
          (w) =>
              w.repository.update('c-1', const ContactPatch(isActive: false)),
        ]) {
          final wire = await contactsWire(
            always(FakeReply.problem(403, 'reauth_required')),
          );
          await expectLater(
            call(wire),
            throwsA(
              isA<ForbiddenFailure>()
                  .having((f) => f.code, 'code', 'reauth_required')
                  .having((f) => f is PlanLimitFailure, 'plan', false),
            ),
          );
          expect(wire.adapter.requests, hasLength(1), reason: 'not repeated');
        }
      });

      test('a plain 403 stays a ForbiddenFailure', () async {
        expect(
          await failure(FakeReply.problem(403, 'forbidden')),
          isA<ForbiddenFailure>().having(
            (f) => f is PlanLimitFailure,
            'plan',
            false,
          ),
        );
      });

      test('409 contact_duplicate and invalid_state', () async {
        expect(
          await failure(FakeReply.problem(409, 'contact_duplicate')),
          isA<ContactDuplicateFailure>(),
        );
        expect(
          await failure(FakeReply.problem(409, 'invalid_state')),
          isA<InvalidStateFailure>(),
        );
        expect(
          await failure(FakeReply.problem(409, 'something_else')),
          isA<ConflictFailure>()
              .having((f) => f is InvalidStateFailure, 'invalid', false)
              .having((f) => f is ContactDuplicateFailure, 'dup', false),
        );
      });

      test(
        '422 cannot_be_own_email, and validation errors with fields',
        () async {
          expect(
            await failure(FakeReply.problem(422, 'cannot_be_own_email')),
            isA<CannotBeOwnEmailFailure>(),
          );
          final f = await failure(
            FakeReply.problem(
              422,
              'validation_failed',
              extra: {
                'errors': [
                  {'field': 'email', 'code': 'invalid_email'},
                ],
              },
            ),
          );
          expect(f, isA<ValidationFailure>());
          expect((f as ValidationFailure).fieldErrors.single.field, 'email');
        },
      );

      test('429 keeps Retry-After', () async {
        final f = await failure(
          FakeReply.problem(
            429,
            'rate_limited',
            headers: {'Retry-After': '3600'},
          ),
        );
        expect(f, isA<RateLimitedFailure>());
        expect((f as RateLimitedFailure).retryAfter, const Duration(hours: 1));
      });

      test('404, 401, 5xx and a malformed success body', () async {
        expect(
          await failure(FakeReply.problem(404, 'not_found')),
          isA<NotFoundFailure>(),
        );
        expect(
          await failure(FakeReply.problem(500, 'internal_error')),
          isA<ServerFailure>(),
        );
        expect(
          await failure(const FakeReply.json(201, {'id': 5})),
          isA<UnknownFailure>(),
        );
        expect(
          await failure(const FakeReply.raw(201, '[]', 'application/json')),
          isA<UnknownFailure>(),
        );
      });

      test('failures never carry the request body', () async {
        final f = await failure(FakeReply.problem(409, 'contact_duplicate'));
        expect(f.toString(), isNot(contains('mom@example.com')));
        expect(jsonEncode(f.problem?.toJson()), isNot(contains('mom@')));
      });
    });
  });
}
