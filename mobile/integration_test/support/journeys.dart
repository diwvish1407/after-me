import 'package:afterme/features/plan/presentation/plan_preview.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

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

/// An instruction written in onboarding step 7, shared with the contact just added after
/// [afterDays] days without a check-in (which adds a stage at that time to the plan).
class InstructionSpec {
  const InstructionSpec({
    required this.title,
    required this.body,
    this.afterDays = 1,
  });

  final String title;
  final String body;
  final int afterDays;
}

/// Onboarding steps 4 to 9 on the way to an active plan: the contact is added and, while
/// the person carries on, accepts through the public pages; then the schedule, the plan
/// (Standard preset), the instruction step skipped (or [instruction] written), "Stay
/// protected" passed, and the last step turns check-ins on. Ends on Home, active.
Future<void> onboardToActivePlan(
  Harness h,
  TestAccount account, {
  InstructionSpec? instruction,
}) async {
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
  if (instruction == null) {
    await h.tapText(l10n.actionSkipForNow);
  } else {
    await writeFirstInstruction(h, instruction);
  }
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

/// Step 7 as a person does it: write one's own instruction (category Home, a title and
/// a text), shared with the contact just added after [InstructionSpec.afterDays] day(s)
/// without a check-in, and save it. The app then moves on by itself to the next step
/// ("Stay protected"), which is what this waits for.
Future<void> writeFirstInstruction(Harness h, InstructionSpec spec) async {
  await h.waitForText(l10n.instructionStepTitle);
  await h.tapText(l10n.instructionsWriteOwn);
  await h.waitForText(l10n.instructionCategoryHeading);
  await h.tapText(l10n.instructionCategoryHome);
  await h.typeInto(l10n.fieldInstructionTitle, spec.title);
  await h.typeInto(l10n.fieldInstructionBody, spec.body);
  // The contact just added is ticked already; the time is a stage the plan has no stage
  // for yet, which the save adds to the plan.
  await h.expectPresent(
    find.text(TestAccount.contactName),
    'the contact offered as the recipient',
  );
  await h.tapText(
    l10n.instructionReleaseAfter(l10n.durationDays(spec.afterDays)),
  );
  await h.tapButton(l10n.instructionSave);
  await h.waitForText(
    l10n.protectStepTitle,
    timeout: const Duration(seconds: 30),
  );
}

/// Sign-up and onboarding in one: a fresh app, a new account, an active plan, on Home.
///
/// With [premium] the account's plan is raised right after sign-up (through the host
/// helper: there is no billing), so that a second contact and custom stages are allowed.
Future<TestAccount> signUpAndActivate(
  Harness h, {
  List<Override> overrides = const [],
  InstructionSpec? instruction,
  bool premium = false,
}) async {
  final account = TestAccount.fresh();
  await h.launch(overrides: overrides);
  await signUpThroughUi(h, account);
  if (premium) {
    final me = await h.backend.getJson(h.probe!, '/v1/me');
    await h.backend.setTier(me['id'] as String, 'premium');
  }
  await onboardToActivePlan(h, account, instruction: instruction);
  return account;
}

/// A premium account's second trusted contact, added in the People tab and accepted
/// through the public pages. Ends on the People tab.
Future<void> addSecondContact(Harness h, TestAccount account) async {
  await h.tapTab(l10n.navPeople);
  await h.waitForText(TestAccount.contactName);
  await h.tapButton(l10n.peopleAddContact);
  await h.waitForText(l10n.contactAddTitle);
  await h.typeInto(l10n.fieldContactName, TestAccount.secondContactName);
  await h.tapText(l10n.relationshipSibling);
  await h.typeInto(l10n.fieldContactEmail, account.secondContactEmail);
  await h.tapButton(l10n.contactFormSendInvite);
  // Said only after the server accepted the contact (the typed name would match too).
  await h.waitForText(
    l10n.contactAdded(account.secondContactEmail),
    timeout: const Duration(seconds: 30),
  );
  final token = await h.backend.invitationToken(account.secondContactEmail);
  await h.backend.acceptInvitation(token);
}

/// The plan editor, as a person uses it: a second stage after one day that tells the
/// second contact, saved with the password (check-ins are on). Ends on the Plan tab.
Future<void> addSecondStageForSecondContact(
  Harness h,
  TestAccount account,
) async {
  await h.tapTab(l10n.navPlan);
  await h.tapButton(l10n.planEditAction);
  await h.waitForText(l10n.planStagesTitle);
  await h.tapButton(l10n.planEditAdd);
  await h.waitForText(l10n.planTimeAddTitle);
  await h.tapFinder(
    find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text(l10n.durationDays(1)),
    ),
    reason: 'the "1 day" time',
  );
  await h.tapButton(l10n.planTimeUse);
  await h.waitForText(l10n.planStageNobody);
  // Stage 2 is the second card: its own "Choose who is told".
  await h.tapFinder(
    find.text(l10n.planEditChooseWho).at(1),
    reason: 'the "Choose who is told" of stage 2',
  );
  await h.waitForText(l10n.planWhoTitle(2));
  await h.tapFinder(
    find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text(TestAccount.secondContactName),
    ),
    reason: 'the second contact in the who sheet',
  );
  await h.tapButton(l10n.planWhoUse);
  await h.waitForText(
    l10n.planStageNotify(TestAccount.secondContactName),
    timeout: const Duration(seconds: 10),
  );
  await h.tapButton(l10n.planEditSave);
  await h.waitForText(l10n.reauthTitle);
  await h.typeInto(l10n.fieldPassword, account.password);
  await h.tapButton(l10n.reauthConfirm);
  // Said only after the server answered with the plan; the editor then closes.
  await h.waitForText(l10n.planEditSaved, timeout: const Duration(seconds: 30));
  await h.waitUntilAbsent(
    find.text(l10n.planEditSave),
    reason: 'the editor closing after the save',
  );
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
///
/// [told] are the people who were messaged (the sheet and the result name them);
/// [whileConfirming] runs while the confirmation is on screen, for what it says about
/// what was shared and viewed.
Future<void> markSafeThroughUi(
  Harness h,
  TestAccount account, {
  List<String> told = const [TestAccount.contactName],
  Future<void> Function()? whileConfirming,
}) async {
  // The server lists who was told in its own order (not always the stage order), so a
  // sentence naming them is accepted in any order.
  final sentences = [
    for (final order in _orderings(told)) joinNames(l10n, order),
  ];
  await h.tapText(l10n.incidentSafeButton);
  await h.waitForText(l10n.reauthTitle);
  await h.expectPresent(
    find.text(l10n.reauthReasonIncidentSafe),
    'the reason the password is asked for',
  );
  await h.typeInto(l10n.fieldPassword, account.password);
  await h.tapButton(l10n.reauthConfirm);

  await h.waitForText(l10n.safeConfirmTitle);
  if (!sentences.any(
    (names) => find.text(l10n.safeConfirmTell(names)).evaluate().isNotEmpty,
  )) {
    await h.fail('Expected the confirmation to name ${told.join(', ')}.');
  }
  if (whileConfirming != null) {
    await whileConfirming();
  }
  await h.tapButton(l10n.safeConfirmButton);

  await h.waitForText(l10n.safeDoneTitle, timeout: const Duration(seconds: 30));
  if (!sentences.any(
    (names) =>
        find.textContaining(l10n.safeDoneTold(names)).evaluate().isNotEmpty,
  )) {
    await h.fail('Expected the all-clear to name ${told.join(', ')}.');
  }
  await h.tapButton(l10n.safeDoneButton);
}

/// The timeline entry of [incident] of this [kind] (`execute_stage`,
/// `user_final_warning`) at stage [position], or null.
Map<String, dynamic>? timelineEntry(
  Map<String, dynamic> incident,
  String kind,
  int position,
) {
  for (final item in incident['timeline'] as List<dynamic>? ?? const []) {
    final entry = item as Map<String, dynamic>;
    if (entry['kind'] == kind && entry['stage_position'] == position) {
      return entry;
    }
  }
  return null;
}

/// Runs stage [position] of the open incident and lets its messages leave: the clock
/// goes to the final warning of a stage that shares instructions (if it has one), then
/// to the stage, a few seconds past each, one step at a time (the worker puts back a
/// contact-facing stage found far too late, which is the production rule working); the
/// worker's two-second tick runs each. Then the settle delay (5 minutes) passes, so the
/// messages of the stage may be sent. Returns the incident the server holds after it.
Future<Map<String, dynamic>> runStage(Harness h, int position) async {
  final backend = h.backend;
  final incident = await backend.incident(h.probe!);
  if (incident == null) {
    await h.fail('There is no open incident to run stage $position of.');
  }
  final warning = timelineEntry(incident, 'user_final_warning', position);
  if (warning != null && warning['status'] != 'executed') {
    await backend.advanceTo(
      DateTime.parse(warning['scheduled_for'] as String),
      after: const Duration(seconds: 15),
    );
    await waitForServerIncident(
      h,
      (i) =>
          timelineEntry(i, 'user_final_warning', position)?['status'] ==
          'executed',
      reason: 'the final warning before stage $position was sent',
    );
  }
  final stage = timelineEntry(incident, 'execute_stage', position);
  if (stage == null) {
    await h.fail('The incident has no stage $position.');
  }
  await backend.advanceTo(
    DateTime.parse(stage['scheduled_for'] as String),
    after: const Duration(seconds: 10),
  );
  await waitForServerIncident(
    h,
    (i) => timelineEntry(i, 'execute_stage', position)?['status'] == 'executed',
    reason: 'stage $position executed',
  );
  // The message waits out the settle delay (5 minutes by default) before it leaves: the
  // incident says contacts were messaged once the dispatcher has handed one over. (For a
  // later stage that is already true, so callers check the mail of the contact they
  // expect.)
  await backend.advanceSeconds(310);
  return waitForServerIncident(
    h,
    (i) => i['contacts_messaged'] == true,
    reason: 'a contact was messaged after stage $position',
  );
}

/// Every ordering of [names] (there are at most a few).
List<List<String>> _orderings(List<String> names) {
  if (names.length <= 1) {
    return [names];
  }
  return [
    for (var i = 0; i < names.length; i++)
      for (final rest in _orderings([
        ...names.sublist(0, i),
        ...names.sublist(i + 1),
      ]))
        [names[i], ...rest],
  ];
}
