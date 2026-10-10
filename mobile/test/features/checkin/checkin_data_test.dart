import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/features/checkin/data/dio_checkin_repository.dart';
import 'package:afterme/features/checkin/data/dio_schedule_repository.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/api_wire.dart';
import '../../helpers/contacts_wire.dart' show always;
import '../../helpers/fake_http_adapter.dart';

Map<String, Object?> _schedule({
  String status = 'active',
  int version = 4,
  String due = '20:00',
  Object? next = '2026-10-14T14:30:00Z',
}) => {
  'interval_days': 1,
  'due_local_time': due,
  'reminder_lead_minutes': 60,
  'timezone': 'Asia/Kolkata',
  'status': status,
  'next_due_at': next,
  'last_checkin_at': '2026-10-13T14:00:00Z',
  'version': version,
};

Map<String, Object?> _result({
  Object? next = '2026-10-15T14:30:00Z',
  bool resolved = false,
}) => {
  'checkin': {'id': 'c-1', 'kind': 'ok', 'received_at': '2026-10-14T13:31:02Z'},
  'next_due_at': next,
  'incident_resolved': resolved,
  'server_time': '2026-10-14T13:31:02Z',
};

void main() {
  group('DioScheduleRepository', () {
    Future<(ApiWire, DioScheduleRepository)> repo(FakeHandler handler) async {
      final wire = await apiWire(handler);
      return (wire, DioScheduleRepository(dio: wire.dio));
    }

    test('GET reads the schedule and its ETag', () async {
      final (wire, schedule) = await repo(
        always(FakeReply.json(200, _schedule(), const {'ETag': '"sched-4"'})),
      );
      final snapshot = await schedule.get();
      expect(wire.request.method, 'GET');
      expect(wire.request.path, '/v1/checkin/schedule');
      expect(wire.request.bearer, 'access-1');
      expect(snapshot.intervalDays, 1);
      expect(snapshot.dueMinutes, 20 * 60);
      expect(snapshot.reminderLeadMinutes, 60);
      expect(snapshot.timezone, 'Asia/Kolkata');
      expect(snapshot.status, CheckInStatus.active);
      expect(snapshot.isOn, isTrue);
      expect(snapshot.nextDueAt, DateTime.utc(2026, 10, 14, 14, 30));
      expect(snapshot.lastCheckinAt, DateTime.utc(2026, 10, 13, 14));
      expect(snapshot.version, 4);
      expect(snapshot.etag, '"sched-4"');
      expect(snapshot.ifMatch, '"sched-4"');
      expect(
        snapshot.settings,
        const CheckInSchedule(
          intervalDays: 1,
          dueMinutes: 1200,
          reminderLeadMinutes: 60,
          timezone: 'Asia/Kolkata',
        ),
      );
    });

    test('without an ETag header the version names it', () async {
      final (_, schedule) = await repo(
        always(FakeReply.json(200, _schedule(version: 7))),
      );
      final snapshot = await schedule.get();
      expect(snapshot.etag, isNull);
      expect(snapshot.ifMatch, '"sched-7"');
    });

    test('an inactive schedule has no next deadline', () async {
      final (_, schedule) = await repo(
        always(FakeReply.json(200, _schedule(status: 'inactive', next: null))),
      );
      final snapshot = await schedule.get();
      expect(snapshot.status, CheckInStatus.inactive);
      expect(snapshot.isOn, isFalse);
      expect(snapshot.nextDueAt, isNull);
    });

    test('a status from a newer server is unknown, not an error', () async {
      final (_, schedule) = await repo(
        always(FakeReply.json(200, _schedule(status: 'paused'))),
      );
      final snapshot = await schedule.get();
      expect(snapshot.status, CheckInStatus.unknown);
      expect(snapshot.isOn, isFalse);
    });

    test('an incident-open status is on', () async {
      final (_, schedule) = await repo(
        always(FakeReply.json(200, _schedule(status: 'incident_open'))),
      );
      expect((await schedule.get()).isOn, isTrue);
    });

    test('PUT sends If-Match and only the three chosen values', () async {
      final (wire, schedule) = await repo(
        always(
          FakeReply.json(200, _schedule(version: 5), const {
            'ETag': '"sched-5"',
          }),
        ),
      );
      final saved = await schedule.save(
        const CheckInSchedule(
          intervalDays: 3,
          dueMinutes: 21 * 60 + 5,
          reminderLeadMinutes: 30,
          timezone: 'Asia/Kolkata',
        ),
        ifMatch: '"sched-4"',
      );
      expect(wire.request.method, 'PUT');
      expect(wire.request.path, '/v1/checkin/schedule');
      expect(wire.request.header('If-Match'), '"sched-4"');
      expect(wire.body, {
        'interval_days': 3,
        'due_local_time': '21:05',
        'reminder_lead_minutes': 30,
      });
      expect(saved.etag, '"sched-5"');
      expect(saved.version, 5);
    });

    test('activate and deactivate are bodiless POSTs', () async {
      var (wire, schedule) = await repo(
        always(FakeReply.json(200, _schedule(), const {'ETag': '"sched-5"'})),
      );
      var snapshot = await schedule.activate();
      expect(wire.request.method, 'POST');
      expect(wire.request.path, '/v1/checkin/activate');
      expect(wire.request.data, isNull);
      expect(snapshot.etag, '"sched-5"');

      (wire, schedule) = await repo(
        always(
          FakeReply.json(200, _schedule(status: 'inactive', next: null), const {
            'ETag': '"sched-6"',
          }),
        ),
      );
      snapshot = await schedule.deactivate();
      expect(wire.request.path, '/v1/checkin/deactivate');
      expect(wire.request.data, isNull);
      expect(snapshot.status, CheckInStatus.inactive);
    });

    test('409 activation_requirements_unmet lists what is missing', () async {
      final (_, schedule) = await repo(
        always(
          FakeReply.problem(
            409,
            'activation_requirements_unmet',
            extra: {
              'requirements': ['no_contacts', 'something_new'],
            },
          ),
        ),
      );
      await expectLater(
        schedule.activate(),
        throwsA(
          isA<ActivationRequirementsFailure>().having(
            (f) => f.requirements,
            'requirements',
            ['no_contacts', 'something_new'],
          ),
        ),
      );
    });

    test(
      '409 activation_requirements_unmet without a list still maps',
      () async {
        final (_, schedule) = await repo(
          always(FakeReply.problem(409, 'activation_requirements_unmet')),
        );
        await expectLater(
          schedule.activate(),
          throwsA(
            isA<ActivationRequirementsFailure>().having(
              (f) => f.requirements,
              'requirements',
              isEmpty,
            ),
          ),
        );
      },
    );

    test('the documented errors become typed failures', () async {
      Future<AppFailure> failureOf(FakeReply reply, {bool save = true}) async {
        final (_, schedule) = await repo(always(reply));
        try {
          if (save) {
            await schedule.save(const CheckInSchedule(), ifMatch: '"sched-1"');
          } else {
            await schedule.deactivate();
          }
        } on AppFailure catch (failure) {
          return failure;
        }
        fail('expected a failure');
      }

      var failure = await failureOf(
        FakeReply.problem(412, 'precondition_failed'),
      );
      expect(failure, isA<ConflictFailure>());
      expect((failure as ConflictFailure).code, 'precondition_failed');

      failure = await failureOf(
        FakeReply.problem(428, 'precondition_required'),
      );
      expect((failure as ConflictFailure).code, 'precondition_required');

      failure = await failureOf(FakeReply.problem(409, 'incident_open'));
      expect((failure as ConflictFailure).code, 'incident_open');

      failure = await failureOf(
        FakeReply.problem(
          422,
          'validation_failed',
          extra: {
            'errors': [
              {'field': 'interval_days', 'code': 'too_small', 'message': 'x'},
            ],
          },
        ),
      );
      expect(
        (failure as ValidationFailure).fieldErrors.single.field,
        'interval_days',
      );

      failure = await failureOf(
        FakeReply.problem(403, 'reauth_required'),
        save: false,
      );
      expect((failure as ForbiddenFailure).code, 'reauth_required');
    });

    test('changes are not retried automatically', () async {
      final (wire, schedule) = await repo(
        always(FakeReply.problem(503, 'service_unavailable')),
      );
      await expectLater(
        schedule.save(const CheckInSchedule(), ifMatch: '"sched-1"'),
        throwsA(isA<ServerFailure>()),
      );
      expect(wire.adapter.requests, hasLength(1));
    });

    test('reads are retried by the API client', () async {
      final (wire, schedule) = await repo(
        (request, index) => index == 0
            ? const FakeReply.networkError()
            : FakeReply.json(200, _schedule()),
      );
      expect((await schedule.get()).version, 4);
      expect(wire.adapter.requests, hasLength(2));
    });

    test('a damaged body is a failure, never a half-read schedule', () async {
      for (final reply in [
        FakeReply.json(200, _schedule(due: '25:99')),
        FakeReply.json(200, _schedule(due: '8pm')),
        const FakeReply.json(200, <String, Object?>{'version': 1}),
        const FakeReply.json(200, <Object?>['not', 'an', 'object']),
        const FakeReply.raw(200, '<html>', 'text/html'),
      ]) {
        final (_, schedule) = await repo(always(reply));
        await expectLater(schedule.get(), throwsA(isA<AppFailure>()));
      }
    });

    test('local time helpers', () {
      expect(parseLocalTime('00:00'), 0);
      expect(parseLocalTime('23:59'), 23 * 60 + 59);
      expect(() => parseLocalTime('24:00'), throwsFormatException);
      expect(() => parseLocalTime('7:00'), throwsFormatException);
      expect(formatLocalTime(0), '00:00');
      expect(formatLocalTime(20 * 60 + 5), '20:05');
      expect(formatLocalTime(1440 + 90), '01:30');
      expect(formatLocalTime(-60), '23:00');
    });
  });

  group('DioCheckInRepository', () {
    Future<(ApiWire, DioCheckInRepository)> repo(FakeHandler handler) async {
      final wire = await apiWire(handler);
      return (wire, DioCheckInRepository(dio: wire.dio));
    }

    test('POST /checkins carries the key and the informational time', () async {
      final (wire, checkins) = await repo(
        always(FakeReply.json(200, _result())),
      );
      final result = await checkins.checkIn(
        idempotencyKey: 'tap-key-0000000001',
        clientReportedAt: DateTime.utc(2026, 10, 14, 13, 30, 59, 123, 456),
      );
      expect(wire.request.method, 'POST');
      expect(wire.request.path, '/v1/checkins');
      expect(wire.request.header('Idempotency-Key'), 'tap-key-0000000001');
      expect(wire.body, {'client_reported_at': '2026-10-14T13:30:59Z'});
      expect(wire.request.bearer, 'access-1');
      expect(result.checkin.id, 'c-1');
      expect(result.checkin.kind, CheckInKind.ok);
      expect(result.checkin.receivedAt, DateTime.utc(2026, 10, 14, 13, 31, 2));
      expect(result.nextDueAt, DateTime.utc(2026, 10, 15, 14, 30));
      expect(result.incidentResolved, isFalse);
      expect(result.serverTime, DateTime.utc(2026, 10, 14, 13, 31, 2));
    });

    test('a local time is sent as the same instant in UTC', () async {
      final (wire, checkins) = await repo(
        always(FakeReply.json(200, _result())),
      );
      await checkins.checkIn(
        idempotencyKey: 'tap-key-0000000001',
        clientReportedAt: DateTime.parse('2026-10-14T19:00:59+05:30'),
      );
      expect(wire.body['client_reported_at'], '2026-10-14T13:30:59Z');
    });

    test('next_due_at is null while the schedule is inactive; an incident '
        'can be resolved', () async {
      final (_, checkins) = await repo(
        always(FakeReply.json(200, _result(next: null, resolved: true))),
      );
      final result = await checkins.checkIn(
        idempotencyKey: 'tap-key-0000000001',
      );
      expect(result.nextDueAt, isNull);
      expect(result.incidentResolved, isTrue);
    });

    test(
      'the same key is sent again after a dropped connection and a 503',
      () async {
        final (wire, checkins) = await repo(
          (request, index) => switch (index) {
            0 => const FakeReply.networkError(),
            1 => FakeReply.problem(503, 'service_unavailable'),
            _ => FakeReply.json(200, _result()),
          },
        );
        await checkins.checkIn(idempotencyKey: 'tap-key-0000000001');
        expect(wire.adapter.requests, hasLength(3));
        expect(
          {for (final r in wire.adapter.requests) r.header('Idempotency-Key')},
          {'tap-key-0000000001'},
        );
      },
    );

    test('safe_required, rate limit, validation and server errors', () async {
      Future<AppFailure> failureOf(FakeReply reply) async {
        final (_, checkins) = await repo(always(reply));
        try {
          await checkins.checkIn(idempotencyKey: 'tap-key-0000000001');
        } on AppFailure catch (failure) {
          return failure;
        }
        fail('expected a failure');
      }

      var failure = await failureOf(FakeReply.problem(409, 'safe_required'));
      expect((failure as ConflictFailure).code, 'safe_required');

      failure = await failureOf(
        FakeReply.problem(
          429,
          'rate_limited',
          headers: const {'Retry-After': '1200'},
        ),
      );
      expect(
        (failure as RateLimitedFailure).retryAfter,
        const Duration(minutes: 20),
      );

      failure = await failureOf(
        FakeReply.problem(
          422,
          'validation_failed',
          extra: {
            'errors': [
              {'field': 'Idempotency-Key', 'code': 'required'},
            ],
          },
        ),
      );
      expect(failure, isA<ValidationFailure>());

      failure = await failureOf(FakeReply.problem(503, 'service_unavailable'));
      expect(failure, isA<ServerFailure>());

      failure = await failureOf(const FakeReply.networkError());
      expect(failure, isA<NetworkFailure>());
    });

    test(
      'a 200 whose body cannot be read is not a confirmed check-in',
      () async {
        for (final reply in [
          const FakeReply.json(200, <String, Object?>{'checkin': 1}),
          const FakeReply.raw(200, 'ok', 'text/plain'),
          const FakeReply.json(200, <Object?>[]),
        ]) {
          final (_, checkins) = await repo(always(reply));
          await expectLater(
            checkins.checkIn(idempotencyKey: 'tap-key-0000000001'),
            throwsA(isA<AppFailure>()),
          );
        }
      },
    );

    test('history sends limit and cursor and keeps the server order', () async {
      final (wire, checkins) = await repo(
        always(
          const FakeReply.json(200, {
            'items': [
              {
                'id': 'a',
                'kind': 'ok',
                'source': 'app',
                'received_at': '2026-10-14T13:31:02Z',
              },
              {
                'id': 'b',
                'kind': 'safe',
                'source': 'web',
                'received_at': '2026-10-13T13:31:02Z',
              },
              {
                'id': 'c',
                'kind': 'future_kind',
                'source': 'future_source',
                'received_at': '2026-10-12T13:31:02Z',
              },
            ],
            'next_cursor': 'opaque-1',
          }),
        ),
      );
      final page = await checkins.history(limit: 3, cursor: 'opaque-0');
      expect(wire.request.method, 'GET');
      expect(wire.request.path, '/v1/checkins');
      expect(wire.request.uri.queryParameters, {
        'limit': '3',
        'cursor': 'opaque-0',
      });
      expect(page.items.map((i) => i.id), ['a', 'b', 'c']);
      expect(page.items[0].source, CheckInSource.app);
      expect(page.items[1].kind, CheckInKind.safe);
      expect(page.items[1].source, CheckInSource.web);
      expect(page.items[2].kind, CheckInKind.unknown);
      expect(page.items[2].source, CheckInSource.unknown);
      expect(page.nextCursor, 'opaque-1');
    });

    test('history without a cursor omits it and ends with null', () async {
      final (wire, checkins) = await repo(
        always(
          const FakeReply.json(200, <String, Object?>{
            'items': <Object?>[],
            'next_cursor': null,
          }),
        ),
      );
      final page = await checkins.history();
      expect(wire.request.uri.queryParameters, {'limit': '20'});
      expect(page.items, isEmpty);
      expect(page.nextCursor, isNull);
    });
  });
}
