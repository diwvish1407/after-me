import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// The steps a person takes, driven through the real screens against the real backend.
/// Every step waits for what the next screen shows, so a break is reported where it
/// happened.

/// Welcome, create account, the emailed code (read from the backend's mail directory),
/// and arrival at the first onboarding step.
Future<void> signUpThroughUi(Harness h, TestAccount account) async {
  await h.waitForText(
    l10n.welcomeGetStarted,
    timeout: const Duration(seconds: 30),
  );
  await h.tapText(l10n.welcomeGetStarted);
  await h.waitForText(l10n.createAccountHeading);
  await h.typeInto(l10n.fieldName, TestAccount.name);
  await h.typeInto(l10n.fieldEmail, account.email);
  await h.typeInto(l10n.fieldPassword, account.password);
  await h.tapText(l10n.consentAdult);
  await h.tapText(l10n.consentTerms);
  await h.tapText(l10n.createAccountSubmit);
  await h.waitForText(l10n.codeHeading, timeout: const Duration(seconds: 30));

  final code = await h.backend.signupCode(account.email);
  await h.typeInto(l10n.fieldCode, code);
  await h.tapText(l10n.codeVerify);
  await h.waitForText(
    l10n.contactStepTitle,
    timeout: const Duration(seconds: 30),
  );

  // From here the tests can read what the server holds, with a session of their own.
  h.probe = await h.backend.login(account.email, account.password);
}

/// Onboarding steps 4 to 9 on the way to an active plan: the contact is added and, while
/// the person carries on, accepts through the public pages; then the schedule, the plan
/// (Standard preset), the instruction step skipped, "Stay protected" passed, and the last
/// step turns check-ins on. Ends on Home, active.
Future<void> onboardToActivePlan(Harness h, TestAccount account) async {
  // Step 4: a trusted contact.
  await h.typeInto(l10n.fieldContactName, TestAccount.contactName);
  await h.tapText(l10n.relationshipParent);
  await h.typeInto(l10n.fieldContactEmail, account.contactEmail);
  await h.tapText(l10n.contactStepSave);
  await h.waitForText(
    l10n.scheduleStepTitle,
    timeout: const Duration(seconds: 30),
  );

  // The contact's side: the invitation mail, then the public pages.
  final token = await h.backend.invitationToken(account.contactEmail);
  await h.backend.acceptInvitation(token);

  // Step 5: the schedule (the default: every day, by 8:00 PM).
  await h.tapText(l10n.scheduleStepSave);
  await h.waitForText(l10n.planStepTitle, timeout: const Duration(seconds: 30));

  // Step 6: the plan (the Standard preset).
  await h.tapText(l10n.planStepUse);
  await h.waitForText(
    l10n.instructionStepTitle,
    timeout: const Duration(seconds: 30),
  );

  // Step 7: instructions are optional.
  await h.tapText(l10n.actionSkipForNow);
  await h.waitForText(l10n.protectStepTitle);

  // Step 8: stay protected is optional too (nothing here opens a system dialog).
  await h.tapText(l10n.actionContinue);

  // Step 9: the server decides whether check-ins can start.
  await h.waitForText(
    l10n.doneTitleActive,
    timeout: const Duration(seconds: 30),
  );
  await h.tapText(l10n.doneGoHome);
  await h.waitForText(
    l10n.homeStatusActiveTitle,
    timeout: const Duration(seconds: 30),
  );
}

/// Sign-up and onboarding in one: a fresh app, a new account, an active plan, on Home.
Future<TestAccount> signUpAndActivate(
  Harness h, {
  List<Override> overrides = const [],
}) async {
  final account = TestAccount.fresh();
  await h.launch(overrides: overrides);
  await signUpThroughUi(h, account);
  await onboardToActivePlan(h, account);
  return account;
}

/// The server's idea of the next deadline for the probe's account.
Future<DateTime> nextDueAt(Harness h) async {
  final home = await h.backend.home(h.probe!);
  final checkin = home['checkin'] as Map<String, dynamic>;
  final due = checkin['next_due_at'] as String?;
  if (due == null) {
    await h.fail('The server has no next_due_at (check-ins are not active).');
  }
  return DateTime.parse(due).toUtc();
}

/// Polls the server (through the probe) until the account's incident satisfies [test];
/// fails with the last incident the server returned. Frames keep being pumped, so the app
/// stays alive while the worker (two-second tick) does its job.
Future<Map<String, dynamic>> waitForServerIncident(
  Harness h,
  bool Function(Map<String, dynamic> incident) test, {
  required String reason,
  Duration timeout = const Duration(seconds: 40),
}) async {
  final deadline = DateTime.now().add(timeout);
  Map<String, dynamic>? last;
  while (true) {
    last = await h.backend.incident(h.probe!);
    if (last != null && test(last)) {
      return last;
    }
    if (DateTime.now().isAfter(deadline)) {
      await h.fail(
        'The server did not reach "$reason" within ${timeout.inSeconds}s '
        '(worker tick is 2 s). Last incident seen: '
        '${last == null ? 'none' : 'status=${last['status']} requires=${last['requires']} contacts_messaged=${last['contacts_messaged']}'}',
      );
    }
    await h.pump(const Duration(milliseconds: 500));
  }
}

/// Moves the test clock just past [due] so the worker opens the incident, then waits for
/// the server to say so.
Future<Map<String, dynamic>> missDeadline(Harness h) async {
  final due = await nextDueAt(h);
  await h.backend.advanceTo(due, after: const Duration(seconds: 20));
  return waitForServerIncident(
    h,
    (incident) => incident['status'] == 'grace',
    reason: 'incident open in grace',
  );
}

/// I'M SAFE as a person does it: the button, the password sheet, the confirmation
/// (naming who will be told) and the result; then "Done". Ends back on Home.
Future<void> markSafeThroughUi(Harness h, TestAccount account) async {
  await h.tapText(l10n.incidentSafeButton);
  await h.waitForText(l10n.reauthTitle);
  await h.expectPresent(
    find.text(l10n.reauthReasonIncidentSafe),
    'the reason the password is asked for',
  );
  await h.typeInto(l10n.fieldPassword, account.password);
  await h.tapButton(l10n.reauthConfirm);

  await h.waitForText(l10n.safeConfirmTitle);
  await h.expectPresent(
    find.text(l10n.safeConfirmTell(TestAccount.contactName)),
    'who will be told',
  );
  await h.tapButton(l10n.safeConfirmButton);

  await h.waitForText(l10n.safeDoneTitle, timeout: const Duration(seconds: 30));
  await h.expectPresent(
    find.textContaining(l10n.safeDoneTold(TestAccount.contactName)),
    'the all-clear naming the contact',
  );
  await h.tapButton(l10n.safeDoneButton);
}
