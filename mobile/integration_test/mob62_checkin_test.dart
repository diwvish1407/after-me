// MOB-62: a check-in (TEST_PLAN §6).
//
// I'M OK on Home. "Checked in" is shown only once the server holds the check-in, the
// Home aggregate follows, and the history screen lists it.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/backend.dart';
import 'support/harness.dart';
import 'support/journeys.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final backend = Backend.fromEnvironment();
  tearDownAll(backend.close);

  integrationTest('MOB-62 check-in', backend, (h) async {
    await signUpAndActivate(h);

    await h.expectPresent(
      find.text(l10n.homeLastCheckInNone),
      'no check-in yet',
    );
    expect(
      await backend.checkins(h.probe!),
      isEmpty,
      reason: 'the server holds no check-in before the tap',
    );

    await h.tapText(l10n.checkInLabelIdle);

    // Success may be on screen only when the server holds the check-in: the moment the
    // button says "Checked in", the server must already list it.
    var seenSuccess = false;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!seenSuccess) {
      seenSuccess = find.text(l10n.checkInLabelSuccess).evaluate().isNotEmpty;
      if (seenSuccess) {
        final held = await backend.checkins(h.probe!);
        expect(
          held,
          hasLength(1),
          reason: 'the button said "Checked in" before the server had it',
        );
        expect(held.single['kind'], 'ok');
        expect(held.single['source'], 'app');
      } else if (DateTime.now().isAfter(deadline)) {
        await h.fail('The button never reached "Checked in" within 30 s.');
      } else {
        await h.pump(const Duration(milliseconds: 100));
      }
    }
    await h.waitForTextContaining('Checked in. Next check-in');

    // Home follows the server: the last check-in is no longer "none".
    await h.waitUntilAbsent(
      find.text(l10n.homeLastCheckInNone),
      reason: 'the "No check-in yet" text',
    );
    final home = await backend.home(h.probe!);
    final checkin = home['checkin'] as Map<String, dynamic>;
    expect(checkin['last_checkin_at'], isNotNull);
    expect(checkin['status'], 'active');

    // Settings > Check-in history lists it, from the app.
    await h.tapTab(l10n.navSettings);
    await h.tapText(l10n.settingsCheckInHistory);
    await h.waitForText(l10n.historyKindOk);
    await h.waitForText(l10n.historySourceApp);
    await h.expectAbsent(
      find.text(l10n.historyEmptyTitle),
      'the empty-history message',
    );
  });
}
