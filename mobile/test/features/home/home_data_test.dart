import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/home/data/dio_home_repository.dart';
import 'package:afterme/features/home/data/models/home_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/api_wire.dart';
import '../../helpers/contacts_wire.dart' show always;
import '../../helpers/fake_http_adapter.dart';

Map<String, Object?> _home({
  Object? incident,
  String status = 'active',
  List<Object?> issues = const [],
  Map<String, Object?>? extra,
}) => {
  'server_time': '2026-10-14T13:30:00Z',
  'user': {
    'display_name': 'Diwakar',
    'tier': 'free',
    'timezone': 'Asia/Kolkata',
  },
  'checkin': {
    'status': status,
    'next_due_at': '2026-10-14T14:30:00Z',
    'last_checkin_at': '2026-10-13T14:00:00Z',
    'schedule': {
      'interval_days': 1,
      'due_local_time': '20:00',
      'reminder_lead_minutes': 60,
    },
  },
  'incident': incident,
  'plan_summary': {
    'stages': 2,
    'contacts_total': 3,
    'contacts_verified': 1,
    'instructions_active': 4,
  },
  'readiness': {'ready': issues.isEmpty, 'issues': issues},
  'recent_activity': [
    {'action': 'checkin.recorded', 'occurred_at': '2026-10-13T14:00:00Z'},
    {'action': 'something.new', 'occurred_at': '2026-10-12T14:00:00Z'},
  ],
  ...?extra,
};

void main() {
  Future<(ApiWire, DioHomeRepository)> repo(FakeHandler handler) async {
    final wire = await apiWire(handler);
    return (wire, DioHomeRepository(dio: wire.dio));
  }

  test('GET /v1/home parses the whole aggregate', () async {
    final (wire, home) = await repo(always(FakeReply.json(200, _home())));
    final snapshot = await home.load();
    expect(wire.request.method, 'GET');
    expect(wire.request.path, '/v1/home');
    expect(wire.request.bearer, 'access-1');
    expect(snapshot.serverTime, DateTime.utc(2026, 10, 14, 13, 30));
    expect(snapshot.user.displayName, 'Diwakar');
    expect(snapshot.user.tier, 'free');
    expect(snapshot.user.timezone, 'Asia/Kolkata');
    expect(snapshot.checkin.status, CheckInStatus.active);
    expect(snapshot.checkin.nextDueAt, DateTime.utc(2026, 10, 14, 14, 30));
    expect(snapshot.checkin.lastCheckinAt, DateTime.utc(2026, 10, 13, 14));
    expect(snapshot.checkin.schedule!.dueMinutes, 20 * 60);
    expect(snapshot.checkin.schedule!.reminderLeadMinutes, 60);
    expect(snapshot.incident, isNull);
    expect(snapshot.planSummary.stages, 2);
    expect(snapshot.planSummary.contactsTotal, 3);
    expect(snapshot.planSummary.contactsVerified, 1);
    expect(snapshot.planSummary.instructionsActive, 4);
    expect(snapshot.readiness.ready, isTrue);
    expect(snapshot.recentActivity.map((a) => a.action), [
      'checkin.recorded',
      'something.new',
    ]);
  });

  test('readiness issues keep their contact, and unknown codes are not an '
      'error', () async {
    final (_, home) = await repo(
      always(
        FakeReply.json(
          200,
          _home(
            issues: [
              {'code': 'contact_declined', 'contact_id': 'c-1'},
              {'code': 'schedule_inactive', 'contact_id': null},
              {'code': 'a_code_from_the_future'},
            ],
          ),
        ),
      ),
    );
    final snapshot = await home.load();
    expect(snapshot.readiness.ready, isFalse);
    expect(snapshot.readiness.issues.map((i) => i.code), [
      ReadinessCode.contactDeclined,
      ReadinessCode.scheduleInactive,
      ReadinessCode.unknown,
    ]);
    expect(snapshot.readiness.issues.first.contactId, 'c-1');
    expect(snapshot.readiness.issues[1].contactId, isNull);
  });

  test('every documented readiness code is known', () async {
    const codes = [
      'schedule_inactive',
      'no_contacts',
      'contact_pending',
      'contact_declined',
      'contact_bounced',
      'contact_opted_out',
      'no_stages',
      'stage_empty',
      'release_contact_unverified',
    ];
    final (_, home) = await repo(
      always(
        FakeReply.json(
          200,
          _home(
            issues: [
              for (final c in codes) {'code': c},
            ],
          ),
        ),
      ),
    );
    final snapshot = await home.load();
    expect(
      snapshot.readiness.issues.map((i) => i.code),
      isNot(contains(ReadinessCode.unknown)),
    );
    expect(snapshot.readiness.issues, hasLength(codes.length));
  });

  test('an incident object is kept as an opaque map', () async {
    final (_, home) = await repo(
      always(
        FakeReply.json(
          200,
          _home(
            status: 'incident_open',
            incident: {
              'id': 'i-1',
              'status': 'grace',
              'next_action': {'at': '2026-10-14T17:30:00Z'},
            },
          ),
        ),
      ),
    );
    final snapshot = await home.load();
    expect(snapshot.checkin.status, CheckInStatus.incidentOpen);
    expect(snapshot.incident!['id'], 'i-1');
    expect(snapshot.incident!['next_action'], isA<Map<String, dynamic>>());
  });

  test('an unknown status is unknown, not a crash', () async {
    final (_, home) = await repo(
      always(FakeReply.json(200, _home(status: 'paused'))),
    );
    expect((await home.load()).checkin.status, CheckInStatus.unknown);
  });

  test('missing optional parts get calm defaults', () async {
    final (_, home) = await repo(
      always(
        const FakeReply.json(200, {
          'server_time': '2026-10-14T13:30:00Z',
          'user': {'display_name': 'D', 'timezone': 'UTC'},
          'checkin': {'status': 'inactive'},
        }),
      ),
    );
    final snapshot = await home.load();
    expect(snapshot.user.tier, 'free');
    expect(snapshot.checkin.nextDueAt, isNull);
    expect(snapshot.checkin.lastCheckinAt, isNull);
    expect(snapshot.checkin.schedule, isNull);
    expect(snapshot.incident, isNull);
    expect(snapshot.planSummary, const PlanSummary());
    expect(snapshot.readiness.ready, isFalse);
    expect(snapshot.readiness.issues, isEmpty);
    expect(snapshot.recentActivity, isEmpty);
  });

  group('service.interruption', () {
    Future<HomeSnapshot> load(Map<String, Object?>? extra) async {
      final (_, home) = await repo(
        always(FakeReply.json(200, _home(extra: extra))),
      );
      return home.load();
    }

    test('true while a Hold blocks contact-facing work', () async {
      final snapshot = await load({
        'service': {'interruption': true},
      });
      expect(snapshot.service.interruption, isTrue);
      expect(snapshot.serviceInterruption, isTrue);
    });

    test('false when the server says false', () async {
      final snapshot = await load({
        'service': {'interruption': false},
      });
      expect(snapshot.service.interruption, isFalse);
      expect(snapshot.serviceInterruption, isFalse);
    });

    test('an old server that does not send it means no interruption', () async {
      // `_home` has no `service` at all.
      final snapshot = await load(null);
      expect(snapshot.service, const HomeService());
      expect(snapshot.serviceInterruption, isFalse);
    });

    test('null, an empty object and a null flag are read as false', () async {
      for (final service in <Object?>[
        null,
        <String, Object?>{},
        {'interruption': null},
      ]) {
        final snapshot = await load({'service': service});
        expect(snapshot.serviceInterruption, isFalse, reason: '$service');
        // The rest of the aggregate is still read.
        expect(snapshot.user.displayName, 'Diwakar');
      }
    });

    test('unknown fields are ignored, with the flag on or off', () async {
      final on = await load({
        'service': {
          'interruption': true,
          'reason': 'ingestion',
          'since': '2026-10-14T13:00:00Z',
          'a_field_from_the_future': {'x': 1},
        },
        'another_top_level_thing': [1, 2, 3],
      });
      expect(on.serviceInterruption, isTrue);
      final off = await load({
        'service': {'interruption': false, 'banner': 'maintenance'},
      });
      expect(off.serviceInterruption, isFalse);
    });

    test('only a literal true counts; anything unreadable never breaks '
        'Home', () async {
      for (final service in <Object?>[
        'down',
        7,
        true,
        [true],
        {'interruption': 'true'},
        {'interruption': 1},
        {
          'interruption': [true],
        },
      ]) {
        final snapshot = await load({'service': service});
        expect(snapshot.serviceInterruption, isFalse, reason: '$service');
        expect(snapshot.checkin.status, CheckInStatus.active);
      }
    });
  });

  test('the name never reaches a log', () async {
    final (_, home) = await repo(always(FakeReply.json(200, _home())));
    final snapshot = await home.load();
    expect(snapshot.user.toString(), isNot(contains('Diwakar')));
  });

  test('failures are typed; a damaged body is a failure', () async {
    Future<AppFailure> failureOf(FakeReply reply) async {
      final (_, home) = await repo(always(reply));
      try {
        await home.load();
      } on AppFailure catch (failure) {
        return failure;
      }
      fail('expected a failure');
    }

    expect(
      await failureOf(const FakeReply.networkError()),
      isA<NetworkFailure>(),
    );
    expect(
      await failureOf(FakeReply.problem(401, 'unauthenticated')),
      isA<UnauthorizedFailure>(),
    );
    expect(
      await failureOf(FakeReply.problem(426, 'upgrade_required')),
      isA<UpgradeRequiredFailure>(),
    );
    expect(
      await failureOf(FakeReply.problem(503, 'service_unavailable')),
      isA<ServerFailure>(),
    );
    expect(
      await failureOf(const FakeReply.json(200, <Object?>[])),
      isA<UnknownFailure>(),
    );
    expect(
      await failureOf(const FakeReply.json(200, {'server_time': 'x'})),
      isA<UnknownFailure>(),
    );
    expect(
      await failureOf(
        FakeReply.json(
          200,
          _home(
            extra: {
              'checkin': {
                'status': 'active',
                'schedule': {
                  'interval_days': 1,
                  'due_local_time': '99:99',
                  'reminder_lead_minutes': 60,
                },
              },
            },
          ),
        ),
      ),
      isA<UnknownFailure>(),
    );
  });

  test('a read is retried by the API client', () async {
    final (wire, home) = await repo(
      (request, index) => index == 0
          ? FakeReply.problem(503, 'service_unavailable')
          : FakeReply.json(200, _home()),
    );
    await home.load();
    expect(wire.adapter.requests, hasLength(2));
  });
}
