// MOB-67: a plan with two stages and two different contacts (TEST_PLAN §6).
//
// A premium account (the plan is raised through the host helper: there is no billing) has
// Mom in stage 1 and, added in the People tab and the plan editor, Brother in stage 2 after
// one day. Mom is told at stage 1 and Brother is not; Brother is told at stage 2 and Mom is
// not told again. I'M SAFE after both were told sends one all-clear to each. In the second
// case I'M SAFE comes after stage 1 only: stage 2 never runs, Brother is never told
// anything, and only Mom gets the all-clear.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/backend.dart';
import 'support/harness.dart';
import 'support/journeys.dart';

/// The templates a contact is only ever sent because of an incident.
const _incidentMail = [
  'contact_alert',
  'contact_alert_with_release',
  'contact_release',
  'contact_all_clear',
];

Future<List<String>> _incidentMailTo(Backend backend, String address) async => [
  for (final m in await backend.mail(to: address, limit: 50))
    if (_incidentMail.contains(m.template)) m.template,
];

/// A premium account with two contacts, Mom told at stage 1 and Brother at stage 2, on
/// Home with check-ins on.
Future<TestAccount> _twoStagePlan(Harness h) async {
  final account = await signUpAndActivate(h, premium: true);
  await addSecondContact(h, account);
  await addSecondStageForSecondContact(h, account);

  // The server's plan: two stages, Mom at the first and Brother at the second.
  final home = await h.backend.home(h.probe!);
  final plan = home['plan_summary'] as Map<String, dynamic>;
  expect(plan['stages'], 2, reason: 'the plan editor saved a second stage');
  expect(plan['contacts_verified'], 2, reason: 'both contacts accepted');
  await h.tapTab(l10n.navHome);
  await h.waitForText(l10n.homeStatusActiveTitle);
  return account;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final backend = Backend.fromEnvironment();
  tearDownAll(backend.close);

  integrationTest(
    'MOB-67 two stages, two contacts, I\'M SAFE after both',
    backend,
    (h) async {
      final account = await _twoStagePlan(h);
      await missDeadline(h);

      // Stage 1 tells Mom, and only Mom.
      final afterOne = await runStage(h, 1);
      expect(afterOne['contacts_messaged'], isTrue);
      await backend.waitForMail(
        to: account.contactEmail,
        template: 'contact_alert',
      );
      expect(
        await _incidentMailTo(backend, account.secondContactEmail),
        isEmpty,
        reason: 'Brother is not told at stage 1',
      );
      await h.waitFor(
        find.text(l10n.incidentNotifiedTitle),
        reason: 'the notified headline',
        onPoll: h.refreshHome,
      );
      await h.expectPresent(
        find.textContaining(
          '${TestAccount.secondContactName} will be notified',
        ),
        'who is told next',
      );

      // Stage 2 tells Brother, and Mom is not told a second time.
      await runStage(h, 2);
      await backend.waitForMail(
        to: account.secondContactEmail,
        template: 'contact_alert',
      );
      expect(
        await backend.mail(to: account.contactEmail, template: 'contact_alert'),
        hasLength(1),
        reason: 'Mom got her one alert at stage 1 only',
      );
      await h.waitFor(
        find.textContaining('${TestAccount.secondContactName} was notified'),
        reason: 'Brother, told, in the headline',
        onPoll: h.refreshHome,
      );

      // I'M SAFE: one all-clear to each, exactly.
      await markSafeThroughUi(
        h,
        account,
        told: const [TestAccount.contactName, TestAccount.secondContactName],
      );
      await h.waitFor(
        find.text(l10n.homeStatusActiveTitle),
        reason: 'Home back to active',
        onPoll: h.refreshHome,
      );
      expect(
        await backend.waitForMail(
          to: account.contactEmail,
          template: 'contact_all_clear',
        ),
        hasLength(1),
      );
      expect(
        await backend.waitForMail(
          to: account.secondContactEmail,
          template: 'contact_all_clear',
        ),
        hasLength(1),
      );
      expect(await backend.incident(h.probe!), isNull);
    },
  );

  integrationTest(
    'MOB-67b I\'M SAFE after stage 1 stops stage 2: Brother is never told',
    backend,
    (h) async {
      final account = await _twoStagePlan(h);
      final grace = await missDeadline(h);
      final stage2 = timelineEntry(grace, 'execute_stage', 2)!;
      await runStage(h, 1);
      await backend.waitForMail(
        to: account.contactEmail,
        template: 'contact_alert',
      );
      await h.waitFor(
        find.text(l10n.incidentSafeButton),
        reason: "the I'M SAFE button after stage 1",
        onPoll: h.refreshHome,
      );

      await markSafeThroughUi(h, account);
      await h.waitFor(
        find.text(l10n.homeStatusActiveTitle),
        reason: 'Home back to active',
        onPoll: h.refreshHome,
      );
      expect(
        await backend.waitForMail(
          to: account.contactEmail,
          template: 'contact_all_clear',
        ),
        hasLength(1),
        reason: 'Mom was told, so Mom gets the all-clear',
      );

      // The clock goes past stage 2's time, and the worker runs for a while. (The next
      // deadline is about the same moment, so a new incident may open in its grace
      // period: that is the schedule working, and it tells nobody.)
      await backend.advanceTo(
        DateTime.parse(stage2['scheduled_for'] as String),
        after: const Duration(minutes: 20),
      );
      await h.settle(const Duration(seconds: 8));

      // The first incident: closed by I'M SAFE, its stage 2 never ran.
      final incidents = await backend.getJson(h.probe!, '/v1/incidents');
      final first = (incidents['items'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .where((i) => i['closed_by'] == 'user_safe')
          .single;
      final detail = await backend.getJson(
        h.probe!,
        '/v1/incidents/${first['id']}',
      );
      expect(
        timelineEntry(detail, 'execute_stage', 2)!['status'],
        isNot('executed'),
        reason: 'stage 2 of the closed incident never ran',
      );
      expect(
        await _incidentMailTo(backend, account.secondContactEmail),
        isEmpty,
        reason: 'Brother was never told anything, and has no all-clear to get',
      );
      expect(
        await backend.mail(to: account.contactEmail, template: 'contact_alert'),
        hasLength(1),
      );
    },
  );
}
