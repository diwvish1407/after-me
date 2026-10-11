import 'package:afterme/features/home/data/models/home_models.dart';
import 'package:afterme/features/incidents/application/incident_events.dart';
import 'package:afterme/features/incidents/data/incidents_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/incident_fixtures.dart';

Map<String, dynamic> _home(Object? incident) => {
  'server_time': '2026-10-09T14:30:41Z',
  'user': {'display_name': 'Test User', 'timezone': 'Asia/Kolkata'},
  'checkin': {'status': 'incident_open'},
  'incident': incident,
};

void main() {
  group('Incident', () {
    test('reads the grace object of the contract', () {
      final incident = parsed(incidentJson());
      expect(incident.id, incidentId);
      expect(incident.status, IncidentStatus.grace);
      expect(incident.requires, IncidentRequires.checkin);
      expect(incident.missedDueAt, missedDue);
      expect(incident.anchorAt, anchor);
      expect(incident.graceEndsAt, graceEnds);
      expect(incident.contactsMessaged, isFalse);
      expect(incident.closedAt, isNull);
      expect(incident.closedBy, isNull);
      expect(incident.releases, isEmpty);
      expect(incident.timeline, hasLength(4));
      expect(incident.isOpen, isTrue);
      expect(incident.needsSafe, isFalse);

      final reminder = incident.timeline.first;
      expect(reminder.kind, TimelineKind.userReminder);
      expect(reminder.variant, TimelineVariant.missed);
      expect(reminder.status, TimelineStatus.executed);
      expect(reminder.contacts, isNull);
      expect(reminder.releaseCount, isNull);

      final stage = incident.timeline.last;
      expect(stage.isStage, isTrue);
      expect(stage.stagePosition, 1);
      expect(stage.status, TimelineStatus.pending);
      expect(stage.contacts!.single.displayName, 'Mom');
      expect(stage.contacts!.single.result, isNull);
      expect(stage.releaseCount, 0);
      expect(incident.nextStage, stage);
    });

    test('reads an escalated incident with a viewed release', () {
      final incident = parsed(
        escalatedJson(
          stage2Ran: true,
          releases: [
            releaseJson(
              firstViewedAt: DateTime.utc(2026, 10, 10, 14, 50, 5),
              lastViewedAt: DateTime.utc(2026, 10, 10, 15, 10),
              viewCount: 3,
            ),
          ],
        ),
      );
      expect(incident.status, IncidentStatus.escalated);
      expect(incident.requires, IncidentRequires.safe);
      expect(incident.needsSafe, isTrue);
      expect(incident.contactsMessaged, isTrue);
      expect(incident.notifiedContacts.map((c) => c.displayName), [
        'Mom',
        'Brother',
      ]);
      expect(incident.nextStage, isNull, reason: 'every stage has run');
      final release = incident.releases.single;
      expect(release.contactDisplayName, 'Brother');
      expect(release.instructionTitle, 'House emergency');
      expect(release.stagePosition, 2);
      expect(release.wasViewed, isTrue);
      expect(release.viewCount, 3);
      expect(release.isRevoked, isFalse);
      expect(release.revokeReason, isNull);
    });

    test('a closed incident says how it closed', () {
      final incident = parsed(
        incidentJson(
          status: 'cancelled',
          requires: null,
          contactsMessaged: true,
          closedAt: DateTime.utc(2026, 10, 9, 17, 37, 20),
          closedBy: 'user_safe',
        ),
      );
      expect(incident.isClosed, isTrue);
      expect(incident.isOpen, isFalse);
      expect(incident.requires, isNull);
      expect(incident.closedBy, IncidentClosedBy.userSafe);
    });

    test('the next stage is the earliest one that has not run', () {
      final incident = parsed(
        incidentJson(
          status: 'escalating',
          timeline: [
            stageJson(3, DateTime.utc(2026, 10, 12, 14), status: 'pending'),
            stageJson(2, DateTime.utc(2026, 10, 11, 14), status: 'held'),
            stageJson(1, DateTime.utc(2026, 10, 10, 14), status: 'executed'),
          ],
        ),
      );
      expect(incident.nextStage!.stagePosition, 2);
      expect(incident.nextStage!.status, TimelineStatus.held);
    });
  });

  group('values from a newer server', () {
    test('an unknown value never throws and never claims anything', () {
      final json = incidentJson(
        status: 'paused',
        requires: 'review',
        closedBy: 'robot',
        timeline: [
          {
            ...reminderJson('missed', anchor),
            'kind': 'push_nudge',
            'variant': 'someday',
            'status': 'snoozed',
          },
          stageJson(
            1,
            graceEnds,
            contacts: [contactJson(momId, 'Mom', result: 'bounced')],
          ),
        ],
        releases: [releaseJson(revokeReason: 'solar_flare')],
      );
      final incident = parsed(json);
      expect(incident.status, IncidentStatus.unknown);
      expect(incident.requires, IncidentRequires.unknown);
      expect(incident.closedBy, IncidentClosedBy.unknown);
      final first = incident.timeline.first;
      expect(first.kind, TimelineKind.unknown);
      expect(first.variant, TimelineVariant.unknown);
      expect(first.status, TimelineStatus.unknown);
      expect(
        incident.timeline.last.contacts!.single.result,
        ContactResult.unknown,
      );
      expect(
        incident.timeline.last.messagedContacts,
        isEmpty,
        reason: 'an unknown result is not "notified"',
      );
      expect(
        incident.releases.single.revokeReason,
        ReleaseRevokeReason.unknown,
      );
      // Not closed: the server did not say so.
      expect(incident.isClosed, isFalse);
      expect(incident.isOpen, isTrue);
      expect(incident.notifiedContacts, isEmpty);
      // An unknown event kind still has a line.
      expect(
        incidentEvents(incident).map((e) => e.kind),
        contains(IncidentEventKind.other),
      );
    });

    test('an unknown `requires` follows contacts_messaged', () {
      expect(
        parsed(incidentJson(requires: 'review')).needsSafe,
        isFalse,
        reason: 'nobody was told',
      );
      expect(
        parsed(incidentJson(requires: 'review', contactsMessaged: true))
            .needsSafe,
        isTrue,
      );
      expect(
        parsed(incidentJson(requires: null, contactsMessaged: true)).needsSafe,
        isTrue,
      );
    });

    test('unknown fields are ignored', () {
      final json = incidentJson()..['next_action'] = {'at': 'later'};
      expect(parsed(json).id, incidentId);
    });
  });

  group('missing and null parts', () {
    test('no releases key, no titles, no counts, no contacts', () {
      final json = incidentJson(
        status: 'escalating',
        requires: 'safe',
        contactsMessaged: true,
        timeline: [
          {
            'kind': 'execute_stage',
            'scheduled_for': iso(graceEnds),
            'status': 'executed',
          },
        ],
        releases: [releaseJson(title: null)],
      )..remove('releases');
      final incident = parsed(json);
      expect(incident.releases, isEmpty);
      final item = incident.timeline.single;
      expect(item.contacts, isNull);
      expect(item.messagedContacts, isEmpty);
      expect(item.releaseCount, isNull);
      expect(item.stagePosition, isNull);
      expect(item.variant, isNull);

      final withRelease = parsed(
        incidentJson(releases: [releaseJson(title: null)]),
      );
      expect(withRelease.releases.single.instructionTitle, isNull);
      expect(withRelease.releases.single.viewCount, 0);
      expect(withRelease.releases.single.wasViewed, isFalse);
    });

    test('a release that was viewed has a view even without a time', () {
      final json = incidentJson(
        releases: [
          {...releaseJson(), 'view_count': 2},
        ],
      );
      expect(parsed(json).releases.single.wasViewed, isTrue);
    });

    test('tryFromJson is null for something that is not an incident', () {
      expect(Incident.tryFromJson(null), isNull);
      expect(Incident.tryFromJson({'id': 'i-1'}), isNull);
      expect(Incident.tryFromJson(incidentJson()), isNotNull);
    });
  });

  group('the timeline in order', () {
    test('times as the server gives them, views and take-backs among them', () {
      final incident = parsed(
        escalatedJson(
          stage2Ran: true,
          releases: [
            // Viewed, but the server gave only a count.
            {...releaseJson(), 'view_count': 2},
            releaseJson(
              instructionId: '00000000-0000-4000-8000-000000000021',
              firstViewedAt: DateTime.utc(2026, 10, 10, 14, 50),
              revokedAt: DateTime.utc(2026, 10, 10, 15),
              revokeReason: 'user_safe',
              viewCount: 1,
            ),
          ],
        ),
      );
      final events = incidentEvents(incident);
      final times = [for (final e in events) e.at];
      expect([...times]..sort(), times);
      expect(
        events
            .map((e) => e.kind)
            .where(
              (k) =>
                  k == IncidentEventKind.viewed ||
                  k == IncidentEventKind.revoked,
            ),
        [
          IncidentEventKind.viewed,
          IncidentEventKind.viewed,
          IncidentEventKind.revoked,
        ],
      );
      // A view without a time is put where the release happened, not later.
      final viewed = events.firstWhere(
        (e) => e.kind == IncidentEventKind.viewed,
      );
      expect(viewed.at, DateTime.utc(2026, 10, 10, 14, 30, 1));
    });

    test('a closed incident ends with how it ended', () {
      final incident = parsed(
        incidentJson(
          status: 'cancelled',
          requires: null,
          closedAt: DateTime.utc(2026, 10, 9, 17, 37, 20),
          closedBy: 'user_safe',
        ),
      );
      final events = incidentEvents(incident);
      expect(events.last.kind, IncidentEventKind.closed);
      expect(events.last.at, DateTime.utc(2026, 10, 9, 17, 37, 20));
    });

    test('entries at the same time keep the order the server gave', () {
      final at = DateTime.utc(2026, 10, 9, 15);
      final incident = parsed(
        incidentJson(
          timeline: [
            stageJson(2, at, contacts: [contactJson(brotherId, 'Brother')]),
            reminderJson('midpoint', at, status: 'pending'),
          ],
        ),
      );
      expect(incidentEvents(incident).map((e) => e.kind), [
        IncidentEventKind.stage,
        IncidentEventKind.reminder,
      ]);
    });
  });

  group('summaries and results', () {
    test('a history row and its page', () {
      final page = IncidentPage.fromJson({
        'items': [
          {
            'id': 'i-2',
            'status': 'resolved',
            'missed_due_at': '2026-10-10T14:30:00Z',
            'opened_at': '2026-10-10T14:30:01Z',
            'closed_at': '2026-10-10T14:30:21Z',
            'closed_by': 'user_checkin',
            'contacts_messaged': false,
          },
          {
            'id': 'i-1',
            'status': 'brand_new',
            'missed_due_at': '2026-10-09T14:30:00Z',
            'opened_at': '2026-10-09T14:30:01Z',
            'closed_at': null,
            'closed_by': 'future_value',
            'contacts_messaged': true,
          },
        ],
        'next_cursor': 'abc',
      });
      expect(page.nextCursor, 'abc');
      expect(page.items.first.closedBy, IncidentClosedBy.userCheckin);
      expect(page.items.first.isClosed, isTrue);
      expect(page.items.last.status, IncidentStatus.unknown);
      expect(page.items.last.closedBy, IncidentClosedBy.unknown);
      expect(page.items.last.isClosed, isFalse);
      expect(IncidentPage.fromJson({}).items, isEmpty);
    });

    test('the I\'M SAFE answer', () {
      final result = SafeResult.fromJson({
        'status': 'cancelled',
        'incident_id': incidentId,
        'all_clear_sent_to': [
          {'contact_id': momId, 'display_name': 'Mom'},
        ],
        'next_due_at': '2026-10-10T14:30:00Z',
        'server_time': '2026-10-09T17:37:20Z',
      });
      expect(result.incidentId, incidentId);
      expect(result.allClearSentTo.single.displayName, 'Mom');
      expect(result.nextDueAt, DateTime.utc(2026, 10, 10, 14, 30));
      expect(
        SafeResult.fromJson({
          'incident_id': incidentId,
          'next_due_at': null,
          'server_time': '2026-10-09T17:37:20Z',
        }).allClearSentTo,
        isEmpty,
      );
    });
  });

  group('names never reach a log', () {
    test('printing any incident model hides names and titles', () {
      final incident = parsed(
        escalatedJson(
          stage2Ran: true,
          releases: [
            releaseJson(firstViewedAt: DateTime.utc(2026, 10, 10, 15)),
          ],
        ),
      );
      final result = SafeResult.fromJson({
        'incident_id': incidentId,
        'all_clear_sent_to': [
          {'contact_id': momId, 'display_name': 'Mom'},
        ],
        'server_time': '2026-10-09T17:37:20Z',
      });
      final printed = [
        '$incident',
        '${incident.timeline}',
        '${incident.timeline.last.contacts}',
        '${incident.releases}',
        '$result',
        '${result.allClearSentTo}',
      ].join(' | ');
      for (final secret in ['Mom', 'Brother', 'House emergency']) {
        expect(printed, isNot(contains(secret)));
      }
      expect(incident.toString(), 'Incident(<redacted>)');
    });

    test('printing the Home aggregate hides the incident and the name', () {
      final home = HomeSnapshot.fromJson(_home(escalatedJson()));
      expect(home.toString(), isNot(contains('Brother')));
      expect(home.toString(), isNot(contains('Test User')));
    });
  });

  group('HomeSnapshot.incidentDetails', () {
    test('is the typed incident, and the raw object is kept', () {
      final home = HomeSnapshot.fromJson(_home(incidentJson()));
      expect(home.hasIncident, isTrue);
      expect(home.incident!['id'], incidentId);
      expect(home.incidentDetails!.status, IncidentStatus.grace);
    });

    test('is null without an incident', () {
      final home = HomeSnapshot.fromJson(_home(null));
      expect(home.hasIncident, isFalse);
      expect(home.incidentDetails, isNull);
    });

    test('an object this version cannot read still counts as an incident', () {
      final home = HomeSnapshot.fromJson(_home({'id': 'i-1'}));
      expect(home.hasIncident, isTrue);
      expect(home.incidentDetails, isNull);
    });
  });
}
