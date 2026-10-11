@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:afterme/app/repository_providers.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/failures/failure_mapper.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/design_system/error_view.dart';
import 'package:afterme/features/checkin/application/checkin_controller.dart';
import 'package:afterme/features/checkin/data/dio_checkin_repository.dart';
import 'package:afterme/features/checkin/data/dio_schedule_repository.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/checkin/presentation/schedule_labels.dart';
import 'package:afterme/features/home/application/home_status.dart';
import 'package:afterme/features/home/data/dio_home_repository.dart';
import 'package:afterme/features/home/data/models/home_models.dart';
import 'package:afterme/features/incidents/application/safe_controller.dart';
import 'package:afterme/features/incidents/data/dio_incidents_repository.dart';
import 'package:afterme/features/incidents/data/incidents_repository.dart';
import 'package:afterme/features/plan/data/dio_plan_repository.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:afterme/features/plan/presentation/plan_labels.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/api_wire.dart';
import '../helpers/fake_http_adapter.dart';
import '../helpers/in_memory_contacts_repository.dart';
import '../helpers/test_app.dart';

/// The backend writes example requests and responses for every Phase 5 endpoint to
/// docs/contracts/phase5 (generated and compared by a backend test). Those files are the
/// source of truth for what is on the wire: the app must send what the golden requests
/// show (bodies and the `If-Match` / `Idempotency-Key` headers the index lists), read
/// what the golden responses contain (bodies and `ETag`), and map every problem file.
///
/// Phase 5's mobile half is the plan (`GET` / `PUT /v1/plan`), the activation
/// requirements `no_stages` / `stage_empty` and the Home aggregate. Phase 7 adds the
/// incident screens, so the incident endpoints are parsed by the real models and
/// repository (`GET /incidents`, `GET /incidents/{id}`, `POST /incidents/{id}/safe`, and
/// the incident inside `GET /home`), and every incident problem is mapped to the failure
/// the I'M SAFE flow reacts to.
///
/// Until the backend writes the folder, the whole file is skipped with a message, so
/// the suite stays green; once it exists, nothing here needs changing.
///
/// The files are in the repository root; `flutter test` runs from `mobile/`.
final Directory _dir = Directory('../docs/contracts/phase5');

bool get _present => File('${_dir.path}/index.json').existsSync();

Map<String, dynamic> _json(String file) =>
    jsonDecode(File('${_dir.path}/$file').readAsStringSync())
        as Map<String, dynamic>;

String _template(String path) => path.replaceAll(RegExp(r'\{[^}]*\}'), '{}');

Map<String, String> _headers(Map<String, dynamic> entry, String key) => {
  for (final e in ((entry[key] ?? const <String, Object?>{}) as Map).entries)
    '${e.key}': '${e.value}',
};

/// The keys a header-bearing request may carry in the index, and nothing else.
const _knownHeaders = {
  'If-Match',
  'ETag',
  'Idempotency-Key',
  'Idempotent-Replayed',
};

void main() {
  if (!_present) {
    test(
      'phase 5 golden files',
      () {},
      skip:
          'docs/contracts/phase5/index.json does not exist yet: the backend '
          'half of Phase 5 writes it (make contracts). This test parses it as '
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

  test('the index names the contract and covers every Phase 5 endpoint', () {
    expect(index['contract'], 'afterme-phase5');
    expect(index['base_path'], '/v1');
    expect(
      {for (final e in endpoints) route(e)},
      containsAll(<String>[
        'GET /v1/plan',
        'PUT /v1/plan',
        'GET /v1/home',
        'POST /v1/checkin/activate',
        'GET /v1/incidents/current',
        'GET /v1/incidents/{}',
        'POST /v1/incidents/{}/safe',
        'GET /v1/incidents',
        'POST /v1/checkins',
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

  group('recorded headers', () {
    test('only the four the app knows are recorded', () {
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

    test('every ETag names the version in its body', () {
      var seen = 0;
      for (final e in endpoints) {
        final etag = _headers(e, 'response_headers')['ETag'];
        if (etag == null) {
          continue;
        }
        seen++;
        final version = _json(e['response'] as String)['version'];
        final prefix = (e['path'] as String) == '/v1/plan' ? 'plan' : 'sched';
        expect(etag, '"$prefix-$version"', reason: '${e['name']}');
      }
      expect(seen, 3, reason: 'plan GET, plan PUT and the activation');
    });

    test(
      'the If-Match of a plan change is the version that was read',
      () async {
        final get = endpoint('plan_get_default');
        final put = endpoint('plan_put');
        final wire = await apiWire((_, _) => replyFor(get));
        final read = await DioPlanRepository(dio: wire.dio).get();
        expect(
          _headers(put, 'request_headers')['If-Match'],
          read.ifMatch,
          reason: 'built from the body version of the plan that was read',
        );
        expect(read.ifMatch, _headers(get, 'response_headers')['ETag']);
        expect(
          (_json(put['response'] as String)['version'] as int) - read.version,
          1,
          reason: 'a change goes up by one',
        );
      },
    );

    test('a refused plan change names the version it was made from', () {
      for (final name in [
        'problem_validation_failed',
        'problem_precondition_failed',
        'problem_plan_incident_open',
      ]) {
        expect(
          _headers(problem(name), 'request_headers')['If-Match'],
          matches(RegExp(r'^"plan-\d+"$')),
          reason: name,
        );
      }
      expect(
        _headers(problem('problem_precondition_required'), 'request_headers'),
        isEmpty,
        reason: 'the one without If-Match is the one answered with 428',
      );
    });

    test('keys of I\'M OK and I\'M SAFE have the app\'s shape', () {
      final keys = [
        for (final e in [...endpoints, ...problems])
          ?_headers(e, 'request_headers')['Idempotency-Key'],
      ];
      expect(keys, isNotEmpty);
      for (final key in keys) {
        expect(key, matches(RegExp(r'^[A-Za-z0-9_.:-]{16,64}$')));
      }
    });

    test('a replayed I\'M SAFE has the original key and the original '
        'answer, and is marked', () {
      final first = endpoint('incident_safe');
      final replay = endpoint('incident_safe_replay');
      expect(
        _headers(replay, 'request_headers')['Idempotency-Key'],
        _headers(first, 'request_headers')['Idempotency-Key'],
      );
      expect(_headers(first, 'response_headers'), isEmpty);
      expect(
        _headers(replay, 'response_headers')['Idempotent-Replayed'],
        'true',
      );
      // The key order of a replay may differ; the content is the same.
      expect(
        _json(replay['response'] as String),
        _json(first['response'] as String),
      );
    });
  });

  group('plan', () {
    test(
      'GET reads the default plan: no stages, the rules and the ETag',
      () async {
        final e = endpoint('plan_get_default');
        final wire = await apiWire((_, _) => replyFor(e));
        final plan = await DioPlanRepository(dio: wire.dio).get();
        final raw = _json(e['response'] as String);
        expect(wire.request.method, 'GET');
        expect(wire.request.path, e['path']);
        expect(plan.id, raw['id']);
        expect(plan.version, raw['version']);
        expect(plan.graceMinutes, raw['grace_minutes']);
        expect(plan.stages, isEmpty);
        expect(plan.etag, _headers(e, 'response_headers')['ETag']);
        final rules = raw['rules'] as Map<String, dynamic>;
        expect(plan.rules.graceMin, rules['grace_min']);
        expect(plan.rules.graceMax, rules['grace_max']);
        expect(plan.rules.stageGapMin, rules['stage_gap_min']);
        expect(plan.rules.offsetMax, rules['offset_max']);
        expect(plan.rules.releaseOffsetMin, rules['release_offset_min']);
        expect(plan.rules.maxStages, rules['max_stages']);
        expect(plan.rules.customOffsets, rules['custom_offsets']);
        expect(plan.rules.presets, (rules['presets'] as List).cast<int>());
      },
    );

    test(
      'PUT sends the golden body and If-Match, and reads the new plan',
      () async {
        final e = endpoint('plan_put');
        final golden = _json(e['request'] as String);
        final headers = _headers(e, 'request_headers');
        final wire = await apiWire((_, _) => replyFor(e));
        final stage = (golden['stages'] as List).single as Map<String, dynamic>;
        final saved = await DioPlanRepository(dio: wire.dio).save(
          PlanDraft(
            graceMinutes: golden['grace_minutes'] as int,
            stages: [
              PlanStageDraft(
                id: stage['id'] as String?,
                offsetMinutes: stage['offset_minutes'] as int,
                contactIds: (stage['notify_contact_ids'] as List)
                    .cast<String>(),
              ),
            ],
          ),
          ifMatch: headers['If-Match']!,
        );
        expect(wire.request.method, 'PUT');
        expect(wire.request.path, e['path']);
        expect(wire.request.header('If-Match'), headers['If-Match']);
        expect(
          wire.body,
          golden,
          reason: 'exactly the documented fields, with the explicit null id',
        );

        final raw = _json(e['response'] as String);
        expect(saved.version, raw['version']);
        expect(saved.etag, _headers(e, 'response_headers')['ETag']);
        expect(saved.ifMatch, saved.etag, reason: 'the next change');
        expect(saved.graceMinutes, golden['grace_minutes']);
        final rawStage = (raw['stages'] as List).single as Map<String, dynamic>;
        expect(saved.stages.single.id, rawStage['id']);
        expect(saved.stages.single.position, rawStage['position']);
        expect(saved.stages.single.offsetMinutes, rawStage['offset_minutes']);
        expect(saved.stages.single.contactIds, rawStage['notify_contact_ids']);
        expect(saved.stages.single.releaseCount, rawStage['release_count']);
        expect(
          saved.stages.single.offsetMinutes,
          saved.graceMinutes,
          reason: 'stage 1 runs when the grace period ends',
        );
      },
    );

    test('the standard preset is exactly what the contract\'s example '
        'request sends', () async {
      final e = endpoint('plan_put');
      final golden = _json(e['request'] as String);
      final stage = (golden['stages'] as List).single as Map<String, dynamic>;
      final contactId = (stage['notify_contact_ids'] as List).first as String;
      final default_ = await DioPlanRepository(
        dio: (await apiWire((_, _) => replyFor(endpoint('plan_get_default'))))
            .dio,
      ).get();
      final draft = PlanPresets.standard([
        testContact(id: contactId),
      ], current: default_);
      expect(draft.toJson(), golden);
    });

    test('every request body of the plan problems is the same shape', () {
      for (final name in [
        'problem_precondition_required',
        'problem_precondition_failed',
        'problem_plan_incident_open',
        'problem_validation_failed',
      ]) {
        final body = _json(problem(name)['request'] as String);
        expect(body.keys, {'grace_minutes', 'stages'}, reason: name);
        final stage = (body['stages'] as List).single as Map<String, dynamic>;
        expect(stage.keys, {'id', 'offset_minutes', 'notify_contact_ids'});
      }
    });
  });

  group('home', () {
    Future<HomeSnapshot> load(String name) async {
      final e = endpoint(name);
      final wire = await apiWire((_, _) => replyFor(e));
      final home = await DioHomeRepository(dio: wire.dio).load();
      expect(wire.request.path, '/v1/home');
      return home;
    }

    test(
      'a Home without a plan: zero stages and the issue that says so',
      () async {
        final home = await load('home_without_plan');
        final raw = _json(endpoint('home_without_plan')['response'] as String);
        expect(home.incident, isNull);
        expect(home.planSummary.stages, 0);
        expect(home.readiness.ready, isFalse);
        final codes = home.readiness.issues.map((i) => i.code).toList();
        expect(codes, [ReadinessCode.scheduleInactive, ReadinessCode.noStages]);
        final issues =
            (raw['readiness'] as Map<String, dynamic>)['issues'] as List;
        expect(home.readiness.issues, hasLength(issues.length));
        expect(home.checkin.status, CheckInStatus.inactive);
      },
    );

    test('a Home with an incident: the object is kept, read, and counted '
        'as an incident', () async {
      final e = endpoint('home_incident');
      final home = await load('home_incident');
      final raw = _json(e['response'] as String);
      expect(home.incident, raw['incident'], reason: 'kept as it came');
      final incident = home.incidentDetails!;
      expect(incident.id, (raw['incident'] as Map)['id']);
      expect(incident.status, IncidentStatus.grace);
      expect(incident.requires, IncidentRequires.checkin);
      expect(incident.timeline, hasLength(4));
      expect(incident.releases, isEmpty);
      expect(incident.isOpen, isTrue);
      expect(home.checkin.status, CheckInStatus.incidentOpen);
      expect(home.planSummary.stages, 1, reason: 'the real count');
      expect(home.readiness.ready, isTrue);
      expect(home.recentActivity.first.action, 'auth.login_succeeded');

      // The neutral placeholder: a non-null incident is an incident, whatever the
      // schedule says.
      final now = home.serverTime;
      expect(homeStatus(home, serverNow: now), HomeStatus.incident);
      final active = home.copyWith(
        checkin: home.checkin.copyWith(status: CheckInStatus.active),
      );
      expect(homeStatus(active, serverNow: now), HomeStatus.incident);
      final closed = active.copyWith(incident: null);
      expect(homeStatus(closed, serverNow: now), isNot(HomeStatus.incident));
    });

    test('every readiness code the app knows is known to the app', () async {
      for (final name in ['home_without_plan', 'home_incident']) {
        final home = await load(name);
        for (final issue in home.readiness.issues) {
          expect(issue.code, isNot(ReadinessCode.unknown), reason: name);
        }
      }
    });

    test('the incident object of Home has the keys of the incident '
        'endpoints', () async {
      final fromHome =
          _json(endpoint('home_incident')['response'] as String)['incident']
              as Map<String, dynamic>;
      final current =
          _json(endpoint('incident_current')['response'] as String)['incident']
              as Map<String, dynamic>;
      final byId = _json(endpoint('incident_get')['response'] as String);
      expect(fromHome.keys.toSet(), current.keys.toSet());
      expect(byId.keys.toSet(), current.keys.toSet());
      expect(fromHome['id'], current['id']);
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
      expect(wire.request.data, isNull);
      expect(snapshot.status, CheckInStatus.active);
      expect(snapshot.nextDueAt, instant(raw['next_due_at']));
      expect(snapshot.version, raw['version']);
      expect(snapshot.etag, _headers(e, 'response_headers')['ETag']);
      expect(snapshot.isOn, isTrue);
    });

    test('the requirement is said in words, and the screens that fix it '
        'are named', () {
      final l10n = AppLocalizationsEn();
      final golden = _json(
        problem('problem_activation_requirements_unmet')['response'] as String,
      );
      final codes = (golden['requirements'] as List).cast<String>();
      expect(codes, ['no_stages']);
      expect(activationMissingText(l10n, codes), l10n.activationNoStages);
      // The two other codes of the contract (API_SPEC §6.1 and the Home readiness).
      expect(
        activationMissingText(l10n, ['no_contacts', 'stage_empty']),
        '${l10n.activationNoContacts}, ${l10n.activationStageEmpty}',
      );
    });
  });

  group('check-ins', () {
    test(
      'an I\'M OK that closes the incident sends its key and is read',
      () async {
        final e = endpoint('checkin_resolves_incident');
        final key = _headers(e, 'request_headers')['Idempotency-Key']!;
        final wire = await apiWire((_, _) => replyFor(e));
        final result = await DioCheckInRepository(dio: wire.dio)
            .checkIn(idempotencyKey: key);
        final raw = _json(e['response'] as String);
        final receipt = raw['checkin'] as Map<String, dynamic>;
        expect(wire.request.method, 'POST');
        expect(wire.request.path, '/v1/checkins');
        expect(wire.request.header('Idempotency-Key'), key);
        expect(result.incidentResolved, isTrue);
        expect(result.checkin.id, receipt['id']);
        expect(result.checkin.kind.name, receipt['kind']);
        expect(result.checkin.receivedAt, instant(receipt['received_at']));
        expect(result.nextDueAt, instant(raw['next_due_at']));
        expect(result.serverTime, instant(raw['server_time']));
      },
    );
  });

  group('incidents', () {
    const requires = {'checkin', 'safe'};

    Map<String, dynamic> incidentOf(String name) {
      final raw = _json(endpoint(name)['response'] as String);
      return name == 'incident_get'
          ? raw
          : raw['incident'] as Map<String, dynamic>;
    }

    /// Every field of [model] is what [json] says.
    void expectSameIncident(Incident model, Map<String, dynamic> json) {
      expect(model.id, json['id']);
      expect(model.status.name, json['status']);
      expect(
        model.requires?.name,
        json['requires'],
        reason: '`requires` is "checkin" or "safe", null once closed',
      );
      expect(model.missedDueAt, instant(json['missed_due_at']));
      expect(model.anchorAt, instant(json['anchor_at']));
      expect(model.graceEndsAt, instant(json['grace_ends_at']));
      expect(model.contactsMessaged, json['contacts_messaged']);
      expect(model.closedAt, instant(json['closed_at']));
      expect(model.serverTime, instant(json['server_time']));
      final timeline = (json['timeline'] as List).cast<Map<String, dynamic>>();
      expect(model.timeline, hasLength(timeline.length));
      for (var i = 0; i < timeline.length; i++) {
        final row = timeline[i];
        final item = model.timeline[i];
        expect(
          item.kind,
          isNot(TimelineKind.unknown),
          reason: '${row['kind']} is known to the app',
        );
        expect(item.status, isNot(TimelineStatus.unknown));
        expect(item.scheduledFor, instant(row['scheduled_for']));
        expect(item.stagePosition, row['stage_position']);
        expect(item.releaseCount, row['release_count']);
        final contacts = row['contacts'] as List?;
        expect(item.contacts?.length, contacts?.length);
        for (var c = 0; c < (contacts?.length ?? 0); c++) {
          final contact = contacts![c] as Map<String, dynamic>;
          expect(item.contacts![c].id, contact['id']);
          expect(item.contacts![c].displayName, contact['display_name']);
          expect(item.contacts![c].result?.name, contact['result']);
        }
      }
      expect(model.releases, hasLength((json['releases'] as List).length));
    }

    test('the current incident, by id, in Home and after a stage are read '
        'by the model, field for field', () async {
      for (final name in [
        'incident_current',
        'incident_get',
        'incident_after_stage',
        'home_incident',
      ]) {
        final raw = name == 'home_incident'
            ? _json(endpoint(name)['response'] as String)['incident']
                  as Map<String, dynamic>
            : incidentOf(name);
        final incident = Incident.fromJson(raw);
        expectSameIncident(incident, raw);
        expect(requires, contains(raw['requires']), reason: name);
        expect(
          incident.needsSafe,
          raw['contacts_messaged'],
          reason: 'I\'M SAFE is needed exactly when somebody was told',
        );
        expect(
          raw.containsKey('releases'),
          isTrue,
          reason: '$name has `releases`',
        );
      }
      final after = Incident.fromJson(incidentOf('incident_after_stage'));
      expect(after.status, IncidentStatus.escalated);
      expect(after.needsSafe, isTrue);
      expect(after.notifiedContacts.single.displayName, 'Mom');
      expect(
        after.timeline.last.contacts!.single.result,
        ContactResult.messaged,
      );
      expect(after.nextStage, isNull);
      expect(
        _json(
          endpoint('incidents_current_none')['response'] as String,
        )['incident'],
        isNull,
      );
    });

    test('GET by id reads the golden through the repository', () async {
      final e = endpoint('incident_get');
      final wire = await apiWire((_, _) => replyFor(e));
      final json = _json(e['response'] as String);
      final incident = await DioIncidentsRepository(dio: wire.dio)
          .get(json['id'] as String);
      expect(wire.request.method, 'GET');
      expect(wire.request.path, '/v1/incidents/${json['id']}');
      expectSameIncident(incident, json);
    });

    test('a release as the backend\'s ReleaseOut describes it is read, with '
        'a title only the owner sees', () {
      // No golden carries a release yet: this object has the keys of `ReleaseOut`
      // (backend/app/incidents/schemas.py).
      final json = {
        ...incidentOf('incident_after_stage'),
        'releases': [
          {
            'contact_id': '00000000-0000-4000-8000-000000000003',
            'contact_display_name': 'Brother',
            'instruction_id': '00000000-0000-4000-8000-000000000020',
            'instruction_title': 'House emergency',
            'stage_position': 2,
            'released_at': '2026-10-10T14:30:01Z',
            'visible_after': '2026-10-10T14:35:01Z',
            'first_viewed_at': '2026-10-10T14:50:05Z',
            'last_viewed_at': '2026-10-10T14:50:05Z',
            'view_count': 1,
            'revoked_at': null,
            'revoke_reason': null,
          },
          {
            'contact_id': '00000000-0000-4000-8000-000000000003',
            'contact_display_name': 'Brother',
            'instruction_id': '00000000-0000-4000-8000-000000000021',
            'instruction_title': null,
            'stage_position': null,
            'released_at': '2026-10-10T14:30:01Z',
            'visible_after': '2026-10-10T14:35:01Z',
            'first_viewed_at': null,
            'last_viewed_at': null,
            'view_count': 0,
            'revoked_at': '2026-10-10T15:00:00Z',
            'revoke_reason': 'user_safe',
          },
        ],
      };
      final incident = Incident.fromJson(json);
      final viewed = incident.releases.first;
      expect(viewed.contactDisplayName, 'Brother');
      expect(viewed.instructionTitle, 'House emergency');
      expect(viewed.stagePosition, 2);
      expect(viewed.firstViewedAt, DateTime.utc(2026, 10, 10, 14, 50, 5));
      expect(viewed.viewCount, 1);
      expect(viewed.isRevoked, isFalse);
      final revoked = incident.releases.last;
      expect(revoked.instructionTitle, isNull);
      expect(revoked.stagePosition, isNull);
      expect(revoked.wasViewed, isFalse);
      expect(revoked.revokeReason, ReleaseRevokeReason.userSafe);
    });

    test('the history lists, newest first, with a cursor', () async {
      for (final name in ['incidents_list', 'incidents_list_after']) {
        final e = endpoint(name);
        final wire = await apiWire((_, _) => replyFor(e));
        final page = await DioIncidentsRepository(dio: wire.dio).list();
        final raw = _json(e['response'] as String);
        expect(wire.request.method, 'GET');
        expect(wire.request.path, '/v1/incidents');
        expect(raw.keys, {'items', 'next_cursor'}, reason: name);
        final items = (raw['items'] as List).cast<Map<String, dynamic>>();
        expect(page.items, hasLength(items.length));
        expect(page.nextCursor, raw['next_cursor']);
        for (var i = 0; i < items.length; i++) {
          final item = page.items[i];
          expect(item.id, items[i]['id']);
          expect(item.status.name, items[i]['status']);
          expect(item.closedBy?.name, isNotNull);
          expect(item.closedBy, isNot(IncidentClosedBy.unknown));
          expect(_snake(item.closedBy!.name), items[i]['closed_by']);
          expect(item.missedDueAt, instant(items[i]['missed_due_at']));
          expect(item.openedAt, instant(items[i]['opened_at']));
          expect(item.closedAt, instant(items[i]['closed_at']));
          expect(item.contactsMessaged, items[i]['contacts_messaged']);
          expect(item.isClosed, isTrue);
        }
        final opened = [for (final i in page.items) i.openedAt];
        expect([...opened]..sort((a, b) => b.compareTo(a)), opened);
      }
    });

    test('I\'M SAFE sends the golden key and no body, and reads who is told; '
        'a replay reads the same', () async {
      final first = endpoint('incident_safe');
      final replay = endpoint('incident_safe_replay');
      final key = _headers(first, 'request_headers')['Idempotency-Key']!;
      final raw = _json(first['response'] as String);
      Future<SafeResult> run(Map<String, dynamic> e) async {
        final wire = await apiWire((_, _) => replyFor(e));
        final result = await DioIncidentsRepository(dio: wire.dio)
            .markSafe(raw['incident_id'] as String, idempotencyKey: key);
        expect(wire.request.method, 'POST');
        expect(wire.request.path, '/v1/incidents/${raw['incident_id']}/safe');
        expect(wire.request.header('Idempotency-Key'), key);
        expect(wire.request.data, isNull);
        return result;
      }

      final result = await run(first);
      expect(result.incidentId, raw['incident_id']);
      expect(result.nextDueAt, instant(raw['next_due_at']));
      expect(result.serverTime, instant(raw['server_time']));
      final told = (raw['all_clear_sent_to'] as List)
          .cast<Map<String, dynamic>>();
      expect(result.allClearSentTo, hasLength(told.length));
      expect(result.allClearSentTo.first.contactId, told.first['contact_id']);
      expect(
        result.allClearSentTo.first.displayName,
        told.first['display_name'],
      );
      // The replay is the same answer (its key order may differ).
      expect(await run(replay), result);
    });
  });

  group('problem+json files', () {
    final l10n = AppLocalizationsEn();

    /// The failure the app makes of [p]'s answer, through the real API client and the
    /// repository that owns the request (or the bare client where none exists yet).
    Future<AppFailure> failureOf(Map<String, dynamic> p) async {
      final wire = await apiWire((_, _) => problemReply(p));
      final plan = DioPlanRepository(dio: wire.dio);
      final schedule = DioScheduleRepository(dio: wire.dio);
      final ifMatch = _headers(p, 'request_headers')['If-Match'] ?? '"plan-1"';
      try {
        switch (route(p)) {
          case 'PUT /v1/plan':
            await plan.save(
              const PlanDraft(graceMinutes: 180, stages: []),
              ifMatch: ifMatch,
            );
          case 'POST /v1/checkin/activate':
            await schedule.activate();
          case 'POST /v1/checkins':
            await DioCheckInRepository(dio: wire.dio)
                .checkIn(idempotencyKey: 'a-key-of-16-chars');
          case 'POST /v1/incidents/{}/safe':
            await DioIncidentsRepository(dio: wire.dio)
                .markSafe('incident-1', idempotencyKey: 'a-key-of-16-chars');
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
        {
          'activation_requirements_unmet',
          'precondition_required',
          'validation_failed',
          'precondition_failed',
          'incident_open',
          'safe_required',
          'reauth_required',
          'invalid_state',
        },
      );
    });

    test('activation_requirements_unmet lists what is missing', () async {
      final p = problem('problem_activation_requirements_unmet');
      final failure = await failureOf(p);
      expect(failure, isA<ActivationRequirementsFailure>());
      expect(
        (failure as ActivationRequirementsFailure).requirements,
        (_json(p['response'] as String)['requirements'] as List).cast<String>(),
      );
      expect(failureMessage(l10n, failure), l10n.errorActivationRequirements);
    });

    test('428 and 412 are the conflicts the plan screens explain', () async {
      for (final (name, code) in [
        ('problem_precondition_required', 'precondition_required'),
        ('problem_precondition_failed', 'precondition_failed'),
      ]) {
        final failure = await failureOf(problem(name));
        expect(failure, isA<ConflictFailure>());
        expect((failure as ConflictFailure).code, code);
        expect(failureMessage(l10n, failure), l10n.errorStaleData);
        expect(planFailureMessage(l10n, failure), l10n.planStale);
        expect(failure.problem?.status, problem(name)['status']);
      }
    });

    test('an open incident refuses the change in the app\'s words', () async {
      final failure = await failureOf(problem('problem_plan_incident_open'));
      expect(failure, isA<ConflictFailure>());
      expect((failure as ConflictFailure).code, 'incident_open');
      expect(failureMessage(l10n, failure), l10n.errorIncidentOpen);
      expect(planFailureMessage(l10n, failure), l10n.errorIncidentOpen);
    });

    test('a field error is mapped to its field and never shown as the '
        'server wrote it', () async {
      final p = problem('problem_validation_failed');
      final golden = _json(p['response'] as String);
      final failure = await failureOf(p);
      expect(failure, isA<ValidationFailure>());
      final errors = (failure as ValidationFailure).fieldErrors;
      expect(
        [for (final e in errors) '${e.field} ${e.code}'],
        [
          for (final e in golden['errors'] as List)
            '${(e as Map)['field']} ${e['code']}',
        ],
      );
      expect(errors.single.field, 'stages[0].offset_minutes');
      expect(planFailureMessage(l10n, failure), l10n.planErrorStageTime);
      for (final e in golden['errors'] as List) {
        expect(
          planFailureMessage(l10n, failure),
          isNot(contains((e as Map)['message'] as String)),
        );
      }
    });

    test(
      'safe_required is the existing conflict, with its incident id',
      () async {
        final p = problem('problem_safe_required');
        final golden = _json(p['response'] as String);
        final failure = await failureOf(p);
        expect(failure, isA<ConflictFailure>());
        expect((failure as ConflictFailure).code, 'safe_required');
        expect(failure.problem?.incidentId, golden['incident_id']);
        expect(failure.requestId, golden['request_id']);
        expect(failureMessage(l10n, failure), l10n.errorSafeRequired);
      },
    );

    test('safe_required still puts the tap in the placeholder state, and '
        'nothing is kept to retry', () async {
      final p = problem('problem_safe_required');
      final wire = await apiWire((_, _) => problemReply(p));
      final fakes = TestFakes()..realCheckInRepositories = true;
      final container = ProviderContainer.test(
        retry: (retryCount, error) => null,
        overrides: [
          ...testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
          checkInRepositoryProvider.overrideWithValue(
            DioCheckInRepository(dio: wire.dio),
          ),
        ],
      );
      container.listen(checkInControllerProvider, (_, _) {});
      await container.read(checkInControllerProvider.notifier).checkIn();
      final state = container.read(checkInControllerProvider);
      expect(state.phase, CheckInPhase.safeRequired);
      expect(state.isUnconfirmed, isFalse, reason: 'retrying cannot change it');
      expect(wire.adapter.requests, hasLength(1));
      expect(wire.request.header('Idempotency-Key'), isNotNull);
    });

    test('reauth_required and invalid_state keep the codes the app reacts '
        'to', () async {
      final reauth = await failureOf(problem('problem_reauth_required'));
      expect(reauth, isA<ForbiddenFailure>());
      expect((reauth as ForbiddenFailure).code, 'reauth_required');
      expect(failureMessage(l10n, reauth), l10n.errorReauthRequired);

      final state = await failureOf(problem('problem_invalid_state'));
      expect(state, isA<InvalidStateFailure>());
      expect(failureMessage(l10n, state), l10n.errorInvalidState);
    });

    test(
      'the I\'M SAFE flow reacts to reauth_required and invalid_state',
      () async {
        for (final (name, check) in <(String, bool Function(SafeState))>[
          ('problem_reauth_required', (s) => s.needsPassword),
          ('problem_invalid_state', (s) => s.alreadyClosed),
        ]) {
          final p = problem(name);
          final wire = await apiWire((_, _) => problemReply(p));
          final fakes = TestFakes()..realIncidentsRepository = true;
          final container = ProviderContainer.test(
            retry: (retryCount, error) => null,
            overrides: [
              ...testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
              incidentsRepositoryProvider.overrideWithValue(
                DioIncidentsRepository(dio: wire.dio),
              ),
            ],
          );
          container.listen(safeControllerProvider, (_, _) {});
          await expectLater(
            container
                .read(safeControllerProvider.notifier)
                .markSafe('incident-1'),
            throwsA(isA<AppFailure>()),
            reason: name,
          );
          final state = container.read(safeControllerProvider);
          expect(state.phase, SafePhase.failed, reason: name);
          expect(check(state), isTrue, reason: name);
          expect(state.result, isNull, reason: 'never claimed: $name');
          expect(wire.request.header('Idempotency-Key'), isNotNull);
        }
      },
    );

    test('the server\'s text is never what the person reads', () async {
      for (final p in problems) {
        final golden = _json(p['response'] as String);
        final failure = await failureOf(p);
        expect(
          failureMessage(l10n, failure),
          isNot(contains(golden['detail'] as String)),
          reason: '${p['name']}',
        );
        expect(failure.requestId, golden['request_id']);
      }
    });
  });
}

/// `userSafe` -> `user_safe`.
String _snake(String name) =>
    name.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');
