// MOB-63: a simulated miss, the grace state, then I'M OK (TEST_PLAN §6).
//
// The test clock is moved past the deadline (for the API and the worker), the worker
// opens the incident, Home shows the grace state, and I'M OK resolves it with nobody
// contacted.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/backend.dart';
import 'support/harness.dart';
import 'support/journeys.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final backend = Backend.fromEnvironment();
  tearDownAll(backend.close);

  integrationTest('MOB-63 simulated miss, grace, I\'M OK', backend, (h) async {
    final account = await signUpAndActivate(h);

    // The deadline passes (clock moved for the API and the worker), and the worker, on
    // its own tick, opens the incident.
    final incident = await missDeadline(h);
    expect(incident['requires'], 'checkin');
    expect(incident['contacts_messaged'], isFalse);

    // The app has not been told yet: a real pull-to-refresh reads Home again. (The
    // access token expired with the clock jump; the app renews it by itself.)
    await h.pullToRefresh();
    await h.waitFor(
      find.textContaining('You missed your'),
      reason: 'the grace headline "You missed your ... check-in"',
      onPoll: h.refreshHome,
    );
    await h.expectPresent(
      find.textContaining('${TestAccount.contactName} will be notified'),
      'who will be notified',
    );
    await h.expectPresent(
      find.text(l10n.checkInLabelIdle),
      "the I'M OK button",
    );
    await h.expectAbsent(
      find.text(l10n.incidentSafeButton),
      "I'M SAFE (nobody has been told)",
    );
    await h.expectAbsent(
      find.text(l10n.incidentNotifiedTitle),
      'the "contacts have been notified" state',
    );

    // I'M OK: nobody was contacted, and the app says so only after the server's answer.
    await h.tapText(l10n.checkInLabelIdle);
    await h.waitForText(
      l10n.homeWelcomeBack,
      timeout: const Duration(seconds: 30),
    );
    await h.waitFor(
      find.text(l10n.homeStatusActiveTitle),
      reason: 'Home back to active',
      onPoll: h.refreshHome,
    );
    await h.expectAbsent(
      find.textContaining('You missed your'),
      'the grace headline',
    );

    // The server: no incident, a recorded check-in, and nobody was contacted.
    expect(await backend.incident(h.probe!), isNull);
    final checkins = await backend.checkins(h.probe!);
    expect(checkins, hasLength(1));
    expect(checkins.single['kind'], 'ok');
    final alerts = await backend.mail(
      to: account.contactEmail,
      template: 'contact_alert',
    );
    expect(alerts, isEmpty, reason: 'no contact_alert may have been sent');
    final incidents = await backend.getJson(h.probe!, '/v1/incidents');
    final items = incidents['items'] as List<dynamic>;
    expect(items, hasLength(1));
    expect((items.single as Map<String, dynamic>)['closed_by'], 'user_checkin');
  });
}
