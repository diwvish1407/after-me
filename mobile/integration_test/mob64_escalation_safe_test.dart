// MOB-64: escalation, then I'M SAFE with re-authentication (TEST_PLAN §6).
//
// Time is moved past the deadline, the grace period and the settle delay, one step at a
// time (the worker refuses a contact message that is found far too late), so the worker
// runs stage 1 and the contact is alerted. Home then offers I'M SAFE, which asks for the
// password and a confirmation; the contact gets the all-clear.
import 'package:afterme/features/checkin/application/checkin_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/backend.dart';
import 'support/harness.dart';
import 'support/journeys.dart';

/// Stage 1 runs, then the settle delay passes and the message leaves: the incident
/// ends up with `contacts_messaged` and `requires: safe`.
Future<void> escalate(Harness h, Map<String, dynamic> grace) async {
  final backend = h.backend;
  await backend.advanceTo(
    DateTime.parse(grace['grace_ends_at'] as String),
    after: const Duration(seconds: 10),
  );
  await waitForServerIncident(
    h,
    (i) => i['status'] == 'escalated',
    reason: 'stage 1 executed (escalated)',
  );
  // The message waits out the settle delay (5 minutes by default) before it leaves.
  await backend.advanceSeconds(310);
  final told = await waitForServerIncident(
    h,
    (i) => i['contacts_messaged'] == true,
    reason: 'the contact was messaged',
  );
  expect(told['requires'], 'safe');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final backend = Backend.fromEnvironment();
  tearDownAll(backend.close);

  integrationTest('MOB-64 escalation, then I\'M SAFE with a password', backend, (
    h,
  ) async {
    final account = await signUpAndActivate(h);

    final grace = await missDeadline(h);
    await h.waitFor(
      find.textContaining('You missed your'),
      reason: 'the grace headline',
      onPoll: h.refreshHome,
    );

    await escalate(h, grace);
    final alerts = await backend.waitForMail(
      to: account.contactEmail,
      template: 'contact_alert',
    );
    expect(alerts, hasLength(1), reason: 'exactly one alert to the contact');

    // Home: the contacts were told, and I'M SAFE is the way out.
    await h.waitFor(
      find.text(l10n.incidentNotifiedTitle),
      reason: 'the "Your contacts have been notified" headline',
      onPoll: h.refreshHome,
    );
    await h.expectPresent(
      find.text(l10n.incidentSafeButton),
      "the I'M SAFE button",
    );
    await h.expectAbsent(
      find.text(l10n.checkInLabelIdle),
      "I'M OK (it would be refused)",
    );

    // The full timeline, from the real incident JSON.
    await h.tapButton(l10n.incidentSeeTimeline);
    await h.waitForText(l10n.incidentTimelineTitle);
    await h.expectPresent(
      find.text(l10n.incidentEventStageDone(1, TestAccount.contactName)),
      'the stage that notified the contact',
    );
    await h.tester.pageBack();
    await h.waitForText(l10n.incidentSafeButton);

    await markSafeThroughUi(h, account);

    await h.waitFor(
      find.text(l10n.homeStatusActiveTitle),
      reason: 'Home back to active',
      onPoll: h.refreshHome,
    );
    final clear = await backend.waitForMail(
      to: account.contactEmail,
      template: 'contact_all_clear',
    );
    expect(clear, hasLength(1), reason: 'the contact got one all-clear');
    expect(await backend.incident(h.probe!), isNull);
    final incidents = await backend.getJson(h.probe!, '/v1/incidents');
    final closed =
        (incidents['items'] as List<dynamic>).first as Map<String, dynamic>;
    expect(closed['closed_by'], 'user_safe');

    // Past incidents: the closed incident and how it ended, from the real history.
    await h.tapTab(l10n.navSettings);
    await h.tapText(l10n.settingsIncidents);
    await h.waitFor(
      find.textContaining(
        l10n.incidentRowTitle('\u0000').split('\u0000').first,
      ),
      reason: 'the closed incident in the history',
    );
    await h.expectPresent(
      find.text(l10n.incidentOutcomeSafe),
      'how it ended: confirmed safe, contacts told',
    );
    await h.tester.pageBack();
    await h.pump(const Duration(milliseconds: 500));

    // Activity: every action the server wrote reads as a sentence, none as the
    // "Something changed" fallback (which is what an action this app does not know
    // gets).
    await h.tapText(l10n.settingsActivity);
    await h.waitForText(l10n.activityContactAccepted(TestAccount.contactName));
    await h.expectPresent(
      find.text(l10n.activityScheduleActivated),
      'check-ins turned on',
    );
    await h.expectPresent(
      find.text(l10n.activityIncidentOpened),
      'the missed check-in',
    );
    await h.expectAbsent(
      find.text(l10n.activityUnknown),
      'an activity line the app could not word',
    );
  });

  integrationTest(
    'MOB-64b I\'M OK before I\'M SAFE is refused and handled',
    backend,
    (h) async {
      final account = await signUpAndActivate(h);

      // The phone stays on Home, as a phone in a pocket would, and learns nothing while
      // the miss and the escalation happen.
      final grace = await missDeadline(h);
      await escalate(h, grace);
      await backend.waitForMail(
        to: account.contactEmail,
        template: 'contact_alert',
      );
      await h.expectPresent(
        find.text(l10n.homeStatusActiveTitle),
        'the stale "checked in" status the phone still shows',
      );

      // I'M OK: the server answers 409 safe_required and records nothing.
      await h.tapText(l10n.checkInLabelIdle);
      await h.waitFor(
        find.text(l10n.incidentSafeButton),
        reason: "the I'M SAFE path after the 409 safe_required",
        timeout: const Duration(seconds: 30),
      );
      await h.waitFor(
        find.text(l10n.incidentNotifiedTitle),
        reason: 'the "Your contacts have been notified" headline',
        timeout: const Duration(seconds: 30),
        onPoll: h.refreshHome,
      );
      // The app reached I'M SAFE through the 409 itself, not through a lucky refresh.
      expect(
        h.container.read(checkInControllerProvider).phase,
        CheckInPhase.safeRequired,
        reason: 'the check-in controller must hold the safe_required answer',
      );
      expect(
        await backend.checkins(h.probe!),
        isEmpty,
        reason: 'a refused check-in must record nothing',
      );
      final incident = await backend.incident(h.probe!);
      expect(incident, isNotNull, reason: 'the incident is still open');
      expect(incident!['contacts_messaged'], isTrue);

      // And the way out works from there.
      await markSafeThroughUi(h, account);
      await h.waitFor(
        find.text(l10n.homeStatusActiveTitle),
        reason: 'Home back to active',
        onPoll: h.refreshHome,
      );
      expect(await backend.incident(h.probe!), isNull);
    },
  );
}
