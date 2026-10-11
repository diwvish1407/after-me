@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/failures/failure_mapper.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/design_system/error_view.dart';
import 'package:afterme/features/activity/data/activity_repository.dart';
import 'package:afterme/features/activity/data/dio_activity_repository.dart';
import 'package:afterme/features/activity/presentation/activity_labels.dart';
import 'package:afterme/features/home/data/models/home_models.dart';
import 'package:afterme/features/incidents/data/dio_incidents_repository.dart';
import 'package:afterme/features/incidents/data/models/incident_models.dart';
import 'package:afterme/features/incidents/presentation/incident_labels.dart';
import 'package:afterme/features/privacy/data/dio_privacy_repository.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/api_wire.dart';
import '../helpers/fake_http_adapter.dart';

/// The backend writes example requests and responses for every Phase 7 endpoint to
/// docs/contracts/phase7 (generated and compared by a backend test). Those files are the
/// source of truth for what is on the wire: the app must send what the golden requests
/// show, read what the golden responses contain, and map every problem file.
///
/// Phase 7's mobile half in this file is the Activity feed (`GET /v1/activity`), the data
/// export (`POST /v1/me/export`, a file download) and the account deletion (`DELETE
/// /v1/me`). The two incident goldens (an incident whose release was viewed, and the same
/// incident closed with the release taken back and its title no longer readable) are the
/// first with a non-empty `releases`; they are read with the incident models of the
/// incident screens.
///
/// The files are in the repository root; `flutter test` runs from `mobile/`. Golden files
/// are read-only here.
final Directory _dir = Directory('../docs/contracts/phase7');

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
      'phase 7 golden files',
      () {},
      skip:
          'docs/contracts/phase7/index.json does not exist yet: the backend '
          'half of Phase 7 writes it (make contracts).',
    );
    return;
  }

  final l10n = AppLocalizationsEn();
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

  test('the index names the contract and covers every Phase 7 endpoint', () {
    expect(index['contract'], 'afterme-phase7');
    expect(index['base_path'], '/v1');
    expect(
      {for (final e in endpoints) route(e)},
      containsAll(<String>[
        'GET /v1/activity?limit=3',
        'GET /v1/activity',
        'POST /v1/me/export',
        'DELETE /v1/me',
        'GET /v1/incidents/current',
        'GET /v1/incidents/{}',
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

  group('activity', () {
    test(
      'the first page: newest first, a cursor, params read as sent',
      () async {
        final e = endpoint('activity_first_page');
        final wire = await apiWire((_, _) => replyFor(e));
        final page = await DioActivityRepository(dio: wire.dio).list(limit: 3);
        final raw = _json(e['response'] as String);
        expect(wire.request.method, 'GET');
        expect(wire.request.path, '/v1/activity');
        expect(wire.request.uri.queryParameters, {'limit': '3'});
        expect(page.nextCursor, raw['next_cursor']);
        expect(
          [for (final item in page.items) item.id],
          [for (final item in raw['items'] as List) (item as Map)['id']],
        );
        expect(page.items.first.action, 'checkin.recorded');
        expect(page.items.first.params, {'kind': 'ok', 'source': 'app'});
        expect(page.items[1].params, isEmpty);
        expect(
          page.items.first.occurredAt,
          DateTime.parse(
            ((raw['items'] as List).first as Map)['occurred_at'] as String,
          ),
        );
      },
    );

    test('the next page sends the cursor and ends the feed', () async {
      final e = endpoint('activity_next_page');
      final wire = await apiWire((_, _) => replyFor(e));
      final page = await DioActivityRepository(dio: wire.dio)
          .list(limit: 3, cursor: 'cursor_example_0001');
      expect(wire.request.uri.queryParameters, {
        'limit': '3',
        'cursor': 'cursor_example_0001',
      });
      expect(page.nextCursor, isNull);
      expect(page.items.map((i) => i.action), [
        'contact.invitation_sent',
        'contact.created',
      ]);
      expect(page.items.first.params['contact_display_name'], 'Mom');
    });

    test('the words of every entry of the goldens, composed by the app', () {
      final first = ActivityPage.fromJson(
        _json('activity_first_page.response.json'),
      );
      final next = ActivityPage.fromJson(
        _json('activity_next_page.response.json'),
      );
      final lines = [
        for (final item in [...first.items, ...next.items])
          describeActivity(l10n, item.action, item.params),
      ];
      expect(lines.map((l) => l.text), [
        'You checked in',
        'Check-ins were turned on',
        'Your plan was updated',
        'An invitation was sent to Mom',
        'You added Mom as a trusted contact',
      ]);
      expect(lines[2].details, ['1 stage in your plan']);
      expect(lines.any((l) => l.text == l10n.activityUnknown), isFalse);
    });

    test('every action in the goldens (the export has the whole feed) is one '
        'the app words', () {
      final export = _json('export.response.json');
      final items = [
        for (final entry in export['activity'] as List)
          ?ActivityItem.tryFromJson(entry),
      ];
      expect(items, hasLength((export['activity'] as List).length));
      for (final item in items) {
        expect(
          describeActivity(l10n, item.action, item.params).text,
          isNot(l10n.activityUnknown),
          reason: item.action,
        );
      }
    });
  });

  group('export', () {
    test('POST asks for bytes, sends no body and no idempotency key', () async {
      final e = endpoint('export');
      final wire = await apiWire((_, _) => replyFor(e));
      final bytes = await DioPrivacyRepository(dio: wire.dio).exportData();
      expect(wire.request.method, 'POST');
      expect(wire.request.path, '/v1/me/export');
      expect(wire.request.data, isNull);
      expect(wire.request.header('Idempotency-Key'), isNull);
      // The file's own content, as bytes: the first and the last character of the JSON.
      final text = utf8.decode(bytes);
      expect(text.trimLeft().startsWith('{'), isTrue);
      expect(jsonDecode(text), _json(e['response'] as String));
      expect(
        _headers(e, 'response_headers')['Content-Disposition'],
        'attachment; filename="afterme-export.json"',
      );
    });

    test('the document is what the app says it is: decrypted titles and '
        'bodies, and the whole feed', () {
      final export = _json('export.response.json');
      expect(export['format_version'], 1);
      expect(export.keys, containsAll(['account', 'contacts', 'instructions']));
      final instruction =
          (export['instructions'] as List).first as Map<String, dynamic>;
      expect(instruction['title'], 'House emergency');
      expect(instruction['body'], isNotEmpty);
      expect(
        export.keys,
        isNot(contains('password')),
        reason: 'nothing that could sign in',
      );
    });
  });

  group('account deletion', () {
    test(
      'DELETE sends exactly the golden body and reads the purge date',
      () async {
        final e = endpoint('account_delete');
        final golden = _json(e['request'] as String);
        final wire = await apiWire((_, _) => replyFor(e));
        final deletion = await DioPrivacyRepository(dio: wire.dio)
            .deleteAccount();
        expect(wire.request.method, 'DELETE');
        expect(wire.request.path, '/v1/me');
        expect(wire.body, golden);
        expect(wire.request.header('Idempotency-Key'), isNull);
        final raw = _json(e['response'] as String);
        expect(raw['status'], 'pending_deletion');
        expect(
          deletion.purgeAfter,
          DateTime.parse(raw['purge_after'] as String),
        );
      },
    );

    test('the app never sends what the server refused', () {
      final refused = _json(
        problem('problem_delete_unconfirmed')['request'] as String,
      );
      expect(refused['confirm'], isNot('DELETE'));
      expect(_json('account_delete.request.json'), {'confirm': 'DELETE'});
    });
  });

  group('problem+json files', () {
    Future<AppFailure> failureOf(Map<String, dynamic> p) async {
      final wire = await apiWire((_, _) => problemReply(p));
      try {
        switch (route(p)) {
          case 'GET /v1/activity':
            await DioActivityRepository(dio: wire.dio)
                .list(limit: 3, cursor: 'not-ours');
          case 'POST /v1/me/export':
            await DioPrivacyRepository(dio: wire.dio).exportData();
          case 'DELETE /v1/me':
            await DioPrivacyRepository(dio: wire.dio).deleteAccount();
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
        {for (final p in problems) p['name']},
        {
          'problem_activity_bad_cursor',
          'problem_reauth_export',
          'problem_reauth_delete',
          'problem_delete_unconfirmed',
          'problem_export_rate_limited',
        },
      );
    });

    test(
      'a fourth export in an hour is a 429 the app reads as rate limited',
      () async {
        final failure = await failureOf(problem('problem_export_rate_limited'));
        expect(failure, isA<RateLimitedFailure>());
      },
    );

    test(
      'a cursor the server did not issue is a field error on `cursor`',
      () async {
        final failure = await failureOf(problem('problem_activity_bad_cursor'));
        expect(failure, isA<ValidationFailure>());
        final errors = (failure as ValidationFailure).fieldErrors;
        expect(errors.single.field, 'cursor');
        expect(errors.single.code, 'invalid');
        expect(failureMessage(l10n, failure), l10n.errorValidation);
      },
    );

    test('the export without a fresh password is 403 reauth_required, read '
        'from a body that arrives as bytes', () async {
      final failure = await failureOf(problem('problem_reauth_export'));
      expect(failure, isA<ForbiddenFailure>());
      expect((failure as ForbiddenFailure).code, 'reauth_required');
      expect(failureMessage(l10n, failure), l10n.errorReauthRequired);
    });

    test(
      'the deletion without a fresh password is 403 reauth_required',
      () async {
        final failure = await failureOf(problem('problem_reauth_delete'));
        expect(failure, isA<ForbiddenFailure>());
        expect((failure as ForbiddenFailure).code, 'reauth_required');
      },
    );

    test(
      'a confirmation that is not DELETE is a field error on `confirm`',
      () async {
        final failure = await failureOf(problem('problem_delete_unconfirmed'));
        expect(failure, isA<ValidationFailure>());
        final errors = (failure as ValidationFailure).fieldErrors;
        expect(errors.single.field, 'confirm');
        expect(errors.single.code, 'invalid_choice');
      },
    );

    test('an action with no queue words a lost answer as "not confirmed" and '
        'a refusal in the app\'s own words', () async {
      for (final p in problems) {
        final golden = _json(p['response'] as String);
        final failure = await failureOf(p);
        for (final action in UnconfirmedAction.values) {
          final message = actionFailureMessage(l10n, failure, action);
          expect(
            message,
            isNot(contains(golden['detail'] as String)),
            reason: '${p['name']} $action: the server\'s text is never shown',
          );
        }
        expect(failure.requestId, golden['request_id']);
      }
    });
  });

  group('the incident\'s releases, as the owner sees them', () {
    Map<String, dynamic> current() =>
        _json('incident_with_release_viewed.response.json')['incident']
            as Map<String, dynamic>;

    test('an incident whose release was viewed once', () {
      final e = endpoint('incident_with_release_viewed');
      expect(e['path'], '/v1/incidents/current');
      final incident = Incident.fromJson(current());
      expect(incident.status, IncidentStatus.escalated);
      expect(incident.requires, IncidentRequires.safe);
      expect(incident.needsSafe, isTrue);
      expect(incident.isOpen, isTrue);
      expect(incident.releases, hasLength(1));
      final release = incident.releases.single;
      expect(release.contactDisplayName, 'Brother');
      expect(release.instructionTitle, 'House emergency');
      expect(release.stagePosition, 2);
      expect(release.viewCount, 1);
      expect(release.wasViewed, isTrue);
      expect(release.isRevoked, isFalse);
      expect(release.revokeReason, isNull);
      expect(release.firstViewedAt, DateTime.utc(2026, 10, 10, 14, 36));
      expect(release.visibleAfter, DateTime.utc(2026, 10, 10, 14, 35));
    });

    test('the same object, read through Home, is the same incident', () {
      final json = current();
      final home = HomeSnapshot.fromJson({
        'server_time': json['server_time'],
        'user': {'display_name': 'Test User', 'timezone': 'Asia/Kolkata'},
        'checkin': {'status': 'incident_open'},
        'incident': json,
      });
      expect(home.incidentDetails, Incident.fromJson(json));
    });

    test('closed by I\'M SAFE: the release is taken back and its title can '
        'no longer be opened (null), read by the real repository', () async {
      final e = endpoint('incident_closed_release_revoked');
      final wire = await apiWire((_, _) => replyFor(e));
      final raw = _json(e['response'] as String);
      final incident = await DioIncidentsRepository(dio: wire.dio)
          .get(raw['id'] as String);
      expect(wire.request.method, 'GET');
      expect(wire.request.path, '/v1/incidents/${raw['id']}');
      expect(incident.status, IncidentStatus.cancelled);
      expect(incident.closedBy, IncidentClosedBy.userSafe);
      expect(incident.isClosed, isTrue);
      expect(incident.requires, isNull);
      final release = incident.releases.single;
      expect(release.instructionTitle, isNull);
      expect(release.isRevoked, isTrue);
      expect(release.revokedAt, DateTime.utc(2026, 10, 10, 14, 36));
      expect(release.revokeReason, ReleaseRevokeReason.userSafe);
      expect(release.wasViewed, isTrue, reason: 'a view cannot be undone');
      expect(
        revokeReasonText(l10n, release.revokeReason),
        l10n.incidentRevokeUserSafe,
      );
    });

    test('both objects have the keys of the incident endpoints', () {
      final closed = _json('incident_closed_release_revoked.response.json');
      expect(closed.keys.toSet(), current().keys.toSet());
    });
  });
}
