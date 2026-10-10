import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/home/application/home_status.dart';
import 'package:afterme/features/home/data/models/home_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/home_fixtures.dart';

void main() {
  final now = DateTime.utc(2026, 10, 8, 12);

  group('homeStatus (USER_FLOWS §4)', () {
    test('inactive is Not active', () {
      expect(
        homeStatus(
          homeSnapshot(status: CheckInStatus.inactive),
          serverNow: now,
        ),
        HomeStatus.notActive,
      );
    });

    test('active and not near the deadline is Active', () {
      expect(
        homeStatus(
          homeSnapshot(nextDueAt: now.add(const Duration(hours: 5))),
          serverNow: now,
        ),
        HomeStatus.active,
      );
    });

    test('active without a deadline is still Active', () {
      expect(homeStatus(homeSnapshot(), serverNow: now), HomeStatus.active);
    });

    test(
      'within the reminder lead is Due soon (the boundary is inclusive)',
      () {
        final snapshot = homeSnapshot(
          nextDueAt: now.add(const Duration(minutes: 60)),
        );
        expect(
          homeStatus(snapshot, serverNow: now),
          HomeStatus.dueSoon,
          reason: 'exactly at the lead',
        );
        expect(
          homeStatus(
            snapshot,
            serverNow: now.subtract(const Duration(seconds: 1)),
          ),
          HomeStatus.active,
          reason: 'a second before the lead begins',
        );
        expect(
          homeStatus(snapshot, serverNow: now.add(const Duration(minutes: 59))),
          HomeStatus.dueSoon,
        );
      },
    );

    test('the lead follows the schedule: 30 minutes, 4 hours', () {
      final due = now.add(const Duration(hours: 3));
      expect(
        homeStatus(
          homeSnapshot(nextDueAt: due, reminderLeadMinutes: 30),
          serverNow: now,
        ),
        HomeStatus.active,
      );
      expect(
        homeStatus(
          homeSnapshot(nextDueAt: due, reminderLeadMinutes: 240),
          serverNow: now,
        ),
        HomeStatus.dueSoon,
      );
    });

    test('with the reminder off nothing is "due soon" before the deadline', () {
      expect(
        homeStatus(
          homeSnapshot(
            nextDueAt: now.add(const Duration(minutes: 1)),
            reminderLeadMinutes: 0,
          ),
          serverNow: now,
        ),
        HomeStatus.active,
      );
    });

    test('a passed deadline the server has not acted on is Overdue, never '
        '"checked in"', () {
      final due = now.subtract(const Duration(minutes: 3));
      expect(
        homeStatus(homeSnapshot(nextDueAt: due), serverNow: now),
        HomeStatus.overdue,
      );
      expect(
        homeStatus(homeSnapshot(nextDueAt: now), serverNow: now),
        HomeStatus.overdue,
        reason: 'at the deadline',
      );
    });

    test('an open incident, or an incident object, is the incident '
        'placeholder', () {
      expect(
        homeStatus(
          homeSnapshot(status: CheckInStatus.incidentOpen),
          serverNow: now,
        ),
        HomeStatus.incident,
      );
      expect(
        homeStatus(
          homeSnapshot(incident: {'id': 'i-1', 'status': 'grace'}),
          serverNow: now,
        ),
        HomeStatus.incident,
      );
      expect(
        homeStatus(
          homeSnapshot(
            status: CheckInStatus.inactive,
            incident: {'anything': true},
          ),
          serverNow: now,
        ),
        HomeStatus.incident,
      );
    });

    test('an unknown status claims nothing', () {
      expect(
        homeStatus(homeSnapshot(status: CheckInStatus.unknown), serverNow: now),
        HomeStatus.unknown,
      );
    });
  });

  group('pickSafetyNetGap (a hole in a safety net that is on)', () {
    Readiness readiness(List<ReadinessIssue> issues) =>
        Readiness(ready: issues.isEmpty, issues: issues);

    test('nothing to say', () {
      expect(pickSafetyNetGap(readiness(const [])), isNull);
    });

    test('each of the three codes is its own gap', () {
      expect(
        pickSafetyNetGap(readiness([issue(ReadinessCode.noContacts)])),
        SafetyNetGap.noContacts,
      );
      expect(
        pickSafetyNetGap(readiness([issue(ReadinessCode.noStages)])),
        SafetyNetGap.noStages,
      );
      expect(
        pickSafetyNetGap(readiness([issue(ReadinessCode.stageEmpty)])),
        SafetyNetGap.stageEmpty,
      );
    });

    test('contact first, then the plan, whatever the order the server '
        'listed them in', () {
      expect(
        pickSafetyNetGap(
          readiness([
            issue(ReadinessCode.stageEmpty),
            issue(ReadinessCode.noStages),
            issue(ReadinessCode.noContacts),
          ]),
        ),
        SafetyNetGap.noContacts,
      );
      expect(
        pickSafetyNetGap(
          readiness([
            issue(ReadinessCode.stageEmpty),
            issue(ReadinessCode.noStages),
          ]),
        ),
        SafetyNetGap.noStages,
      );
    });

    test('per-contact issues, the inactive schedule and unknown codes are '
        'not a gap', () {
      expect(
        pickSafetyNetGap(
          readiness([
            issue(ReadinessCode.scheduleInactive),
            issue(ReadinessCode.contactPending, 'c-1'),
            issue(ReadinessCode.contactDeclined, 'c-2'),
            issue(ReadinessCode.contactBounced, 'c-3'),
            issue(ReadinessCode.contactOptedOut, 'c-4'),
            issue(ReadinessCode.releaseContactUnverified),
            issue(ReadinessCode.unknown),
          ]),
        ),
        isNull,
      );
    });
  });

  group('pickReadinessBanner (one at a time, highest priority first)', () {
    Readiness readiness(List<ReadinessIssue> issues) =>
        Readiness(ready: issues.isEmpty, issues: issues);

    test('nothing to say', () {
      expect(pickReadinessBanner(readiness(const [])), isNull);
    });

    test('a contact that declined, bounced or opted out comes first', () {
      for (final code in [
        ReadinessCode.contactDeclined,
        ReadinessCode.contactBounced,
        ReadinessCode.contactOptedOut,
      ]) {
        expect(
          pickReadinessBanner(
            readiness([
              issue(ReadinessCode.contactPending, 'c-2'),
              issue(code, 'c-1'),
            ]),
            client: const ClientReadiness(
              notificationsOff: true,
              timezoneMismatch: 'Europe/London',
            ),
          ),
          const ReadinessBanner(
            ReadinessBannerKind.contactProblem,
            contactId: 'c-1',
          ),
          reason: '$code',
        );
      }
    });

    test(
      'with several affected contacts it counts and has no single contact',
      () {
        final banner = pickReadinessBanner(
          readiness([
            issue(ReadinessCode.contactDeclined, 'c-1'),
            issue(ReadinessCode.contactBounced, 'c-2'),
          ]),
        );
        expect(banner!.kind, ReadinessBannerKind.contactProblem);
        expect(banner.count, 2);
        expect(banner.contactId, isNull);
      },
    );

    test('then a contact that has not answered', () {
      expect(
        pickReadinessBanner(
          readiness([issue(ReadinessCode.contactPending, 'c-2')]),
          client: const ClientReadiness(notificationsOff: true),
        ),
        const ReadinessBanner(
          ReadinessBannerKind.contactPending,
          contactId: 'c-2',
        ),
      );
    });

    test('then notifications off, then the timezone', () {
      expect(
        pickReadinessBanner(
          readiness(const []),
          client: const ClientReadiness(
            notificationsOff: true,
            timezoneMismatch: 'Europe/London',
          ),
        ),
        const ReadinessBanner(ReadinessBannerKind.notificationsOff),
      );
      expect(
        pickReadinessBanner(
          readiness(const []),
          client: const ClientReadiness(timezoneMismatch: 'Europe/London'),
        ),
        const ReadinessBanner(ReadinessBannerKind.timezoneMismatch),
      );
    });

    test('plan issues, the inactive schedule and unknown codes are not '
        'banners here', () {
      expect(
        pickReadinessBanner(
          readiness([
            issue(ReadinessCode.scheduleInactive),
            issue(ReadinessCode.noContacts),
            issue(ReadinessCode.noStages),
            issue(ReadinessCode.stageEmpty),
            issue(ReadinessCode.releaseContactUnverified),
            issue(ReadinessCode.unknown),
          ]),
        ),
        isNull,
      );
    });

    test('a banner compares by value', () {
      const a = ReadinessBanner(ReadinessBannerKind.contactPending, count: 2);
      expect(
        a,
        const ReadinessBanner(ReadinessBannerKind.contactPending, count: 2),
      );
      expect(
        a.hashCode,
        const ReadinessBanner(
          ReadinessBannerKind.contactPending,
          count: 2,
        ).hashCode,
      );
      expect(
        a,
        isNot(const ReadinessBanner(ReadinessBannerKind.contactPending)),
      );
    });
  });
}
