@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/failures/failure_mapper.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/design_system/error_view.dart';
import 'package:afterme/core/forms/validators.dart';
import 'package:afterme/features/checkin/data/dio_schedule_repository.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/contacts/data/dio_contacts_repository.dart';
import 'package:afterme/features/home/data/models/home_models.dart';
import 'package:afterme/features/incidents/data/incidents_repository.dart';
import 'package:afterme/features/instructions/data/dio_instructions_repository.dart';
import 'package:afterme/features/instructions/data/instructions_repository.dart';
import 'package:afterme/features/instructions/presentation/instruction_labels.dart';
import 'package:afterme/features/plan/data/dio_plan_repository.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:afterme/features/plan/presentation/plan_labels.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/api_wire.dart';
import '../helpers/fake_http_adapter.dart';

/// The backend writes example requests and responses for every Phase 6 endpoint to
/// docs/contracts/phase6 (generated and compared by a backend test). Those files are the
/// source of truth for what is on the wire: the app must send what the golden requests
/// show, read what the golden responses contain, and map every problem file.
///
/// Phase 6's mobile half is the instructions (`GET /v1/instruction-categories`, `GET`,
/// `POST`, `PATCH` and `DELETE /v1/instructions`), the plan's `release_count` and the
/// `stage_in_use` answer of `PUT /v1/plan` (the plan editor that shows it is Phase 7).
///
/// Until the backend writes the folder, the whole file is skipped with a message, so
/// the suite stays green; once it exists, nothing here needs changing.
///
/// The files are in the repository root; `flutter test` runs from `mobile/`.
final Directory _dir = Directory('../docs/contracts/phase6');

bool get _present => File('${_dir.path}/index.json').existsSync();

/// Phase 6 added `releases` to the incident object of Phase 5, so the incident goldens
/// of that folder are read here too.
final Directory _incidentDir = Directory('../docs/contracts/phase5');

Map<String, dynamic> _incidentGolden(String file) =>
    jsonDecode(File('${_incidentDir.path}/$file').readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic> _json(String file) =>
    jsonDecode(File('${_dir.path}/$file').readAsStringSync())
        as Map<String, dynamic>;

String _template(String path) => path.replaceAll(RegExp(r'\{[^}]*\}'), '{}');

Map<String, String> _headers(Map<String, dynamic> entry, String key) => {
  for (final e in ((entry[key] ?? const <String, Object?>{}) as Map).entries)
    '${e.key}': '${e.value}',
};

/// The keys a header-bearing request may carry in the index, and nothing else.
const _knownHeaders = {'If-Match', 'ETag', 'Idempotency-Key'};

void main() {
  if (!_present) {
    test(
      'phase 6 golden files',
      () {},
      skip:
          'docs/contracts/phase6/index.json does not exist yet: the backend '
          'half of Phase 6 writes it (make contracts). This test parses it as '
          'soon as it appears.',
    );
    return;
  }

  late Map<String, dynamic> index;
  late List<Map<String, dynamic>> endpoints;
  late List<Map<String, dynamic>> problems;

  setUpAll(() {
    index = _json('index.json');
    endpoints = (index['endpoints'] as List).cast<Map<String, dynamic>>();
    problems = ((index['problems'] ?? const <Object?>[]) as List)
        .cast<Map<String, dynamic>>();
  });

  String route(Map<String, dynamic> e) =>
      '${e['method']} ${_template(e['path'] as String)}';

  Map<String, dynamic> endpoint(String name) =>
      endpoints.singleWhere((e) => e['name'] == name);

  Map<String, dynamic> problem(String name) =>
      problems.singleWhere((p) => p['name'] == name);

  FakeReply replyFor(Map<String, dynamic> e) {
    final response = e['response'] as String?;
    return FakeReply.json(
      e['status'] as int,
      response == null ? null : _json(response),
      _headers(e, 'response_headers'),
    );
  }

  /// The problem's answer on the wire: `application/problem+json`.
  FakeReply problemReply(Map<String, dynamic> p) {
    final golden = _json(p['response'] as String);
    return FakeReply.raw(
      golden['status'] as int,
      jsonEncode(golden),
      'application/problem+json',
    );
  }

  DateTime? instant(Object? value) =>
      value == null ? null : DateTime.parse(value as String);

  /// The `{id}` of the golden path: whichever the golden response has.
  String idOf(Map<String, dynamic> e) =>
      _json(endpoint('instruction_get')['response'] as String)['id'] as String;

  test('the index names the contract and covers every Phase 6 endpoint', () {
    expect(index['contract'], 'afterme-phase6');
    expect(index['base_path'], '/v1');
    expect(
      {for (final e in endpoints) route(e)},
      containsAll(<String>[
        'GET /v1/instruction-categories',
        'GET /v1/instructions',
        'GET /v1/instructions?category=home',
        'POST /v1/instructions',
        'GET /v1/instructions/{}',
        'PATCH /v1/instructions/{}',
        'DELETE /v1/instructions/{}',
        'GET /v1/plan',
        'POST /v1/checkin/activate',
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

  test('every file is a JSON object', () {
    for (final file in _dir.listSync().whereType<File>()) {
      if (file.path.endsWith('.json')) {
        expect(
          jsonDecode(file.readAsStringSync()),
          isA<Map<String, dynamic>>(),
          reason: file.path,
        );
      }
    }
  });

  test('only headers the app knows are recorded', () {
    for (final e in [...endpoints, ...problems]) {
      for (final key in ['request_headers', 'response_headers']) {
        expect(
          _headers(e, key).keys.toSet().difference(_knownHeaders),
          isEmpty,
          reason: '${e['name']} $key',
        );
      }
    }
  });

  group('categories', () {
    test('GET reads every id, in the server\'s order, and the app words '
        'each of them', () async {
      final e = endpoint('categories_list');
      final wire = await apiWire((_, _) => replyFor(e));
      final categories = await DioInstructionsRepository(dio: wire.dio)
          .categories();
      final raw = _json(e['response'] as String);
      expect(wire.request.method, 'GET');
      expect(wire.request.path, e['path']);
      final items = (raw['items'] as List).cast<Map<String, dynamic>>();
      expect(
        [for (final c in categories) c.id],
        [for (final i in items) i['id']],
      );
      expect(
        [for (final c in categories) c.sortOrder],
        [for (final i in items) i['sort_order']],
      );
      final l10n = AppLocalizationsEn();
      for (final info in categories) {
        expect(info.category, isNotNull, reason: '${info.id} has a label');
        expect(categoryName(l10n, info.category!), isNotEmpty);
      }
      expect(
        {for (final c in categories) categoryName(l10n, c.category!)},
        hasLength(categories.length),
        reason: 'every id has its own words',
      );
      expect(InstructionCategory.values.map((c) => c.id).toSet(), {
        for (final c in categories) c.id,
      }, reason: 'the app knows exactly the ids of the contract');
    });
  });

  group('list', () {
    test(
      'GET reads the summaries: no body, recipients with their stage',
      () async {
        final e = endpoint('instructions_list');
        final wire = await apiWire((_, _) => replyFor(e));
        final items = await DioInstructionsRepository(dio: wire.dio)
            .list(category: InstructionCategory.home);
        final raw = (_json(e['response'] as String)['items'] as List)
            .cast<Map<String, dynamic>>();
        expect(wire.request.method, 'GET');
        expect(wire.request.path, '/v1/instructions');
        expect(wire.request.uri.queryParameters, {'category': 'home'});
        expect(items, hasLength(raw.length));
        final item = items.single;
        expect(
          raw.single.containsKey('body'),
          isFalse,
          reason: 'never in a list',
        );
        expect(item.id, raw.single['id']);
        expect(item.title, raw.single['title']);
        expect(item.category.id, raw.single['category']);
        expect(item.status.name, raw.single['status']);
        expect(item.updatedAt, instant(raw.single['updated_at']));
        final recipient = item.recipients.single;
        final rawRecipient =
            (raw.single['recipients'] as List).single as Map<String, dynamic>;
        expect(recipient.contactId, rawRecipient['contact_id']);
        expect(recipient.displayName, rawRecipient['display_name']);
        expect(recipient.releaseStageId, rawRecipient['release_stage_id']);
        expect(recipient.stagePosition, rawRecipient['stage_position']);
      },
    );

    test('an empty list is an empty list', () async {
      final e = endpoint('instructions_list_empty');
      final wire = await apiWire((_, _) => replyFor(e));
      final items = await DioInstructionsRepository(dio: wire.dio).list();
      expect(items, isEmpty);
      expect(wire.request.uri.queryParameters, isEmpty);
    });
  });

  group('create, read, change, delete', () {
    test('POST sends the golden body exactly and reads the whole '
        'instruction', () async {
      final e = endpoint('instruction_create');
      final golden = _json(e['request'] as String);
      final wire = await apiWire((_, _) => replyFor(e));
      final recipient =
          (golden['recipients'] as List).single as Map<String, dynamic>;
      final created = await DioInstructionsRepository(dio: wire.dio).create(
        InstructionDraft(
          category: InstructionCategory.tryParse(golden['category'] as String)!,
          title: golden['title'] as String,
          body: golden['body'] as String,
          recipients: [
            RecipientDraft(
              contactId: recipient['contact_id'] as String,
              releaseStageId: recipient['release_stage_id'] as String,
            ),
          ],
        ),
      );
      expect(wire.request.method, 'POST');
      expect(wire.request.path, e['path']);
      expect(wire.body, golden, reason: 'exactly the documented fields');

      final raw = _json(e['response'] as String);
      expect(created.id, raw['id']);
      expect(created.title, golden['title']);
      expect(
        created.body,
        golden['body'],
        reason: 'the body is on the full one',
      );
      expect(created.category, InstructionCategory.home);
      expect(created.status, InstructionStatus.active);
      expect(created.createdAt, instant(raw['created_at']));
      expect(created.updatedAt, instant(raw['updated_at']));
      expect(created.recipients.single.displayName, 'Dad');
      expect(e['status'], 201);
    });

    test('the summary of a full instruction is the list item', () async {
      final full = Instruction.fromJson(
        _json(endpoint('instruction_get')['response'] as String),
      );
      final item = InstructionSummary.fromJson(
        ((_json(endpoint('instructions_list')['response'] as String)['items']
                    as List)
                .single
            as Map<String, dynamic>),
      );
      expect(full.summary, item);
      expect(full.summary.toString(), isNot(contains(full.title)));
      expect(full.toString(), isNot(contains(full.body)));
    });

    test('GET reads one instruction by id', () async {
      final e = endpoint('instruction_get');
      final wire = await apiWire((_, _) => replyFor(e));
      final id = idOf(e);
      final got = await DioInstructionsRepository(dio: wire.dio).get(id);
      expect(wire.request.method, 'GET');
      expect(wire.request.path, '/v1/instructions/$id');
      final raw = _json(e['response'] as String);
      expect(got.title, raw['title']);
      expect(got.body, raw['body']);
      expect(got.recipients.single.stagePosition, 2);
    });

    test(
      'PATCH sends only what changed, and the golden answer is read',
      () async {
        final e = endpoint('instruction_patch');
        final golden = _json(e['request'] as String);
        final wire = await apiWire((_, _) => replyFor(e));
        final id = idOf(e);
        final updated = await DioInstructionsRepository(dio: wire.dio).update(
          id,
          InstructionPatch(
            title: golden['title'] as String?,
            status: golden['status'] == 'inactive'
                ? InstructionStatus.inactive
                : InstructionStatus.active,
          ),
        );
        expect(wire.request.method, 'PATCH');
        expect(wire.request.path, '/v1/instructions/$id');
        expect(wire.body, golden);
        expect(updated.status, InstructionStatus.inactive);
        expect(updated.title, golden['title']);
      },
    );

    test('switching on is the one-field patch of the contract', () async {
      final e = endpoint('instruction_activate');
      final golden = _json(e['request'] as String);
      final wire = await apiWire((_, _) => replyFor(e));
      final updated = await DioInstructionsRepository(dio: wire.dio).update(
        idOf(e),
        const InstructionPatch(status: InstructionStatus.active),
      );
      expect(wire.body, golden);
      expect(updated.status, InstructionStatus.active);
      expect(updated.isActive, isTrue);
      expect(updated.summary.isActive, isTrue);
    });

    test('DELETE answers 204 with no body', () async {
      final e = endpoint('instruction_delete');
      final wire = await apiWire((_, _) => replyFor(e));
      final id = idOf(e);
      await DioInstructionsRepository(dio: wire.dio).delete(id);
      expect(wire.request.method, 'DELETE');
      expect(wire.request.path, '/v1/instructions/$id');
      expect(wire.request.data, isNull);
      expect(e['status'], 204);
    });
  });

  group('plan release counts', () {
    Future<Plan> load(String name) async {
      final e = endpoint(name);
      final wire = await apiWire((_, _) => replyFor(e));
      final plan = await DioPlanRepository(dio: wire.dio).get();
      expect(wire.request.path, '/v1/plan');
      expect(plan.etag, _headers(e, 'response_headers')['ETag']);
      return plan;
    }

    test('a stage counts the active instructions released at it', () async {
      final before = await load('plan_with_release_count');
      final after = await load('plan_with_release_count_active');
      expect([for (final s in before.stages) s.releaseCount], [0, 0]);
      expect([for (final s in after.stages) s.releaseCount], [0, 1]);
    });

    test('the stage an instruction names is a stage of the plan that is '
        'late enough', () async {
      final plan = await load('plan_with_release_count_active');
      final recipient = Instruction.fromJson(
        _json(endpoint('instruction_get')['response'] as String),
      ).recipients.single;
      final stage = plan.stages.singleWhere(
        (s) => s.id == recipient.releaseStageId,
      );
      expect(stage.position, recipient.stagePosition);
      expect(
        stage.offsetMinutes,
        greaterThanOrEqualTo(plan.rules.releaseOffsetMin),
      );
      expect(plan.rules.releaseOffsetMin, 1440);
      expect(stage.releaseCount, 1);
    });
  });

  group('activation', () {
    test('POST is bodiless and returns the schedule with its ETag', () async {
      final e = endpoint('schedule_activate');
      final wire = await apiWire((_, _) => replyFor(e));
      final snapshot = await DioScheduleRepository(dio: wire.dio).activate();
      final raw = _json(e['response'] as String);
      expect(wire.request.method, 'POST');
      expect(wire.request.path, '/v1/checkin/activate');
      expect(snapshot.status, CheckInStatus.active);
      expect(snapshot.nextDueAt, instant(raw['next_due_at']));
      expect(snapshot.version, raw['version']);
      expect(snapshot.etag, _headers(e, 'response_headers')['ETag']);
    });
  });

  group('problem+json files', () {
    final l10n = AppLocalizationsEn();

    /// The failure the app makes of [p]'s answer, through the real API client and the
    /// repository that owns the request.
    Future<AppFailure> failureOf(Map<String, dynamic> p) async {
      final wire = await apiWire((_, _) => problemReply(p));
      final instructions = DioInstructionsRepository(dio: wire.dio);
      final contactId = Instruction.fromJson(
        _json(endpoint('instruction_get')['response'] as String),
      ).recipients.first.contactId;
      try {
        switch (route(p)) {
          case 'POST /v1/instructions':
            final body = _json(p['request'] as String);
            await instructions.create(
              InstructionDraft(
                category: InstructionCategory.tryParse(
                  body['category'] as String,
                )!,
                title: body['title'] as String,
                body: body['body'] as String,
              ),
            );
          case 'GET /v1/instructions':
            await instructions.list();
          case 'GET /v1/instructions/{}':
            await instructions.get('9e7a1f3c-0000-4000-8000-000000000000');
          case 'PUT /v1/plan':
            await DioPlanRepository(dio: wire.dio).save(
              const PlanDraft(graceMinutes: 180, stages: []),
              ifMatch: _headers(p, 'request_headers')['If-Match']!,
            );
          case 'DELETE /v1/instructions/{}':
            await instructions.delete('9e7a1f3c-0000-4000-8000-000000000000');
          case 'DELETE /v1/contacts/{}':
            await DioContactsRepository(dio: wire.dio).delete(contactId);
          case 'PATCH /v1/contacts/{}':
            await DioContactsRepository(dio: wire.dio)
                .update(contactId, const ContactPatch(isActive: false));
          default:
            fail('no call for ${route(p)}');
        }
      } on DioException catch (error) {
        return mapDioException(error);
      } on AppFailure catch (failure) {
        return failure;
      }
      fail('expected a failure for ${p['name']}');
    }

    test('every file parses as an ApiProblem with its code and request id', () {
      expect(problems, isNotEmpty);
      for (final p in problems) {
        final golden = _json(p['response'] as String);
        final parsed = ApiProblem.tryParse(
          golden,
          httpStatus: golden['status'] as int,
        );
        expect(parsed, isNotNull, reason: '${p['name']}');
        expect(parsed!.code, golden['code']);
        expect(parsed.requestId, golden['request_id']);
        expect(parsed.status, p['status']);
      }
    });

    test('the documented problems are covered', () {
      expect(
        {for (final p in problems) _json(p['response'] as String)['code']},
        {'validation_failed', 'not_found', 'stage_in_use', 'reauth_required'},
      );
    });

    test('a release stage that is too early is a field error on that '
        'recipient, said in the app\'s own words', () async {
      final p = problem('problem_release_stage_too_early');
      final golden = _json(p['response'] as String);
      final failure = await failureOf(p);
      expect(failure, isA<ValidationFailure>());
      final errors = (failure as ValidationFailure).fieldErrors;
      expect(errors.single.field, 'recipients[0].release_stage_id');
      expect(errors.single.code, 'release_stage_too_early');
      expect(
        errors.single.message,
        ((golden['errors'] as List).single as Map<String, dynamic>)['message'],
        reason: 'kept in the parsed problem, never shown',
      );
      expect(failureMessage(l10n, failure), l10n.errorValidation);
    });

    test('a missing title is the field error the form shows', () async {
      final p = problem('problem_validation_failed');
      final failure = await failureOf(p);
      final errors = (failure as ValidationFailure).fieldErrors;
      expect(errors.single.field, 'title');
      expect(errors.single.code, 'required');
      expect(issueForField(errors, 'title'), FieldIssue.required);
    });

    test('404 is the same for a missing and for somebody else\'s '
        'instruction', () async {
      final failure = await failureOf(problem('problem_not_found'));
      expect(failure, isA<NotFoundFailure>());
      expect(
        instructionFailureMessage(l10n, failure),
        l10n.instructionNotFound,
      );
      expect(failureMessage(l10n, failure), l10n.errorNotFound);
    });

    test('stage_in_use names the instructions and is a conflict of its '
        'own', () async {
      final p = problem('problem_stage_in_use');
      final golden = _json(p['response'] as String);
      final failure = await failureOf(p);
      expect(failure, isA<StageInUseFailure>());
      expect(failure, isA<ConflictFailure>());
      expect(
        (failure as StageInUseFailure).instructionIds,
        (golden['instruction_ids'] as List).cast<String>(),
      );
      expect(failure.requestId, golden['request_id']);
      expect(failureMessage(l10n, failure), l10n.errorStageInUse);
      expect(planFailureMessage(l10n, failure), l10n.errorStageInUse);
    });

    test('the password is asked for with the code the app reacts to', () async {
      for (final name in [
        'problem_reauth_plan',
        'problem_reauth_contact_delete',
        'problem_reauth_contact_off',
        'problem_reauth_instruction',
        // Reading the instructions asks for it too (Phase 9): the app reads it through
        // withReauth, never as a failure of the session.
        'problem_reauth_instruction_read',
      ]) {
        final failure = await failureOf(problem(name));
        expect(failure, isA<ForbiddenFailure>(), reason: name);
        expect((failure as ForbiddenFailure).code, 'reauth_required');
        expect(failureMessage(l10n, failure), l10n.errorReauthRequired);
      }
    });

    test('every reauth problem of the index is one the app reacts to', () {
      final named = {
        'problem_reauth_plan',
        'problem_reauth_contact_delete',
        'problem_reauth_contact_off',
        'problem_reauth_instruction',
        'problem_reauth_instruction_read',
      };
      final reauth = {
        for (final p in problems)
          if (_json(p['response'] as String)['code'] == 'reauth_required')
            p['name'] as String,
      };
      expect(reauth, named, reason: 'a new one needs its own check above');
    });

    test('the server\'s text is never what the person reads', () async {
      for (final p in problems) {
        final golden = _json(p['response'] as String);
        final failure = await failureOf(p);
        for (final message in [
          failureMessage(l10n, failure),
          instructionFailureMessage(l10n, failure),
          planFailureMessage(l10n, failure),
        ]) {
          expect(
            message,
            isNot(contains(golden['detail'] as String)),
            reason: '${p['name']}',
          );
        }
        expect(failure.requestId, golden['request_id']);
      }
    });
  });

  group(
    'the incident\'s releases (added to the incident object in Phase 6)',
    () {
      final present = File('${_incidentDir.path}/index.json').existsSync();

      test('every incident golden has a `releases` list the app reads', () {
        expect(present, isTrue, reason: 'docs/contracts/phase5 is read here');
        final objects = <String, Map<String, dynamic>>{
          'incident_current':
              _incidentGolden('incident_current.response.json')['incident']
                  as Map<String, dynamic>,
          'incident_after_stage':
              _incidentGolden('incident_after_stage.response.json')['incident']
                  as Map<String, dynamic>,
          'incident_get': _incidentGolden('incident_get.response.json'),
          'home_incident':
              _incidentGolden('home_incident.response.json')['incident']
                  as Map<String, dynamic>,
        };
        for (final MapEntry(key: name, value: json) in objects.entries) {
          expect(json['releases'], isA<List<dynamic>>(), reason: name);
          final incident = Incident.fromJson(json);
          expect(
            incident.releases,
            hasLength((json['releases'] as List).length),
            reason: name,
          );
          // The same object, read through Home.
          final home = HomeSnapshot.fromJson({
            'server_time': json['server_time'],
            'user': {'display_name': 'Test User', 'timezone': 'Asia/Kolkata'},
            'checkin': {'status': 'incident_open'},
            'incident': json,
          });
          expect(home.incidentDetails, incident, reason: name);
        }
      });

      test(
        'a stage that shares instructions counts them without naming them',
        () {
          // `release_count` is on the stage and the warning before it; titles are only on
          // `releases`, which the server fills once a stage has run.
          final json =
              _incidentGolden('incident_after_stage.response.json')['incident']
                  as Map<String, dynamic>;
          final withStage = {
            ...json,
            'timeline': [
              for (final row in json['timeline'] as List)
                (row as Map<String, dynamic>)['kind'] == 'execute_stage'
                    ? {...row, 'status': 'pending', 'release_count': 2}
                    : row,
            ],
          };
          final incident = Incident.fromJson(withStage);
          expect(incident.timeline.last.releaseCount, 2);
          expect(incident.releases, isEmpty);
        },
      );
    },
  );
}
