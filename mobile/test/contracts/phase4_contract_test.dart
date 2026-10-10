@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/design_system/error_view.dart';
import 'package:afterme/features/checkin/data/dio_checkin_repository.dart';
import 'package:afterme/features/checkin/data/dio_schedule_repository.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/home/data/dio_home_repository.dart';
import 'package:afterme/features/home/data/models/home_models.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/api_wire.dart';
import '../helpers/fake_http_adapter.dart';

/// The backend writes example requests and responses for every Phase 4 endpoint to
/// docs/contracts/phase4 (generated and compared by a backend test). Those files are the
/// source of truth for what is on the wire: the app must send what the golden requests
/// show (bodies and the `If-Match` / `Idempotency-Key` headers the index lists), read
/// what the golden responses contain (bodies and `ETag`), and map every problem file.
///
/// Until the backend writes the folder, the whole file is skipped with a message, so
/// the suite stays green; once it exists, nothing here needs changing.
///
/// The files are in the repository root; `flutter test` runs from `mobile/`.
final Directory _dir = Directory('../docs/contracts/phase4');

bool get _present => File('${_dir.path}/index.json').existsSync();

Map<String, dynamic> _json(String file) =>
    jsonDecode(File('${_dir.path}/$file').readAsStringSync())
        as Map<String, dynamic>;

String _template(String path) => path.replaceAll(RegExp(r'\{[^}]*\}'), '{}');

Map<String, String> _headers(Map<String, dynamic> entry, String key) => {
  for (final e in ((entry[key] ?? const <String, Object?>{}) as Map).entries)
    '${e.key}': '${e.value}',
};

void main() {
  if (!_present) {
    test(
      'phase 4 golden files',
      () {},
      skip:
          'docs/contracts/phase4/index.json does not exist yet: the backend '
          'half of Phase 4 writes it (make contracts). This test parses it as '
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

  List<Map<String, dynamic>> named(String route_) => [
    for (final e in endpoints)
      if (route(e) == route_) e,
  ];

  FakeReply replyFor(Map<String, dynamic> e) {
    final response = e['response'] as String?;
    return FakeReply.json(
      e['status'] as int,
      response == null ? null : _json(response),
      _headers(e, 'response_headers'),
    );
  }

  DateTime? instant(Object? value) =>
      value == null ? null : DateTime.parse(value as String);

  test('the index names the contract and covers every Phase 4 endpoint', () {
    expect(index['contract'], 'afterme-phase4');
    expect(index['base_path'], '/v1');
    expect(
      {for (final e in endpoints) route(e)},
      containsAll(<String>[
        'GET /v1/checkin/schedule',
        'PUT /v1/checkin/schedule',
        'POST /v1/checkin/activate',
        'POST /v1/checkin/deactivate',
        'POST /v1/checkins',
        'GET /v1/checkins',
        'GET /v1/home',
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

  test('every ETag in the index names the version in its body', () {
    for (final e in endpoints) {
      final etag = _headers(e, 'response_headers')['ETag'];
      if (etag != null) {
        final version = _json(e['response'] as String)['version'];
        expect(etag, '"sched-$version"', reason: '${e['name']}');
      }
    }
  });

  group('schedule', () {
    test('GET reads every example and the ETag', () async {
      for (final e in named('GET /v1/checkin/schedule')) {
        final wire = await apiWire((_, _) => replyFor(e));
        final snapshot = await DioScheduleRepository(dio: wire.dio).get();
        final raw = _json(e['response'] as String);
        expect(wire.request.method, 'GET');
        expect(wire.request.path, e['path']);
        expect(snapshot.intervalDays, raw['interval_days']);
        expect(snapshot.dueLocalTime, raw['due_local_time']);
        expect(snapshot.reminderLeadMinutes, raw['reminder_lead_minutes']);
        expect(snapshot.timezone, raw['timezone']);
        expect(snapshot.status.name, _camel(raw['status'] as String));
        expect(snapshot.nextDueAt, instant(raw['next_due_at']));
        expect(snapshot.lastCheckinAt, instant(raw['last_checkin_at']));
        expect(snapshot.version, raw['version']);
        expect(
          snapshot.etag,
          _headers(e, 'response_headers')['ETag'],
          reason: '${e['name']}: the ETag header is kept for If-Match',
        );
      }
    });

    test(
      'PUT sends the golden body and If-Match, and reads the new ETag',
      () async {
        for (final e in named('PUT /v1/checkin/schedule')) {
          final golden = _json(e['request'] as String);
          final headers = _headers(e, 'request_headers');
          final wire = await apiWire((_, _) => replyFor(e));
          final saved = await DioScheduleRepository(dio: wire.dio).save(
            CheckInSchedule(
              intervalDays: golden['interval_days'] as int,
              dueMinutes: parseLocalTime(golden['due_local_time'] as String),
              reminderLeadMinutes: golden['reminder_lead_minutes'] as int,
            ),
            ifMatch: headers['If-Match']!,
          );
          expect(wire.request.method, 'PUT');
          expect(wire.request.path, e['path']);
          expect(wire.request.header('If-Match'), headers['If-Match']);
          expect(
            wire.body,
            golden,
            reason: 'exactly the three documented fields',
          );
          final raw = _json(e['response'] as String);
          expect(saved.version, raw['version']);
          expect(saved.etag, _headers(e, 'response_headers')['ETag']);
          expect(saved.intervalDays, golden['interval_days']);
        }
      },
    );

    test('activate and deactivate are bodiless and return the ETag', () async {
      for (final (method, path) in [
        ('POST', '/v1/checkin/activate'),
        ('POST', '/v1/checkin/deactivate'),
      ]) {
        for (final e in named('$method $path')) {
          final wire = await apiWire((_, _) => replyFor(e));
          final repository = DioScheduleRepository(dio: wire.dio);
          final snapshot = path == '/v1/checkin/activate'
              ? await repository.activate()
              : await repository.deactivate();
          expect(wire.request.method, method);
          expect(wire.request.path, path);
          expect(wire.request.data, isNull);
          final raw = _json(e['response'] as String);
          expect(snapshot.status.name, _camel(raw['status'] as String));
          expect(snapshot.etag, _headers(e, 'response_headers')['ETag']);
          expect(snapshot.nextDueAt, instant(raw['next_due_at']));
        }
      }
    });
  });

  group('check-ins', () {
    test('POST sends the Idempotency-Key and reads the answer (record, '
        'inactive and replay)', () async {
      final examples = named('POST /v1/checkins');
      expect(examples, isNotEmpty);
      for (final e in examples) {
        final golden = _json(e['request'] as String);
        final headers = _headers(e, 'request_headers');
        final key = headers['Idempotency-Key']!;
        final wire = await apiWire((_, _) => replyFor(e));
        final result = await DioCheckInRepository(dio: wire.dio).checkIn(
          idempotencyKey: key,
          clientReportedAt: instant(golden['client_reported_at']),
        );
        expect(wire.request.method, 'POST');
        expect(wire.request.path, '/v1/checkins');
        expect(wire.request.header('Idempotency-Key'), key);
        // The app sends the same instant, in UTC with a Z (the golden file may use
        // an offset).
        final sent = wire.body['client_reported_at'] as String;
        expect(sent, endsWith('Z'));
        expect(instant(sent), instant(golden['client_reported_at']));

        final raw = _json(e['response'] as String);
        final receipt = raw['checkin'] as Map<String, dynamic>;
        expect(result.checkin.id, receipt['id']);
        expect(result.checkin.kind.name, receipt['kind']);
        expect(result.checkin.receivedAt, instant(receipt['received_at']));
        expect(result.nextDueAt, instant(raw['next_due_at']));
        expect(result.incidentResolved, raw['incident_resolved']);
        expect(result.serverTime, instant(raw['server_time']));
      }
    });

    test('a replay is a success with the original answer', () async {
      final record = named('POST /v1/checkins')
          .where((e) => e['name'] == 'checkin_record');
      final replay = named('POST /v1/checkins').where(
        (e) =>
            _headers(e, 'response_headers').containsKey('Idempotent-Replayed'),
      );
      if (record.isEmpty || replay.isEmpty) {
        return;
      }
      expect(
        _headers(replay.single, 'request_headers')['Idempotency-Key'],
        _headers(record.single, 'request_headers')['Idempotency-Key'],
        reason: 'the same key is reused for a retry of one tap',
      );
      expect(
        _json(replay.single['response'] as String),
        _json(record.single['response'] as String),
      );
      expect(
        _headers(replay.single, 'response_headers')['Idempotent-Replayed'],
        'true',
      );
    });

    test('inactive schedule: next_due_at is null', () async {
      final inactive = named('POST /v1/checkins')
          .where((e) => _json(e['response'] as String)['next_due_at'] == null);
      for (final e in inactive) {
        final wire = await apiWire((_, _) => replyFor(e));
        final result = await DioCheckInRepository(dio: wire.dio).checkIn(
          idempotencyKey: _headers(e, 'request_headers')['Idempotency-Key']!,
        );
        expect(result.nextDueAt, isNull);
      }
    });

    test('GET history reads items and the cursor', () async {
      for (final e in named('GET /v1/checkins')) {
        final wire = await apiWire((_, _) => replyFor(e));
        final page = await DioCheckInRepository(dio: wire.dio).history();
        final raw = _json(e['response'] as String);
        final items = (raw['items'] as List).cast<Map<String, dynamic>>();
        expect(page.items.map((i) => i.id), items.map((i) => i['id']));
        for (var i = 0; i < items.length; i++) {
          expect(page.items[i].kind.name, items[i]['kind']);
          expect(page.items[i].source.name, items[i]['source']);
          expect(page.items[i].receivedAt, instant(items[i]['received_at']));
        }
        expect(page.nextCursor, raw['next_cursor']);
      }
    });
  });

  group('home', () {
    test('every example parses into the model', () async {
      final homes = named('GET /v1/home');
      expect(homes, isNotEmpty);
      for (final e in homes) {
        final wire = await apiWire((_, _) => replyFor(e));
        final home = await DioHomeRepository(dio: wire.dio).load();
        final raw = _json(e['response'] as String);
        expect(wire.request.path, '/v1/home');
        expect(home.serverTime, instant(raw['server_time']));
        final user = raw['user'] as Map<String, dynamic>;
        expect(home.user.displayName, user['display_name']);
        expect(home.user.tier, user['tier']);
        expect(home.user.timezone, user['timezone']);
        final checkin = raw['checkin'] as Map<String, dynamic>;
        expect(home.checkin.status.name, _camel(checkin['status'] as String));
        expect(home.checkin.nextDueAt, instant(checkin['next_due_at']));
        expect(home.checkin.lastCheckinAt, instant(checkin['last_checkin_at']));
        final schedule = checkin['schedule'] as Map<String, dynamic>;
        expect(home.checkin.schedule!.intervalDays, schedule['interval_days']);
        expect(home.checkin.schedule!.dueLocalTime, schedule['due_local_time']);
        expect(
          home.checkin.schedule!.reminderLeadMinutes,
          schedule['reminder_lead_minutes'],
        );
        expect(home.incident, raw['incident'], reason: 'null in Phase 4');
        final plan = raw['plan_summary'] as Map<String, dynamic>;
        expect(home.planSummary.stages, plan['stages']);
        expect(home.planSummary.contactsTotal, plan['contacts_total']);
        expect(home.planSummary.contactsVerified, plan['contacts_verified']);
        expect(
          home.planSummary.instructionsActive,
          plan['instructions_active'],
        );
        final readiness = raw['readiness'] as Map<String, dynamic>;
        expect(home.readiness.ready, readiness['ready']);
        final issues = (readiness['issues'] as List)
            .cast<Map<String, dynamic>>();
        expect(home.readiness.issues, hasLength(issues.length));
        for (var i = 0; i < issues.length; i++) {
          expect(
            home.readiness.issues[i].code,
            isNot(ReadinessCode.unknown),
            reason: 'the app must know ${issues[i]['code']}',
          );
          expect(
            home.readiness.issues[i].code.name,
            _camel(issues[i]['code'] as String),
          );
          expect(home.readiness.issues[i].contactId, issues[i]['contact_id']);
        }
        final activity = (raw['recent_activity'] as List)
            .cast<Map<String, dynamic>>();
        expect(home.recentActivity.map((a) => a.action), [
          for (final a in activity) a['action'],
        ]);
      }
    });

    test('the examples cover the states Home maps', () {
      final statuses = {
        for (final e in named('GET /v1/home'))
          (_json(e['response'] as String)['checkin']
                  as Map<String, dynamic>)['status']:
              true,
      };
      expect(statuses.keys, containsAll(['inactive', 'active']));
    });
  });

  group('problem+json files', () {
    final l10n = AppLocalizationsEn();

    Future<AppFailure> failureOf(Map<String, dynamic> problem) async {
      final golden = _json(problem['response'] as String);
      final wire = await apiWire(
        (_, _) => FakeReply.raw(
          golden['status'] as int,
          jsonEncode(golden),
          'application/problem+json',
        ),
      );
      final schedule = DioScheduleRepository(dio: wire.dio);
      final checkins = DioCheckInRepository(dio: wire.dio);
      final ifMatch =
          _headers(problem, 'request_headers')['If-Match'] ?? '"sched-1"';
      try {
        switch (route(problem)) {
          case 'PUT /v1/checkin/schedule':
            await schedule.save(const CheckInSchedule(), ifMatch: ifMatch);
          case 'POST /v1/checkin/activate':
            await schedule.activate();
          case 'POST /v1/checkin/deactivate':
            await schedule.deactivate();
          case 'POST /v1/checkins':
            await checkins.checkIn(idempotencyKey: 'a-key-of-16-chars');
          case 'GET /v1/checkins':
            await checkins.history();
          case 'GET /v1/checkin/schedule':
            await schedule.get();
          case 'GET /v1/home':
            await DioHomeRepository(dio: wire.dio).load();
          default:
            fail('no repository call for ${route(problem)}');
        }
      } on AppFailure catch (failure) {
        return failure;
      }
      fail('expected a failure for ${problem['name']}');
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
          'precondition_required',
          'precondition_failed',
          'incident_open',
          'activation_requirements_unmet',
          'validation_failed',
          'reauth_required',
        ]),
      );
    });

    test('re-authentication is asked for by name on the two requests that '
        'need it', () {
      final asked = {
        for (final p in problems)
          if (_json(p['response'] as String)['code'] == 'reauth_required')
            '${route(p)} ${p['status']}',
      };
      expect(asked, {
        'POST /v1/checkin/deactivate 403',
        'PUT /v1/checkin/schedule 403',
      });
    });

    test('lengthening an active schedule: the PUT answered 403 '
        'reauth_required becomes the failure that opens the password '
        'sheet', () async {
      final lengthen = problems.where(
        (p) => p['name'] == 'problem_reauth_required_lengthen',
      );
      expect(lengthen, hasLength(1), reason: 'the index lists it');
      final problem = lengthen.single;
      expect(route(problem), 'PUT /v1/checkin/schedule');
      expect(problem['status'], 403);
      final golden = _json(problem['response'] as String);
      expect(golden['status'], 403);
      expect(golden['code'], 'reauth_required');

      // The app sends what the example request shows (three fields, the If-Match).
      final request = _json(problem['request'] as String);
      final headers = _headers(problem, 'request_headers');
      final wire = await apiWire(
        (_, _) =>
            FakeReply.raw(403, jsonEncode(golden), 'application/problem+json'),
      );
      Object? thrown;
      try {
        await DioScheduleRepository(dio: wire.dio).save(
          CheckInSchedule(
            intervalDays: request['interval_days'] as int,
            dueMinutes: parseLocalTime(request['due_local_time'] as String),
            reminderLeadMinutes: request['reminder_lead_minutes'] as int,
          ),
          ifMatch: headers['If-Match']!,
        );
      } on Object catch (error) {
        thrown = error;
      }
      expect(wire.request.method, 'PUT');
      expect(wire.request.path, '/v1/checkin/schedule');
      expect(wire.request.header('If-Match'), headers['If-Match']);
      expect(wire.body, request);

      // `withReauth` reacts to exactly this failure, and to no other 403.
      expect(thrown, isA<ForbiddenFailure>());
      final failure = thrown! as ForbiddenFailure;
      expect(failure.code, 'reauth_required');
      expect(failure.requestId, golden['request_id']);
      expect(failureMessage(l10n, failure), l10n.errorReauthRequired);
    });

    test('each problem becomes its typed failure with calm copy', () async {
      for (final problem in problems) {
        final golden = _json(problem['response'] as String);
        final failure = await failureOf(problem);
        final code = golden['code'];
        switch (code) {
          case 'precondition_required' || 'precondition_failed':
            expect(failure, isA<ConflictFailure>());
            expect((failure as ConflictFailure).code, code);
            expect(failureMessage(l10n, failure), l10n.errorStaleData);
          case 'incident_open':
            expect(failure, isA<ConflictFailure>());
            expect((failure as ConflictFailure).code, 'incident_open');
            expect(failureMessage(l10n, failure), l10n.errorIncidentOpen);
          case 'activation_requirements_unmet':
            expect(failure, isA<ActivationRequirementsFailure>());
            expect(
              (failure as ActivationRequirementsFailure).requirements,
              (golden['requirements'] as List).cast<String>(),
            );
            expect(
              failureMessage(l10n, failure),
              l10n.errorActivationRequirements,
            );
          case 'validation_failed':
            expect(failure, isA<ValidationFailure>());
            expect(
              (failure as ValidationFailure).fieldErrors.map((f) => f.field),
              [for (final f in golden['errors'] as List) (f as Map)['field']],
            );
          case 'reauth_required':
            expect(failure, isA<ForbiddenFailure>());
            expect((failure as ForbiddenFailure).code, 'reauth_required');
            expect(failureMessage(l10n, failure), l10n.errorReauthRequired);
          case 'safe_required':
            expect((failure as ConflictFailure).code, 'safe_required');
          case 'rate_limited':
            expect(failure, isA<RateLimitedFailure>());
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

    test('a missing Idempotency-Key names the header on its field', () async {
      final missing = problems.where((p) {
        final errors = _json(p['response'] as String)['errors'];
        return errors is List &&
            errors.any((f) => (f as Map)['field'] == 'Idempotency-Key');
      });
      for (final problem in missing) {
        final failure = await failureOf(problem) as ValidationFailure;
        expect(failure.fieldErrors.first.field, 'Idempotency-Key');
      }
    });
  });
}

/// `incident_open` -> `incidentOpen`; plain words are unchanged.
String _camel(String snake) {
  final parts = snake.split('_');
  return parts.first +
      parts.skip(1).map((p) => p[0].toUpperCase() + p.substring(1)).join();
}
