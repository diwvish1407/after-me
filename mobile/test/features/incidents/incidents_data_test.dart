import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/features/incidents/data/dio_incidents_repository.dart';
import 'package:afterme/features/incidents/data/incidents_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/api_wire.dart';
import '../../helpers/contacts_wire.dart' show always;
import '../../helpers/fake_http_adapter.dart';
import '../../helpers/incident_fixtures.dart';

Map<String, Object?> _safe({Object? next = '2026-10-10T14:30:00Z'}) => {
  'status': 'cancelled',
  'incident_id': incidentId,
  'all_clear_sent_to': [
    {'contact_id': momId, 'display_name': 'Mom'},
  ],
  'next_due_at': next,
  'server_time': '2026-10-09T17:37:20Z',
};

void main() {
  Future<(ApiWire, DioIncidentsRepository)> repo(FakeHandler handler) async {
    final wire = await apiWire(handler);
    return (wire, DioIncidentsRepository(dio: wire.dio));
  }

  group('GET /v1/incidents', () {
    test('asks for a page and reads the cursor', () async {
      final (wire, incidents) = await repo(
        always(
          const FakeReply.json(200, {
            'items': [
              {
                'id': 'i-1',
                'status': 'cancelled',
                'missed_due_at': '2026-10-09T14:30:00Z',
                'opened_at': '2026-10-09T14:30:01Z',
                'closed_at': '2026-10-09T17:37:20Z',
                'closed_by': 'user_safe',
                'contacts_messaged': true,
              },
            ],
            'next_cursor': 'next-page',
          }),
        ),
      );
      final page = await incidents.list(limit: 20);
      expect(wire.request.method, 'GET');
      expect(wire.request.path, '/v1/incidents');
      expect(wire.request.uri.queryParameters, {'limit': '20'});
      expect(wire.request.bearer, 'access-1');
      expect(page.items.single.closedBy, IncidentClosedBy.userSafe);
      expect(page.nextCursor, 'next-page');
    });

    test('follows the cursor', () async {
      final (wire, incidents) = await repo(
        always(
          const FakeReply.json(200, {'items': <Object>[], 'next_cursor': null}),
        ),
      );
      final page = await incidents.list(limit: 5, cursor: 'abc');
      expect(wire.request.uri.queryParameters, {'limit': '5', 'cursor': 'abc'});
      expect(page.items, isEmpty);
      expect(page.nextCursor, isNull);
    });
  });

  group('GET /v1/incidents/{id}', () {
    test('reads the incident', () async {
      final (wire, incidents) = await repo(
        always(FakeReply.json(200, escalatedJson())),
      );
      final incident = await incidents.get(incidentId);
      expect(wire.request.path, '/v1/incidents/$incidentId');
      expect(incident.needsSafe, isTrue);
    });

    test('an id is escaped into the path', () async {
      final (wire, incidents) = await repo(
        always(FakeReply.json(200, incidentJson())),
      );
      await incidents.get('a/b c');
      expect(wire.request.path, '/v1/incidents/a%2Fb%20c');
    });

    test('a stranger\'s id is a not found failure', () async {
      final (_, incidents) = await repo(
        always(FakeReply.problem(404, 'not_found')),
      );
      await expectLater(incidents.get('x'), throwsA(isA<NotFoundFailure>()));
    });

    test('a body that is not an incident is an unknown failure', () async {
      final (_, incidents) = await repo(
        always(const FakeReply.json(200, {'id': 'i-1'})),
      );
      await expectLater(incidents.get('i-1'), throwsA(isA<UnknownFailure>()));
      final (_, other) = await repo(always(const FakeReply.json(200, [1, 2])));
      await expectLater(other.get('i-1'), throwsA(isA<UnknownFailure>()));
    });
  });

  group('POST /v1/incidents/{id}/safe', () {
    test('sends the key and no body, and reads who is told', () async {
      final (wire, incidents) = await repo(
        always(FakeReply.json(200, _safe())),
      );
      final result = await incidents.markSafe(
        incidentId,
        idempotencyKey: '00000000-0000-4000-8000-000000000006',
      );
      expect(wire.request.method, 'POST');
      expect(wire.request.path, '/v1/incidents/$incidentId/safe');
      expect(
        wire.request.header('Idempotency-Key'),
        '00000000-0000-4000-8000-000000000006',
      );
      expect(wire.request.data, isNull);
      expect(result.incidentId, incidentId);
      expect(result.allClearSentTo.single.displayName, 'Mom');
      expect(result.nextDueAt, DateTime.utc(2026, 10, 10, 14, 30));
    });

    test('a dropped connection is retried with the same key', () async {
      final (wire, incidents) = await repo(
        (request, call) => call == 0
            ? const FakeReply.networkError()
            : FakeReply.json(200, _safe()),
      );
      await incidents.markSafe(incidentId, idempotencyKey: 'my-own-key-0001');
      expect(wire.adapter.requests, hasLength(2));
      expect(
        {for (final r in wire.adapter.requests) r.header('Idempotency-Key')},
        {'my-own-key-0001'},
      );
    });

    test('a 2xx without a readable body is not "marked safe"', () async {
      final (_, incidents) = await repo(
        always(const FakeReply.json(200, {'status': 'cancelled'})),
      );
      await expectLater(
        incidents.markSafe(incidentId, idempotencyKey: 'my-own-key-0001'),
        throwsA(isA<UnknownFailure>()),
      );
    });

    test('the refusals keep their codes', () async {
      final (_, reauth) = await repo(
        always(FakeReply.problem(403, 'reauth_required')),
      );
      await expectLater(
        reauth.markSafe(incidentId, idempotencyKey: 'my-own-key-0001'),
        throwsA(
          isA<ForbiddenFailure>().having(
            (f) => f.code,
            'code',
            'reauth_required',
          ),
        ),
      );
      final (_, closed) = await repo(
        always(FakeReply.problem(409, 'invalid_state')),
      );
      await expectLater(
        closed.markSafe(incidentId, idempotencyKey: 'my-own-key-0001'),
        throwsA(isA<InvalidStateFailure>()),
      );
    });
  });
}
