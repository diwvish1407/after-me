import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/failures/failure_mapper.dart';
import 'package:afterme/core/design_system/error_view.dart';
import 'package:afterme/core/forms/validators.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/instructions/data/dio_instructions_repository.dart';
import 'package:afterme/features/instructions/data/instructions_repository.dart';
import 'package:afterme/features/instructions/presentation/instruction_labels.dart';
import 'package:afterme/features/instructions/presentation/instruction_starters.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/api_wire.dart';
import '../../helpers/fake_http_adapter.dart';

const _recipient = <String, Object?>{
  'contact_id': 'c-1',
  'display_name': 'Mom',
  'release_stage_id': 's-2',
  'stage_position': 2,
};

Map<String, Object?> _summary({
  String id = 'i-1',
  String category = 'home',
  String status = 'active',
  List<Object?> recipients = const [_recipient],
}) => {
  'id': id,
  'category': category,
  'title': 'House emergency',
  'status': status,
  'recipients': recipients,
  'updated_at': '2026-10-08T09:01:20Z',
};

Map<String, Object?> _full({
  String category = 'home',
  String status = 'active',
}) => {
  ..._summary(category: category, status: status),
  'body': 'Where the spare keys are.',
  'created_at': '2026-10-08T09:00:00Z',
};

void main() {
  group('models', () {
    test('a category or status from a newer server is shown as the safe '
        'one', () {
      final summary = InstructionSummary.fromJson(
        _summary(category: 'subscriptions', status: 'archived'),
      );
      expect(summary.category, InstructionCategory.other);
      expect(summary.status, InstructionStatus.inactive);
      expect(summary.isActive, isFalse, reason: 'never claimed to be shared');
    });

    test('every category has its wire id and its words', () {
      final l10n = AppLocalizationsEn();
      expect(InstructionCategory.digitalAccounts.id, 'digital_accounts');
      expect(
        InstructionCategory.tryParse('digital_accounts'),
        InstructionCategory.digitalAccounts,
      );
      expect(InstructionCategory.tryParse('nope'), isNull);
      expect(InstructionCategory.tryParse(null), isNull);
      for (final category in InstructionCategory.values) {
        expect(InstructionCategory.tryParse(category.id), category);
        expect(categoryName(l10n, category), isNotEmpty);
      }
      final info = InstructionCategoryInfo.fromJson({
        'id': 'digital_accounts',
        'sort_order': 10,
      });
      expect(info.category, InstructionCategory.digitalAccounts);
      expect(
        InstructionCategoryInfo.fromJson({'id': 'x', 'sort_order': 1}).category,
        isNull,
      );
    });

    test('a full instruction has the body, and its summary does not', () {
      final full = Instruction.fromJson(_full());
      expect(full.body, 'Where the spare keys are.');
      expect(full.createdAt, DateTime.utc(2026, 10, 8, 9));
      expect(full.summary.id, full.id);
      expect(full.summary.recipients, full.recipients);
      expect(full.isActive, isTrue);
    });

    test('a missing field is rejected, not guessed', () {
      expect(
        () => InstructionSummary.fromJson({'id': 'i'}),
        throwsA(isA<Object>()),
      );
      expect(() => Instruction.fromJson(_summary()), throwsA(isA<Object>()));
    });

    test('titles, texts and names never reach a log through toString', () {
      final full = Instruction.fromJson(_full());
      final printed = [
        '$full',
        '${full.summary}',
        '${full.recipients.single}',
        '${const InstructionDraft(category: InstructionCategory.home, title: 'Secret title', body: 'Secret text')}',
        '${const InstructionPatch(title: 'Secret title')}',
      ].join(' | ');
      for (final secret in [
        'House emergency',
        'Where the spare keys are',
        'Mom',
        'Secret title',
        'Secret text',
      ]) {
        expect(printed, isNot(contains(secret)));
      }
    });
  });

  group('requests', () {
    test('a new instruction sends all of its fields, active by default', () {
      expect(
        const InstructionDraft(
          category: InstructionCategory.digitalAccounts,
          title: 'Accounts',
          body: 'In the manager.',
          recipients: [RecipientDraft(contactId: 'c-1', releaseStageId: 's-2')],
        ).toJson(),
        {
          'category': 'digital_accounts',
          'title': 'Accounts',
          'body': 'In the manager.',
          'status': 'active',
          'recipients': [
            {'contact_id': 'c-1', 'release_stage_id': 's-2'},
          ],
        },
      );
    });

    test('a patch sends only what is set, and an empty one is empty', () {
      expect(const InstructionPatch().isEmpty, isTrue);
      expect(const InstructionPatch(title: 'T').toJson(), {'title': 'T'});
      expect(
        const InstructionPatch(status: InstructionStatus.inactive).toJson(),
        {'status': 'inactive'},
      );
      expect(
        const InstructionPatch(category: InstructionCategory.pets).toJson(),
        {'category': 'pets'},
      );
      // An empty list is a change: it clears the recipients.
      final clear = const InstructionPatch(recipients: <RecipientDraft>[]);
      expect(clear.isEmpty, isFalse);
      expect(clear.toJson(), {'recipients': <Object>[]});
    });

    test('recipients compare by value', () {
      const a = RecipientDraft(contactId: 'c', releaseStageId: 's');
      expect(a, const RecipientDraft(contactId: 'c', releaseStageId: 's'));
      expect(
        a.hashCode,
        const RecipientDraft(contactId: 'c', releaseStageId: 's').hashCode,
      );
      expect(
        a,
        isNot(const RecipientDraft(contactId: 'c', releaseStageId: 't')),
      );
    });
  });

  group('DioInstructionsRepository', () {
    test(
      'lists with the category filter in the query, not in the path',
      () async {
        final wire = await apiWire(
          (_, _) => FakeReply.json(200, {
            'items': [_summary()],
          }),
        );
        final items = await DioInstructionsRepository(dio: wire.dio)
            .list(category: InstructionCategory.digitalAccounts);
        expect(wire.request.path, '/v1/instructions');
        expect(wire.request.uri.queryParameters, {
          'category': 'digital_accounts',
        });
        expect(items.single.id, 'i-1');
      },
    );

    test('reads, creates, patches and deletes by id, url-encoded', () async {
      final wire = await apiWire(
        (r, _) => switch (r.method) {
          'DELETE' => const FakeReply.json(204),
          'POST' => FakeReply.json(201, _full()),
          _ => FakeReply.json(200, _full()),
        },
      );
      final repository = DioInstructionsRepository(dio: wire.dio);
      await repository.get('a/b');
      await repository.update('a/b', const InstructionPatch(title: 'x'));
      await repository.delete('a/b');
      await repository.create(
        const InstructionDraft(
          category: InstructionCategory.home,
          title: 't',
          body: 'b',
        ),
      );
      final paths = [for (final r in wire.adapter.requests) r.path];
      expect(paths, [
        '/v1/instructions/a%2Fb',
        '/v1/instructions/a%2Fb',
        '/v1/instructions/a%2Fb',
        '/v1/instructions',
      ]);
    });

    test('a write is neither keyed nor repeated behind the person\'s '
        'back', () async {
      var posts = 0;
      final wire = await apiWire((r, _) {
        posts++;
        return const FakeReply.networkError();
      });
      await expectLater(
        DioInstructionsRepository(dio: wire.dio).create(
          const InstructionDraft(
            category: InstructionCategory.home,
            title: 't',
            body: 'b',
          ),
        ),
        throwsA(isA<NetworkFailure>()),
      );
      expect(posts, 1);
      expect(wire.request.header('Idempotency-Key'), isNull);
      expect(wire.request.bearer, isNotNull);
    });

    test('no title or text is ever in a URL', () async {
      final wire = await apiWire((_, _) => FakeReply.json(201, _full()));
      await DioInstructionsRepository(dio: wire.dio).create(
        const InstructionDraft(
          category: InstructionCategory.home,
          title: 'Very secret title',
          body: 'Very secret text',
        ),
      );
      expect(wire.request.uri.toString(), isNot(contains('secret')));
    });

    test('answers become the failures the screens react to', () async {
      Future<AppFailure> failure(
        FakeReply reply, {
        InstructionDraft? draft,
      }) async {
        final wire = await apiWire((_, _) => reply);
        try {
          await DioInstructionsRepository(dio: wire.dio).create(
            draft ??
                const InstructionDraft(
                  category: InstructionCategory.home,
                  title: 't',
                  body: 'b',
                ),
          );
        } on AppFailure catch (f) {
          return f;
        }
        fail('expected a failure');
      }

      final limit = await failure(
        FakeReply.problem(
          403,
          'plan_limit_reached',
          extra: {'limit': 3, 'current': 3, 'resource': 'instructions'},
        ),
      );
      expect(limit, isA<PlanLimitFailure>());
      expect((limit as PlanLimitFailure).resource, 'instructions');
      expect(limit.limit, 3);
      expect(limit.current, 3);
      expect(
        failureMessage(AppLocalizationsEn(), limit),
        AppLocalizationsEn().errorPlanLimitInstructions,
      );

      // The password is asked for (SECURITY.md §7): the code the sheet reacts to.
      final reauth = await failure(FakeReply.problem(403, 'reauth_required'));
      expect(reauth, isA<ForbiddenFailure>());
      expect(reauth, isNot(isA<PlanLimitFailure>()));
      expect((reauth as ForbiddenFailure).code, 'reauth_required');
      expect(
        await failure(FakeReply.problem(404, 'not_found')),
        isA<NotFoundFailure>(),
      );
      expect(
        await failure(FakeReply.problem(429, 'rate_limited')),
        isA<RateLimitedFailure>(),
      );
      expect(
        await failure(FakeReply.problem(503, 'service_unavailable')),
        isA<ServerFailure>(),
      );
      final invalid = await failure(
        FakeReply.problem(
          422,
          'validation_failed',
          extra: {
            'errors': [
              {'field': 'body', 'code': 'too_long', 'message': 'x'},
            ],
          },
        ),
      );
      expect(invalid, isA<ValidationFailure>());
      expect((invalid as ValidationFailure).fieldErrors.single.field, 'body');
    });

    test(
      'a body that is not the documented shape is an unknown failure',
      () async {
        for (final body in [
          <String, Object?>{'id': 1},
          <Object?>[],
        ]) {
          final wire = await apiWire((_, _) => FakeReply.json(200, body));
          await expectLater(
            DioInstructionsRepository(dio: wire.dio).get('i-1'),
            throwsA(isA<UnknownFailure>()),
          );
        }
      },
    );
  });

  group('failures and wording', () {
    final l10n = AppLocalizationsEn();

    test('stage_in_use is its own conflict, with the ids', () {
      final failure = mapErrorResponse(
        _response(409, {
          'status': 409,
          'code': 'stage_in_use',
          'instruction_ids': ['i-1', 'i-2'],
        }),
      );
      expect(failure, isA<StageInUseFailure>());
      expect((failure as StageInUseFailure).instructionIds, ['i-1', 'i-2']);
      expect(failure.code, 'stage_in_use');
      expect(failureMessage(l10n, failure), l10n.errorStageInUse);
    });

    test('stage_in_use without ids is still understood', () {
      final failure = mapErrorResponse(
        _response(409, {'status': 409, 'code': 'stage_in_use'}),
      );
      expect((failure as StageInUseFailure).instructionIds, isEmpty);
    });

    test('a limit with no resource keeps the generic wording', () {
      const failure = PlanLimitFailure(limit: 1);
      expect(failureMessage(l10n, failure), l10n.errorPlanLimitReached);
    });

    test('an instruction that is not found has its own sentence', () {
      expect(
        instructionFailureMessage(l10n, const NotFoundFailure()),
        l10n.instructionNotFound,
      );
      // No answer: nothing was confirmed, and the person's text is still on screen.
      expect(
        instructionFailureMessage(l10n, const NetworkFailure()),
        l10n.errorUnconfirmedSave,
      );
      expect(
        instructionFailureMessage(l10n, const ServerFailure(statusCode: 500)),
        l10n.errorUnconfirmedSave,
      );
      // A real answer keeps its own wording.
      expect(
        instructionFailureMessage(l10n, const RateLimitedFailure()),
        l10n.errorRateLimited,
      );
    });
  });

  group('labels', () {
    final l10n = AppLocalizationsEn();

    test('initials are the first letters of the first two words', () {
      expect(initialsOf('Mom'), 'M');
      expect(initialsOf('samantha rao-whitfield'), 'SR');
      expect(initialsOf('  Ann   Lee  Wong '), 'AL');
      expect(initialsOf(''), '?');
    });

    test('recipients are grouped by stage, in order', () {
      const a = InstructionRecipient(
        contactId: 'a',
        displayName: 'Ann',
        releaseStageId: 's2',
        stagePosition: 2,
      );
      const b = InstructionRecipient(
        contactId: 'b',
        displayName: 'Bob',
        releaseStageId: 's3',
        stagePosition: 3,
      );
      const c = InstructionRecipient(
        contactId: 'c',
        displayName: 'Cy',
        releaseStageId: 's2',
        stagePosition: 2,
      );
      final groups = groupByStage([a, b, c]);
      expect(
        [for (final g in groups) g.names],
        [
          ['Ann', 'Cy'],
          ['Bob'],
        ],
      );
      expect(sharingLines(l10n, null, const []), [
        'Not shared with anyone yet',
      ]);
      expect(sharingLines(l10n, null, [a, b, c]), [
        'Ann and Cy: Stage 2',
        'Bob: Stage 3',
      ]);
    });

    test('notes say who has not accepted and who cannot be reached', () {
      const r = InstructionRecipient(
        contactId: 'c2',
        displayName: 'Sam',
        releaseStageId: 's',
        stagePosition: 2,
      );
      const d = InstructionRecipient(
        contactId: 'c3',
        displayName: 'Dad',
        releaseStageId: 's',
        stagePosition: 2,
      );
      const e = InstructionRecipient(
        contactId: 'c9',
        displayName: 'Unknown',
        releaseStageId: 's',
        stagePosition: 2,
      );
      final notes = recipientNotes(
        [r, d, e],
        [
          const TrustedContact(
            id: 'c1',
            displayName: 'Mom',
            relationship: ContactRelationship.mother,
            email: 'm@example.com',
            verificationStatus: VerificationStatus.verified,
          ),
          const TrustedContact(
            id: 'c2',
            displayName: 'Sam',
            relationship: ContactRelationship.friend,
            email: 's@example.com',
            verificationStatus: VerificationStatus.pending,
          ),
          const TrustedContact(
            id: 'c3',
            displayName: 'Dad',
            relationship: ContactRelationship.father,
            email: 'd@example.com',
            verificationStatus: VerificationStatus.bounced,
          ),
        ],
      );
      expect(notes.pending, ['Sam']);
      expect(notes.unreachable, ['Dad']);
      expect(notes.isEmpty, isFalse);
      expect(notes.lines(l10n), [
        "Sam hasn't accepted yet.",
        "Dad can't be reached right now. See People for what to do.",
      ]);
      expect(recipientNotes([e], const []).isEmpty, isTrue);
    });
  });

  group('examples', () {
    final l10n = AppLocalizationsEn();

    test('there are four to six for every category that has any, and six '
        'featured ones', () {
      for (final category in InstructionCategory.values) {
        final starters = InstructionStarter.forCategory(category);
        if (starters.isNotEmpty) {
          expect(starters.length, inInclusiveRange(4, 6), reason: '$category');
        }
      }
      expect(
        InstructionStarter.featured.map((s) => starterText(l10n, s).title),
        [
          'Who to call first',
          'Home and keys',
          'Pets',
          'Work handover',
          'Where my documents are',
          'Insurance',
        ],
      );
    });

    test('they are prompts to complete: never real data, never a password, '
        'never a link', () {
      final titles = <String>{};
      for (final starter in InstructionStarter.values) {
        final text = starterText(l10n, starter);
        expect(text.title.trim(), isNotEmpty);
        expect(text.hint.trim(), isNotEmpty);
        expect(text.body.trim(), isNotEmpty);
        expect(titles.add(text.title), isTrue, reason: 'unique: ${text.title}');
        // Validates as an instruction as it stands.
        expect(Validators.instructionTitle(text.title), isNull);
        expect(Validators.instructionBody(text.body), isNull);
        final all = '${text.title} ${text.hint} ${text.body}';
        expect(all, isNot(matches(RegExp(r'\d{3,}'))), reason: 'no numbers');
        expect(all, isNot(contains('@')));
        expect(all, isNot(contains('http')));
        for (final word in [
          'died',
          'death',
          'dead',
          'deceased',
          'passed away',
        ]) {
          expect(
            all.toLowerCase(),
            isNot(contains(word)),
            reason: starter.name,
          );
        }
      }
    });
  });
}

/// A response for [mapErrorResponse] with a problem body.
Response<Object?> _response(int status, Map<String, Object?> body) =>
    Response<Object?>(
      requestOptions: RequestOptions(path: '/v1/plan'),
      statusCode: status,
      data: body,
    );
