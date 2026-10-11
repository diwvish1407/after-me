import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/design_system/error_view.dart';
import 'package:afterme/features/plan/data/dio_plan_repository.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:afterme/features/plan/presentation/plan_labels.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/api_wire.dart';
import '../../helpers/contacts_wire.dart' show always;
import '../../helpers/fake_http_adapter.dart';

Map<String, Object?> _rules({bool custom = false, int maxStages = 2}) => {
  'grace_min': 60,
  'grace_max': 4320,
  'stage_gap_min': 30,
  'offset_max': 43200,
  'release_offset_min': 1440,
  'max_stages': maxStages,
  'custom_offsets': custom,
  'presets': [180, 360, 720, 1440, 2880, 4320],
};

Map<String, Object?> _plan({
  int version = 7,
  int grace = 180,
  List<Map<String, Object?>>? stages,
  Map<String, Object?>? rules,
}) => {
  'id': 'plan-id',
  'version': version,
  'grace_minutes': grace,
  'stages':
      stages ??
      [
        {
          'id': 's1',
          'position': 1,
          'offset_minutes': 180,
          'notify_contact_ids': ['c-mom'],
          'release_count': 0,
        },
        {
          'id': 's2',
          'position': 2,
          'offset_minutes': 1440,
          'notify_contact_ids': ['c-bro', 'c-mom'],
          'release_count': 2,
        },
      ],
  'rules': rules ?? _rules(),
};

const _draft = PlanDraft(
  graceMinutes: 180,
  stages: [
    PlanStageDraft(offsetMinutes: 180, contactIds: ['c-mom']),
  ],
);

void main() {
  group('DioPlanRepository', () {
    Future<(ApiWire, DioPlanRepository)> repo(FakeHandler handler) async {
      final wire = await apiWire(handler);
      return (wire, DioPlanRepository(dio: wire.dio));
    }

    test('GET reads the plan, its stages, the rules and the ETag', () async {
      final (wire, plan) = await repo(
        always(FakeReply.json(200, _plan(), const {'ETag': '"plan-7"'})),
      );
      final snapshot = await plan.get();
      expect(wire.request.method, 'GET');
      expect(wire.request.path, '/v1/plan');
      expect(wire.request.bearer, 'access-1');
      expect(snapshot.id, 'plan-id');
      expect(snapshot.version, 7);
      expect(snapshot.graceMinutes, 180);
      expect(snapshot.etag, '"plan-7"');
      expect(snapshot.ifMatch, '"plan-7"');
      expect(snapshot.stages, hasLength(2));
      final second = snapshot.stages.last;
      expect(second.id, 's2');
      expect(second.position, 2);
      expect(second.offsetMinutes, 1440);
      expect(second.contactIds, ['c-bro', 'c-mom']);
      expect(second.releaseCount, 2);
      expect(snapshot.contactIds, {'c-mom', 'c-bro'});
      expect(snapshot.rules.graceMin, 60);
      expect(snapshot.rules.graceMax, 4320);
      expect(snapshot.rules.stageGapMin, 30);
      expect(snapshot.rules.offsetMax, 43200);
      expect(snapshot.rules.releaseOffsetMin, 1440);
      expect(snapshot.rules.maxStages, 2);
      expect(snapshot.rules.customOffsets, isFalse);
      expect(snapshot.rules.presets, [180, 360, 720, 1440, 2880, 4320]);
    });

    test('a new account has no stages', () async {
      final (_, plan) = await repo(
        always(FakeReply.json(200, _plan(version: 1, stages: const []))),
      );
      final snapshot = await plan.get();
      expect(snapshot.stages, isEmpty);
      expect(snapshot.graceMinutes, 180);
      expect(snapshot.contactIds, isEmpty);
    });

    test(
      'If-Match is built from the version, not from the ETag header',
      () async {
        // An intermediary may weaken the header; the strong comparison would then be
        // answered with 412 forever.
        final (_, plan) = await repo(
          always(
            FakeReply.json(200, _plan(version: 4), const {
              'ETag': 'W/"plan-9"',
            }),
          ),
        );
        final snapshot = await plan.get();
        expect(snapshot.etag, 'W/"plan-9"');
        expect(snapshot.ifMatch, '"plan-4"');
      },
    );

    test('without an ETag header the version names it', () async {
      final (_, plan) = await repo(
        always(FakeReply.json(200, _plan(version: 3))),
      );
      final snapshot = await plan.get();
      expect(snapshot.etag, isNull);
      expect(snapshot.ifMatch, '"plan-3"');
    });

    test('fields this version does not know are ignored', () async {
      final body = _plan()
        ..['colour'] = 'blue'
        ..['rules'] = {..._rules(), 'future_rule': 12};
      (body['stages']! as List<Map<String, Object?>>).first['mood'] = 'calm';
      final (_, plan) = await repo(always(FakeReply.json(200, body)));
      final snapshot = await plan.get();
      expect(snapshot.stages.first.contactIds, ['c-mom']);
      expect(snapshot.rules.maxStages, 2);
    });

    test('toDraft keeps the stage ids and offsets', () async {
      final (_, plan) = await repo(always(FakeReply.json(200, _plan())));
      final draft = (await plan.get()).toDraft();
      expect(draft.graceMinutes, 180);
      expect(draft.stages, const [
        PlanStageDraft(id: 's1', offsetMinutes: 180, contactIds: ['c-mom']),
        PlanStageDraft(
          id: 's2',
          offsetMinutes: 1440,
          contactIds: ['c-bro', 'c-mom'],
        ),
      ]);
    });

    test('PUT sends If-Match and exactly the documented body', () async {
      final (wire, plan) = await repo(
        always(
          FakeReply.json(200, _plan(version: 8, stages: const []), const {
            'ETag': '"plan-8"',
          }),
        ),
      );
      final saved = await plan.save(_draft, ifMatch: '"plan-7"');
      expect(wire.request.method, 'PUT');
      expect(wire.request.path, '/v1/plan');
      expect(wire.request.header('If-Match'), '"plan-7"');
      expect(wire.request.bearer, 'access-1');
      expect(wire.body, {
        'grace_minutes': 180,
        'stages': [
          {
            'id': null,
            'offset_minutes': 180,
            'notify_contact_ids': ['c-mom'],
          },
        ],
      });
      expect(saved.version, 8);
      expect(saved.etag, '"plan-8"');
    });

    test('an existing stage keeps its id in the body', () async {
      final (wire, plan) = await repo(always(FakeReply.json(200, _plan())));
      await plan.save(
        const PlanDraft(
          graceMinutes: 360,
          stages: [
            PlanStageDraft(
              id: 's1',
              offsetMinutes: 360,
              contactIds: ['c-mom', 'c-bro'],
            ),
          ],
        ),
        ifMatch: '"plan-7"',
      );
      expect((wire.body['stages']! as List).single, {
        'id': 's1',
        'offset_minutes': 360,
        'notify_contact_ids': ['c-mom', 'c-bro'],
      });
    });

    test('a failed save is not repeated behind the person\'s back', () async {
      final (wire, plan) = await repo(always(const FakeReply.networkError()));
      await expectLater(
        plan.save(_draft, ifMatch: '"plan-7"'),
        throwsA(isA<NetworkFailure>()),
      );
      expect(wire.adapter.requests, hasLength(1));
    });

    test('a read is repeated after a transport failure', () async {
      var calls = 0;
      final (wire, plan) = await repo((request, index) {
        calls++;
        return calls == 1
            ? const FakeReply.networkError()
            : FakeReply.json(200, _plan());
      });
      expect((await plan.get()).version, 7);
      expect(wire.adapter.requests, hasLength(2));
    });

    group('failures', () {
      Future<AppFailure> failure(FakeReply reply, {bool save = true}) async {
        final (_, plan) = await repo(always(reply));
        try {
          if (save) {
            await plan.save(_draft, ifMatch: '"plan-7"');
          } else {
            await plan.get();
          }
        } on AppFailure catch (f) {
          return f;
        }
        fail('expected a failure');
      }

      test('428 precondition_required', () async {
        final f = await failure(
          FakeReply.problem(428, 'precondition_required'),
        );
        expect(f, isA<ConflictFailure>());
        expect((f as ConflictFailure).code, 'precondition_required');
      });

      test('412 precondition_failed', () async {
        final f = await failure(FakeReply.problem(412, 'precondition_failed'));
        expect(f, isA<ConflictFailure>());
        expect((f as ConflictFailure).code, 'precondition_failed');
      });

      test('409 incident_open', () async {
        final f = await failure(FakeReply.problem(409, 'incident_open'));
        expect(f, isA<ConflictFailure>());
        expect((f as ConflictFailure).code, 'incident_open');
      });

      test('404 for a contact that is not the person\'s', () async {
        final f = await failure(FakeReply.problem(404, 'not_found'));
        expect(f, isA<NotFoundFailure>());
      });

      test('403 reauth_required keeps the code the password sheet reacts '
          'to, and is not a stage limit', () async {
        final f = await failure(FakeReply.problem(403, 'reauth_required'));
        expect(f, isA<ForbiddenFailure>());
        expect(f, isNot(isA<PlanLimitFailure>()));
        expect((f as ForbiddenFailure).code, 'reauth_required');
      });

      test('403 plan_limit_reached names the stages and the limit', () async {
        final f = await failure(
          FakeReply.problem(
            403,
            'plan_limit_reached',
            extra: {'resource': 'stages', 'limit': 2, 'current': 3},
          ),
        );
        expect(f, isA<PlanLimitFailure>());
        final limit = f as PlanLimitFailure;
        expect(limit.resource, 'stages');
        expect(limit.limit, 2);
        expect(limit.current, 3);
      });

      test('422 validation_failed carries the field errors', () async {
        final f = await failure(
          FakeReply.problem(
            422,
            'validation_failed',
            extra: {
              'errors': [
                {
                  'field': 'stages[0].offset_minutes',
                  'code': 'must_equal_grace',
                  'message': 'The first stage runs when the grace period ends.',
                },
              ],
            },
          ),
        );
        expect(f, isA<ValidationFailure>());
        final errors = (f as ValidationFailure).fieldErrors;
        expect(errors.single.field, 'stages[0].offset_minutes');
        expect(errors.single.code, 'must_equal_grace');
      });

      test('500 and an unreadable success body', () async {
        expect(
          await failure(FakeReply.problem(500, 'internal_error')),
          isA<ServerFailure>(),
        );
        expect(
          await failure(
            const FakeReply.json(200, <String, Object?>{'id': 'x'}),
            save: false,
          ),
          isA<UnknownFailure>(),
          reason: 'a plan without a version or rules is not a plan',
        );
        expect(
          await failure(const FakeReply.json(200, <Object>[]), save: false),
          isA<UnknownFailure>(),
        );
      });
    });
  });

  group('plan wording', () {
    final l10n = AppLocalizationsEn();

    ValidationFailure invalid(List<(String, String)> fields) =>
        ValidationFailure(
          code: 'validation_failed',
          fieldErrors: [
            for (final (field, code) in fields)
              ApiFieldError(field: field, code: code, message: 'server text'),
          ],
        );

    test('a grace period the tier does not allow is said on its own', () {
      for (final code in ['out_of_range', 'not_a_preset']) {
        expect(
          planFailureMessage(l10n, invalid([('grace_minutes', code)])),
          l10n.planErrorGrace,
        );
      }
    });

    test('a stage time that does not fit is said on its own', () {
      for (final code in [
        'must_equal_grace',
        'too_close',
        'too_large',
        'not_a_preset',
        'release_too_early',
      ]) {
        expect(
          planFailureMessage(
            l10n,
            invalid([('stages[1].offset_minutes', code)]),
          ),
          l10n.planErrorStageTime,
        );
      }
    });

    test('the first field this version names wins', () {
      expect(
        planFailureMessage(
          l10n,
          invalid([
            ('stages[0].notify_contact_ids', 'duplicate'),
            ('stages[0].offset_minutes', 'must_equal_grace'),
            ('grace_minutes', 'out_of_range'),
          ]),
        ),
        l10n.planErrorStageTime,
      );
    });

    test('a field it does not name falls back to the generic message', () {
      expect(
        planFailureMessage(
          l10n,
          invalid([('stages[0].notify_contact_ids', 'duplicate')]),
        ),
        l10n.errorValidation,
      );
      expect(planFieldErrorText(l10n, const []), isNull);
    });

    test('a stale plan, a contact that is gone and the stage limit', () {
      expect(
        planFailureMessage(
          l10n,
          const ConflictFailure(code: 'precondition_failed'),
        ),
        l10n.planStale,
      );
      expect(
        planFailureMessage(
          l10n,
          const ConflictFailure(code: 'precondition_required'),
        ),
        l10n.planStale,
      );
      expect(
        planFailureMessage(l10n, const NotFoundFailure()),
        l10n.planContactGone,
      );
      expect(
        failureMessage(
          l10n,
          const PlanLimitFailure(resource: 'stages', limit: 2, current: 3),
        ),
        l10n.errorPlanLimitStages,
      );
      expect(
        failureMessage(
          l10n,
          const PlanLimitFailure(resource: 'contacts', limit: 1, current: 1),
        ),
        l10n.errorPlanLimitReached,
      );
    });

    test('everything else is the generic wording', () {
      expect(
        planFailureMessage(l10n, const ConflictFailure(code: 'incident_open')),
        l10n.errorIncidentOpen,
      );
      // No answer is "not confirmed" (and the plan on screen is kept).
      expect(
        planFailureMessage(l10n, const NetworkFailure()),
        l10n.errorUnconfirmedSave,
      );
      expect(
        planFailureMessage(l10n, const ServerFailure(statusCode: 503)),
        l10n.errorUnconfirmedSave,
      );
    });
  });
}
