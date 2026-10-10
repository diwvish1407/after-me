@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/design_system/error_view.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/contacts/data/dio_contacts_repository.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/contacts_wire.dart';
import '../helpers/fake_http_adapter.dart';

/// The backend writes example requests and responses for every Phase 3 endpoint to
/// docs/contracts/phase3 (generated and compared by a backend test). Those files are the
/// source of truth for what is on the wire. The app must send bodies that agree with the
/// golden requests and parse the golden responses, problem+json included.
///
/// The files are in the repository root; `flutter test` runs from `mobile/`.
final Directory _dir = Directory('../docs/contracts/phase3');

Map<String, dynamic> _json(String file) =>
    jsonDecode(File('${_dir.path}/$file').readAsStringSync())
        as Map<String, dynamic>;

/// `/v1/contacts/{contact_id}` -> `/v1/contacts/{}` so that parameter names don't matter.
String _template(String path) => path.replaceAll(RegExp(r'\{[^}]*\}'), '{}');

const _contactId = '6f1c2a52-8d3b-4a6e-9a43-0c1d5e7b9a10';

String _concrete(String path) =>
    path.replaceAll(RegExp(r'\{[^}]*\}'), _contactId);

void main() {
  late Map<String, dynamic> index;
  late List<Map<String, dynamic>> endpoints;
  late List<Map<String, dynamic>> problems;

  setUpAll(() {
    expect(
      File('${_dir.path}/index.json').existsSync(),
      isTrue,
      reason: 'docs/contracts/phase3 is written by the backend tests',
    );
    index = _json('index.json');
    endpoints = (index['endpoints'] as List).cast<Map<String, dynamic>>();
    problems = ((index['problems'] ?? const <Object?>[]) as List)
        .cast<Map<String, dynamic>>();
  });

  /// Every example the contract has for a route (several for create and entitlements).
  List<Map<String, dynamic>> examples(String method, String template) {
    final found = endpoints
        .where(
          (e) =>
              e['method'] == method &&
              _template(e['path'] as String) == template,
        )
        .toList();
    expect(found, isNotEmpty, reason: 'no $method $template in the index');
    return found;
  }

  Map<String, dynamic> endpoint(String method, String template) =>
      examples(method, template).first;

  Future<ContactsWire> wireFor(Map<String, dynamic> e) {
    final response = e['response'] as String?;
    return contactsWire(
      always(
        FakeReply.json(
          e['status'] as int,
          response == null ? null : _json(response),
        ),
      ),
    );
  }

  void expectRoute(ContactsWire wire, Map<String, dynamic> e, {String? path}) {
    expect(wire.request.method, e['method']);
    expect(wire.request.path, path ?? _concrete(e['path'] as String));
  }

  test('the index names the contract and covers every Phase 3 endpoint', () {
    expect(index['contract'], 'afterme-phase3');
    expect(index['base_path'], '/v1');
    final routes = {
      for (final e in endpoints)
        '${e['method']} ${_template(e['path'] as String)}',
    };
    expect(
      routes,
      containsAll(<String>[
        'GET /v1/contacts',
        'POST /v1/contacts',
        'GET /v1/contacts/{}',
        'PATCH /v1/contacts/{}',
        'DELETE /v1/contacts/{}',
        'POST /v1/contacts/{}/invitation',
        'GET /v1/me/entitlements',
      ]),
    );
  });

  test('every file in the index exists and every file is in the index', () {
    final referenced = <String>{'index.json'};
    for (final e in [...endpoints, ...problems]) {
      for (final key in ['request', 'response']) {
        final file = e[key] as String?;
        if (file != null) {
          referenced.add(file);
          expect(File('${_dir.path}/$file').existsSync(), isTrue, reason: file);
        }
      }
    }
    final onDisk = _dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.json'))
        .toSet();
    expect(onDisk.difference(referenced), isEmpty, reason: 'unlisted files');
  });

  group('requests agree with the golden files', () {
    test('POST /v1/contacts: every example', () async {
      for (final e in examples('POST', '/v1/contacts')) {
        final golden = _json(e['request'] as String);
        final wire = await wireFor(e);
        final created = await wire.repository.create(
          ContactDraft(
            name: golden['display_name'] as String,
            relationship: ContactRelationship.values.byName(
              golden['relationship'] as String,
            ),
            relationshipLabel: golden['relationship_label'] as String?,
            email: golden['email'] as String,
            phone: golden['phone_e164'] as String?,
          ),
        );
        expectRoute(wire, e);
        // `priority` is optional and the app lets the server number the contact.
        expect(
          wire.body,
          {...golden}..remove('priority'),
          reason: '${e['name']}: the app sends exactly the documented fields',
        );
        expect(created.id, _json(e['response'] as String)['id']);
      }
    });

    test(
      'PATCH /v1/contacts/{id}: every example sends only its fields',
      () async {
        for (final e in examples('PATCH', '/v1/contacts/{}')) {
          final golden = _json(e['request'] as String);
          final wire = await wireFor(e);
          final updated = await wire.repository.update(
            _contactId,
            ContactPatch(
              name: golden['display_name'] as String?,
              relationship: golden['relationship'] == null
                  ? null
                  : ContactRelationship.values.byName(
                      golden['relationship'] as String,
                    ),
              relationshipLabel: golden['relationship_label'] as String?,
              clearRelationshipLabel:
                  golden.containsKey('relationship_label') &&
                  golden['relationship_label'] == null,
              email: golden['email'] as String?,
              phone: golden['phone_e164'] as String?,
              clearPhone:
                  golden.containsKey('phone_e164') &&
                  golden['phone_e164'] == null,
              priority: golden['priority'] as int?,
              isActive: golden['is_active'] as bool?,
            ),
          );
          expectRoute(wire, e);
          expect(wire.body, golden, reason: '${e['name']}');
          expect(updated.id, _json(e['response'] as String)['id']);
        }
      },
    );

    test('GET list, GET one, DELETE, resend and entitlements use the '
        'documented routes', () async {
      var e = endpoint('GET', '/v1/contacts');
      var wire = await wireFor(e);
      await wire.repository.list();
      expectRoute(wire, e);
      expect(wire.request.data, isNull);

      e = endpoint('GET', '/v1/contacts/{}');
      wire = await wireFor(e);
      await wire.repository.get(_contactId);
      expectRoute(wire, e);

      e = endpoint('DELETE', '/v1/contacts/{}');
      wire = await wireFor(e);
      await wire.repository.delete(_contactId);
      expectRoute(wire, e);
      expect(e['status'], 204);

      e = endpoint('POST', '/v1/contacts/{}/invitation');
      wire = await wireFor(e);
      await wire.repository.resendInvitation(_contactId);
      expectRoute(wire, e);
      expect(e['status'], 202);
      expect(_json(e['response'] as String), {'status': 'queued'});
      expect(wire.request.data, isNull);

      e = endpoint('GET', '/v1/me/entitlements');
      wire = await wireFor(e);
      await wire.repository.entitlements();
      expectRoute(wire, e);
    });
  });

  group('responses parse into the models', () {
    void expectContactMatches(
      TrustedContact contact,
      Map<String, dynamic> raw,
    ) {
      expect(contact.id, raw['id']);
      expect(contact.displayName, raw['display_name']);
      expect(contact.relationship.name, raw['relationship']);
      expect(contact.relationshipLabel, raw['relationship_label']);
      expect(contact.email, raw['email']);
      expect(contact.phoneE164, raw['phone_e164']);
      expect(contact.priority, raw['priority']);
      expect(contact.verificationStatus, switch (raw['verification_status']) {
        'pending' => VerificationStatus.pending,
        'verified' => VerificationStatus.verified,
        'declined' => VerificationStatus.declined,
        'opted_out' => VerificationStatus.optedOut,
        'bounced' => VerificationStatus.bounced,
        final other => fail('unknown status $other in the contract'),
      });
      expect(
        contact.verifiedAt,
        raw['verified_at'] == null
            ? null
            : DateTime.parse(raw['verified_at'] as String),
      );
      expect(contact.isActive, raw['is_active']);
      expect(
        contact.invitationSentAt,
        raw['invitation_sent_at'] == null
            ? null
            : DateTime.parse(raw['invitation_sent_at'] as String),
      );
      expect(contact.invitationSendCount, raw['invitation_send_count']);
      expect(contact.notifiedAtStages, raw['notified_at_stages']);
      expect(contact.receivesInstructions, raw['receives_instructions']);
      expect(contact.createdAt, DateTime.parse(raw['created_at'] as String));
      expect(contact.updatedAt, DateTime.parse(raw['updated_at'] as String));
    }

    test('the list, in the order the server sent', () async {
      final e = endpoint('GET', '/v1/contacts');
      final raw = _json(e['response'] as String);
      final items = await (await wireFor(e)).repository.list();
      final rawItems = (raw['items'] as List).cast<Map<String, dynamic>>();
      expect(items, hasLength(rawItems.length));
      expect(items, isNotEmpty);
      for (var i = 0; i < items.length; i++) {
        expectContactMatches(items[i], rawItems[i]);
      }
    });

    test(
      'create, get and update return the contact object (every example)',
      () async {
        for (final (method, template) in [
          ('POST', '/v1/contacts'),
          ('GET', '/v1/contacts/{}'),
          ('PATCH', '/v1/contacts/{}'),
        ]) {
          for (final e in examples(method, template)) {
            final wire = await wireFor(e);
            final raw = _json(e['response'] as String);
            final contact = switch (method) {
              'POST' => await wire.repository.create(
                const ContactDraft(
                  name: 'x',
                  relationship: ContactRelationship.other,
                  email: 'x@example.com',
                ),
              ),
              'GET' => await wire.repository.get(_contactId),
              _ => await wire.repository.update(
                _contactId,
                const ContactPatch(name: 'x'),
              ),
            };
            expectContactMatches(contact, raw);
          }
        }
      },
    );

    test('the examples include pending, accepted and declined contacts', () {
      final statuses = <VerificationStatus>{};
      for (final e in endpoints.where((e) => e['response'] != null)) {
        final raw = _json(e['response'] as String);
        final candidates = raw.containsKey('items')
            ? (raw['items'] as List).cast<Map<String, dynamic>>()
            : [raw];
        for (final candidate in candidates) {
          if (candidate.containsKey('verification_status')) {
            statuses.add(TrustedContact.fromJson(candidate).verificationStatus);
          }
        }
      }
      expect(
        statuses,
        containsAll([
          VerificationStatus.pending,
          VerificationStatus.verified,
          VerificationStatus.declined,
        ]),
      );
    });

    test('GET /v1/me/entitlements: every example', () async {
      for (final e in examples('GET', '/v1/me/entitlements')) {
        final raw = _json(e['response'] as String);
        final result = await (await wireFor(e)).repository.entitlements();
        final limits = raw['limits'] as Map<String, dynamic>;
        final usage = raw['usage'] as Map<String, dynamic>;
        expect(result.tier, raw['tier']);
        expect(result.limits.contacts, limits['contacts']);
        expect(result.limits.instructions, limits['instructions']);
        expect(result.limits.stages, limits['stages']);
        expect(result.limits.customOffsets, limits['custom_offsets']);
        expect(result.usage.contacts, usage['contacts']);
        expect(result.usage.instructions, usage['instructions']);
        expect(result.usage.stages, usage['stages']);
      }
    });
  });

  group('problem+json files', () {
    final l10n = AppLocalizationsEn();

    Future<AppFailure> failureOf(Map<String, dynamic> problem) async {
      final golden = _json(problem['response'] as String);
      final method = problem['method'] as String;
      final template = _template(problem['path'] as String);
      final wire = await contactsWire(
        always(
          FakeReply.raw(
            golden['status'] as int,
            jsonEncode(golden),
            'application/problem+json',
          ),
        ),
      );
      final DioContactsRepository repository = wire.repository;
      try {
        switch ('$method $template') {
          case 'POST /v1/contacts':
            await repository.create(
              const ContactDraft(
                name: 'x',
                relationship: ContactRelationship.other,
                email: 'x@example.com',
              ),
            );
          case 'PATCH /v1/contacts/{}':
            await repository.update(_contactId, const ContactPatch(name: 'x'));
          case 'POST /v1/contacts/{}/invitation':
            await repository.resendInvitation(_contactId);
          case 'GET /v1/contacts':
            await repository.list();
          case 'GET /v1/contacts/{}':
            await repository.get(_contactId);
          case 'DELETE /v1/contacts/{}':
            await repository.delete(_contactId);
          case 'GET /v1/me/entitlements':
            await repository.entitlements();
          default:
            fail('no repository call for $method $template');
        }
      } on AppFailure catch (failure) {
        return failure;
      }
      fail('expected a failure');
    }

    test('every file parses as an ApiProblem with its code and request id', () {
      expect(problems, isNotEmpty);
      for (final problem in problems) {
        final golden = _json(problem['response'] as String);
        final parsed = ApiProblem.tryParse(
          golden,
          httpStatus: golden['status'] as int,
        );
        expect(parsed, isNotNull, reason: '${problem['name']}');
        expect(parsed!.code, golden['code']);
        expect(parsed.requestId, golden['request_id']);
        expect(parsed.status, problem['status']);
      }
    });

    test('the documented problems are covered', () {
      final codes = {
        for (final p in problems) _json(p['response'] as String)['code'],
      };
      expect(
        codes,
        containsAll(<String>[
          'plan_limit_reached',
          'contact_duplicate',
          'cannot_be_own_email',
          'invalid_state',
          'rate_limited',
        ]),
      );
    });

    test('each problem becomes its typed failure with calm copy', () async {
      for (final problem in problems) {
        final golden = _json(problem['response'] as String);
        final failure = await failureOf(problem);
        final code = golden['code'];
        switch (code) {
          case 'plan_limit_reached':
            expect(failure, isA<PlanLimitFailure>());
            failure as PlanLimitFailure;
            expect(failure.limit, golden['limit']);
            expect(failure.current, golden['current']);
            expect(failure.resource, golden['resource']);
            expect(failure.resource, 'contacts');
          case 'contact_duplicate':
            expect(failure, isA<ContactDuplicateFailure>());
            expect(failureMessage(l10n, failure), l10n.errorContactDuplicate);
          case 'cannot_be_own_email':
            expect(failure, isA<CannotBeOwnEmailFailure>());
            expect(failureMessage(l10n, failure), l10n.errorOwnEmail);
          case 'invalid_state':
            expect(failure, isA<InvalidStateFailure>());
            expect(failureMessage(l10n, failure), l10n.errorInvalidState);
          case 'rate_limited':
            expect(failure, isA<RateLimitedFailure>());
            expect(failure.isTransient, isTrue);
          case 'validation_failed':
            expect(failure, isA<ValidationFailure>());
            expect(
              (failure as ValidationFailure).fieldErrors.map((f) => f.field),
              [for (final f in golden['errors'] as List) (f as Map)['field']],
            );
          case 'not_found':
            expect(failure, isA<NotFoundFailure>());
            expect(failureMessage(l10n, failure), l10n.errorNotFound);
          default:
            expect(failure.problem?.code, code, reason: '${problem['name']}');
        }
        expect(failure.requestId, golden['request_id']);
        expect(
          failureMessage(l10n, failure),
          isNot(contains(golden['detail'] as String)),
          reason: 'the server text is never what the person reads',
        );
      }
    });

    test('a 429 keeps Retry-After', () async {
      final problem = problems.firstWhere(
        (p) => _json(p['response'] as String)['code'] == 'rate_limited',
      );
      final golden = _json(problem['response'] as String);
      final wire = await contactsWire(
        always(
          JsonReply(429, golden, const {
            'Retry-After': '7200',
          }, 'application/problem+json'),
        ),
      );
      await expectLater(
        wire.repository.resendInvitation(_contactId),
        throwsA(
          isA<RateLimitedFailure>().having(
            (f) => f.retryAfter,
            'retryAfter',
            const Duration(hours: 2),
          ),
        ),
      );
    });
  });
}
