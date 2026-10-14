// MOB-66: an instruction is released to the portal, read there, and taken back by I'M SAFE
// (TEST_PLAN §6, §4 ENG-LC-08).
//
// The person writes an instruction in onboarding and shares it with the contact after one
// day, which adds a second stage to the plan. They then miss check-ins: stage 1 tells the
// contact, the final warning goes, stage 2 runs and releases it. The contact's email holds a
// portal link and no content; the test does what the contact's browser does (link, session,
// the code read from the mail directory, the code entered) and finds the instruction in the
// page. The person then presses I'M SAFE in the app, which says what was viewed; the portal
// shows nothing any more, and the Activity feed says the contact viewed it.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/backend.dart';
import 'support/harness.dart';
import 'support/journeys.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final backend = Backend.fromEnvironment();
  tearDownAll(backend.close);

  integrationTest(
    'MOB-66 release to the portal, then I\'M SAFE takes it back',
    backend,
    (h) async {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      // Plain words only: the page escapes markup, and the test looks for the text.
      final title = 'Locker key $stamp';
      final body =
          'The key is with Mrs Verma at flat 3B. Ask for the grey folder $stamp.';
      final account = await signUpAndActivate(
        h,
        instruction: InstructionSpec(title: title, body: body),
      );

      // The plan has two stages now: the preset and the one the instruction added.
      final plan =
          (await backend.home(h.probe!))['plan_summary']
              as Map<String, dynamic>;
      expect(
        plan['stages'],
        2,
        reason: 'the instruction added a stage at 1 day',
      );
      expect(plan['instructions_active'], 1);

      // The person misses the deadline; stage 1 tells the contact.
      await missDeadline(h);
      await runStage(h, 1);
      await backend.waitForMail(
        to: account.contactEmail,
        template: 'contact_alert',
      );

      // Stage 2 releases the instruction (a final warning goes to the person first).
      final released = await runStage(h, 2);
      expect(released['contacts_messaged'], isTrue);
      final token = await backend.releaseLinkToken(account.contactEmail);

      // What the contact was mailed holds a link and none of the content.
      for (final message in await backend.mail(
        to: account.contactEmail,
        limit: 30,
      )) {
        expect(message.text, isNot(contains(title)), reason: message.template);
        expect(
          message.text,
          isNot(contains('grey folder')),
          reason: message.template,
        );
        expect(
          message.subject,
          isNot(contains(title)),
          reason: message.template,
        );
      }

      // The portal, as the contact's browser: link, session, code, content.
      final portal = await backend.openRelease(
        token,
        contactEmail: account.contactEmail,
      );
      expect(portal.page, contains(title), reason: 'the instruction title');
      expect(portal.page, contains('grey folder $stamp'), reason: 'the text');
      expect(portal.page, contains(account.email), reason: 'who it is from');

      // The server says it was viewed (a release with a count), still open.
      final viewed = await waitForServerIncident(
        h,
        (i) => ((i['releases'] as List<dynamic>?) ?? const []).any(
          (r) => (r as Map<String, dynamic>)['view_count'] == 1,
        ),
        reason: 'the release shows one view',
      );
      expect(viewed['status'], isNot('cancelled'));

      // The app: contacts were told, I'M SAFE is the way out. The confirmation names who
      // viewed what and says it cannot be undone.
      await h.waitFor(
        find.text(l10n.incidentSafeButton),
        reason: "the I'M SAFE button",
        onPoll: h.refreshHome,
      );
      await markSafeThroughUi(
        h,
        account,
        whileConfirming: () async {
          await h.expectPresent(
            find.textContaining('${TestAccount.contactName} viewed'),
            'who viewed it, in the confirmation',
          );
          await h.expectPresent(
            find.textContaining("can't be undone"),
            'that a view cannot be undone',
          );
          await h.expectPresent(
            find.textContaining('will no longer be available'),
            'that what was shared is taken back',
          );
        },
      );
      await h.waitFor(
        find.text(l10n.homeStatusActiveTitle),
        reason: 'Home back to active',
        onPoll: h.refreshHome,
      );

      // The all-clear went to the contact, and the portal now shows nothing.
      final clear = await backend.waitForMail(
        to: account.contactEmail,
        template: 'contact_all_clear',
      );
      expect(clear, hasLength(1));
      final after = await backend.portalView(portal);
      expect(after, isNot(contains(title)));
      expect(after, isNot(contains('grey folder')));
      expect(after, contains('no longer available'));
      final closed =
          ((await backend.getJson(h.probe!, '/v1/incidents'))['items']
                      as List<dynamic>)
                  .first
              as Map<String, dynamic>;
      expect(closed['closed_by'], 'user_safe');

      // Activity: the contact viewed it; the line names the contact by the label the
      // person gave, and never shows what the text said.
      await h.tapTab(l10n.navSettings);
      await h.tapText(l10n.settingsActivity);
      await h.waitFor(
        find.textContaining('${TestAccount.contactName} viewed'),
        reason: 'the Activity line that the contact viewed it',
        timeout: const Duration(seconds: 30),
      );
      await h.expectAbsent(
        find.textContaining('grey folder'),
        'the instruction text anywhere in Activity',
      );
      await h.expectAbsent(
        find.text(l10n.activityUnknown),
        'an activity line the app could not word',
      );
    },
  );
}
