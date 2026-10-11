// MOB-61: onboarding to an active plan (TEST_PLAN §6).
//
// A new person signs up with the emailed code, adds a trusted contact, the contact
// accepts through the real public pages, the schedule and plan are saved, check-ins are
// turned on, and Home says so. Everything runs on an emulator against the dev backend.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/backend.dart';
import 'support/harness.dart';
import 'support/journeys.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final backend = Backend.fromEnvironment();
  tearDownAll(backend.close);

  integrationTest('MOB-61 onboarding to an active plan', backend, (h) async {
    await signUpAndActivate(h);

    // Home, as the person sees it.
    await h.expectPresent(
      find.text(l10n.homeStatusActiveTitle),
      'the "checked in" status',
    );
    await h.expectPresent(
      find.text(l10n.homeGreeting(TestAccount.name)),
      'the greeting with the name from sign-up',
    );
    await h.expectPresent(
      find.text(l10n.homePlanContacts(1, 1)),
      'the contact counted as accepted',
    );
    await h.expectPresent(find.text(l10n.homePlanStages(1)), 'one plan stage');
    await h.expectAbsent(
      find.text(l10n.homeFinishTitle),
      'the onboarding checklist',
    );

    // People: the contact shows as accepted, **without a pull to refresh**. The contact
    // accepted after the list was read during onboarding; Home's counts said so, and the
    // tab reads the list again when it comes into view (it used to keep "Pending").
    await h.tapTab(l10n.navPeople);
    await h.waitForText(TestAccount.contactName);
    await h.waitForText(l10n.contactStatusAccepted);
    await h.expectAbsent(
      find.text(l10n.contactStatusPending),
      'the stale "Pending" chip',
    );
    await h.tapTab(l10n.navHome);
    await h.waitForText(l10n.homeStatusActiveTitle);

    // The server agrees (a session of the test's own).
    final home = await backend.home(h.probe!);
    final checkin = home['checkin'] as Map<String, dynamic>;
    final plan = home['plan_summary'] as Map<String, dynamic>;
    final readiness = home['readiness'] as Map<String, dynamic>;
    expect(checkin['status'], 'active', reason: 'server check-in status');
    expect(checkin['next_due_at'], isNotNull, reason: 'a deadline exists');
    expect(plan['stages'], 1, reason: 'one stage saved');
    expect(plan['contacts_verified'], 1, reason: 'the contact accepted');
    expect(readiness['ready'], isTrue, reason: 'nothing left to fix');
    expect(home['incident'], isNull, reason: 'no incident');
  });
}
