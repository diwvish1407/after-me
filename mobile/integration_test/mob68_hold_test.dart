// MOB-68: the Hold circuit breaker (TEST_PLAN §4.2 ENG-INV-10, §6).
//
// A check-in is missed and the incident is in its grace period when the operator puts the
// system into Hold (`afterme-admin hold enter`, run on the host by tool/integration.sh:
// the CLI is not callable from the phone). The clock then passes the end of the grace
// period, the stage's time and the settle delay. Nobody is told: the incident stays in
// grace, nothing is sent to the contact, and the app still offers I'M OK and never I'M
// SAFE. The app knows (`service.interruption` of the Home aggregate): while the Hold lasts
// Home says so calmly and states no time at which anybody will be told (a time that is
// already past would be wrong); I'M OK stays as it was. When the operator ends the Hold the
// person is told about the interruption, the stage is put back, the banner goes and the
// times come back, and I'M OK closes the incident with nobody ever contacted.
import 'package:flutter/widgets.dart' show Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/backend.dart';
import 'support/harness.dart';
import 'support/journeys.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final backend = Backend.fromEnvironment();
  tearDownAll(backend.close);

  integrationTest('MOB-68 Hold: nobody is told while it lasts', backend, (
    h,
  ) async {
    final account = await signUpAndActivate(h);
    final grace = await missDeadline(h);
    expect(grace['contacts_messaged'], isFalse);
    await h.waitFor(
      find.textContaining('You missed your'),
      reason: 'the grace headline',
      onPoll: h.refreshHome,
    );
    // Before the Hold: no interruption, and a time at which the contact will be told.
    expect((await backend.home(h.probe!))['service'], {
      'interruption': false,
    }, reason: 'the server says there is no interruption');
    await h.expectAbsent(
      find.text(l10n.homeInterruptionTitle),
      'the interruption banner (there is none yet)',
    );
    expect(
      _notifiedSentences(),
      isNotEmpty,
      reason: 'the grace headline says who will be notified',
    );
    expect(
      _notifiedSentences().any(_hasTime),
      isTrue,
      reason: 'and when, before the Hold',
    );

    var holding = false;
    try {
      await backend.holdEnter();
      holding = true;
      expect(
        await backend.holdActive(),
        isTrue,
        reason: 'the engine is in Hold',
      );
      // The server says so in Home, and the app shows it: a calm banner, within the
      // polling the app does by itself (an incident is open).
      expect((await backend.home(h.probe!))['service'], {
        'interruption': true,
      }, reason: 'the server says Home is in an interruption');
      await h.waitFor(
        find.text(l10n.homeInterruptionTitle),
        reason: 'the interruption banner',
        timeout: const Duration(seconds: 90),
        onPoll: h.refreshHome,
      );
      await h.expectPresent(
        find.text(l10n.homeInterruptionBody),
        'what the interruption means for the person',
      );

      // The grace period ends, then the stage's time, then the settle delay.
      await backend.advanceTo(
        DateTime.parse(grace['grace_ends_at'] as String),
        after: const Duration(seconds: 10),
      );
      await h.settle(const Duration(seconds: 8));
      await backend.advanceSeconds(310);
      await h.settle(const Duration(seconds: 8));
      await backend.advanceSeconds(20 * 60);
      await h.settle(const Duration(seconds: 8));

      // The server: still the grace incident, the stage waiting, nobody messaged.
      final incident = (await backend.incident(h.probe!))!;
      expect(incident['status'], 'grace', reason: 'no stage ran');
      expect(incident['contacts_messaged'], isFalse);
      expect(
        timelineEntry(incident, 'execute_stage', 1)!['status'],
        'pending',
        reason: 'the stage waits, it is not executed',
      );
      expect(
        await backend.mail(to: account.contactEmail, limit: 50),
        isNot(
          anyElement(
            predicate<MailMessage>(
              (m) =>
                  m.template.startsWith('contact_alert') ||
                  m.template == 'contact_release',
              'an alert or a release',
            ),
          ),
        ),
        reason: 'nothing was sent to the contact during the Hold',
      );

      // The app: what it can honestly say. The deadline is past, the contact is not told,
      // and the way out is I'M OK (never I'M SAFE, which is for after contacts were told).
      await h.pullToRefresh();
      await h.waitFor(
        find.text(l10n.checkInLabelIdle),
        reason: "the I'M OK button",
        onPoll: h.refreshHome,
      );
      await h.expectAbsent(
        find.text(l10n.incidentSafeButton),
        "I'M SAFE (nobody has been told)",
      );
      await h.expectAbsent(
        find.text(l10n.incidentNotifiedTitle),
        'the "contacts have been notified" state',
      );
      await h.expectPresent(
        find.textContaining('You missed your'),
        'the grace headline, still',
      );
      // The banner is still there, and nothing on screen promises a time at which the
      // contact will be told: the deadline, the stage and the settle delay are all past.
      await h.expectPresent(
        find.text(l10n.homeInterruptionTitle),
        'the interruption banner, still',
      );
      await h.expectPresent(
        find.textContaining(l10n.incidentPausedNote),
        'the paused wording',
      );
      await h.expectPresent(
        find.text(l10n.incidentTimelinePaused),
        'the stage in the timeline, paused',
      );
      final promised = _notifiedSentences();
      expect(promised, isNotEmpty);
      expect(
        promised.where(_hasTime),
        isEmpty,
        reason: 'no time at which anybody will be told: $promised',
      );
    } finally {
      if (holding) {
        await backend.holdExit();
      }
    }

    // The operator ends the Hold. The worker, on its tick, puts the stage back and tells
    // the person; the contact still hears nothing.
    final notices = await _waitForAnyMail(backend, account.email, const [
      'service_interruption',
      'incident_delayed',
    ]);
    expect(notices, isNotEmpty);
    final after = (await backend.incident(h.probe!))!;
    expect(after['contacts_messaged'], isFalse);

    // The stage was put back and shifted: the interruption is over for the app too, the
    // banner goes and the time of the (new) stage is stated again.
    await h.waitUntilAbsent(
      find.text(l10n.homeInterruptionTitle),
      reason: 'the interruption banner after the Hold ended',
      timeout: const Duration(seconds: 90),
      onPoll: h.refreshHome,
    );
    expect((await backend.home(h.probe!))['service'], {
      'interruption': false,
    }, reason: 'the server no longer says there is an interruption');
    await h.expectAbsent(
      find.textContaining(l10n.incidentPausedNote),
      'the paused wording (the Hold is over)',
    );
    await h.expectAbsent(
      find.text(l10n.incidentTimelinePaused),
      'the paused stage in the timeline (the Hold is over)',
    );
    expect(
      _notifiedSentences().any(_hasTime),
      isTrue,
      reason: 'the normal text is back: it says when the contact will be told',
    );

    // I'M OK, and the incident closes with nobody ever contacted.
    await h.tapText(l10n.checkInLabelIdle);
    await h.waitForText(
      l10n.homeWelcomeBack,
      timeout: const Duration(seconds: 30),
    );
    expect(await backend.incident(h.probe!), isNull);
    final incidents = await backend.getJson(h.probe!, '/v1/incidents');
    final closed =
        (incidents['items'] as List<dynamic>).first as Map<String, dynamic>;
    expect(closed['closed_by'], 'user_checkin');
    await h.settle(const Duration(seconds: 6));
    final contactMail = await backend.mail(to: account.contactEmail, limit: 50);
    expect(
      [for (final m in contactMail) m.template],
      isNot(contains('contact_alert')),
      reason: 'the contact was never alerted',
    );
  });
}

/// The sentences on screen that say somebody "will be notified" (the headline and the
/// stage's line in the timeline).
List<String> _notifiedSentences() => [
  for (final element in find.textContaining('will be notified').evaluate())
    ?(element.widget as Text).data,
];

/// A clock time such as "11:00 PM" or "23:00" in [text].
bool _hasTime(String text) => RegExp(r'\d{1,2}:\d{2}').hasMatch(text);

/// Waits until a message of one of [templates] was mailed to [to].
Future<List<MailMessage>> _waitForAnyMail(
  Backend backend,
  String to,
  List<String> templates, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final found = [
      for (final m in await backend.mail(to: to, limit: 30))
        if (templates.contains(m.template)) m,
    ];
    if (found.isNotEmpty) {
      return found;
    }
    if (DateTime.now().isAfter(deadline)) {
      final any = await backend.mail(to: to, limit: 10);
      throw BackendFailure(
        'None of $templates was mailed to $to within ${timeout.inSeconds}s. '
        'Templates sent to that address: ${any.map((m) => m.template).toList()}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}
