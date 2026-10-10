import 'dart:async';
import 'dart:ui' as ui;

import 'package:afterme/app/app.dart';
import 'package:afterme/app/repository_providers.dart';
import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/design_system/check_in_button.dart';
import 'package:afterme/core/security/app_lock/local_auth_gateway.dart';
import 'package:afterme/features/auth/presentation/reauth_sheet.dart';
import 'package:afterme/features/checkin/application/pending_checkin_store.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/home/application/home_controller.dart';
import 'package:afterme/features/instructions/data/instructions_repository.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:afterme/features/onboarding/application/setup_controller.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_checkin_server.dart';
import '../helpers/in_memory_contacts_repository.dart';
import '../helpers/pump_app.dart';
import '../helpers/real_fonts.dart';
import '../helpers/test_app.dart';

/// Every screen added in Phases 2 to 4, reached the way a person reaches it.
///
/// Each one is checked
///  * at 2.0 text scale, with the REAL Roboto metrics, on 360x780 and 320x690: no
///    overflow, no exception, and no word broken in the middle;
///  * against Flutter's accessibility guidelines (48 dp targets, labelled targets, text
///    contrast) in light and dark mode.
class _Screen {
  const _Screen(
    this.name, {
    this.route,
    this.signedIn = false,
    this.step,
    this.prepare,
    this.prefs = const {},
    this.configure,
  });

  final String name;
  final String? route;
  final bool signedIn;

  /// Onboarding step to resume at (signed in).
  final OnboardingStep? step;

  /// Extra preference values (for example an enabled app lock).
  final Map<String, Object> prefs;

  final void Function(TestFakes fakes)? configure;

  /// Reaches the final state of the screen.
  final Future<void> Function(WidgetTester tester, ProviderContainer container)?
  prepare;
}

Future<void> _fillSignUp(WidgetTester tester) async {
  await typeInto(tester, 'Your name', 'Diwakar');
  await typeInto(tester, 'Email', 'new@example.com');
  await typeInto(tester, 'Password', 'a long unique phrase');
  await tapText(tester, 'I am 18 or older.');
  await tapText(
    tester,
    'I agree to the Terms of Service and the Privacy Policy.',
  );
}

Future<void> _addContact(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await container
      .read(setupControllerProvider.notifier)
      .addContact(
        const ContactDraft(
          name: 'Mom',
          relationship: ContactRelationship.parent,
          email: 'mom@example.com',
        ),
      );
}

/// Contacts in every state, as the server would return them.
List<TrustedContact> _everyone() => [
  testContact(sendCount: 2),
  testContact(
    id: 'c2',
    name: 'Samantha Rao-Whitfield',
    relationship: ContactRelationship.other,
    label: 'Neighbour upstairs',
    email: 'samantha.rao.whitfield@example.com',
    phone: '+14155550123',
    priority: 2,
    status: VerificationStatus.pending,
  ),
  testContact(
    id: 'c3',
    name: 'Dad',
    relationship: ContactRelationship.father,
    email: 'dad@example.com',
    priority: 3,
    status: VerificationStatus.declined,
  ),
  testContact(
    id: 'c4',
    name: 'Ann',
    relationship: ContactRelationship.colleague,
    email: 'ann@example.com',
    priority: 4,
    status: VerificationStatus.optedOut,
  ),
  testContact(
    id: 'c5',
    name: 'Joe',
    relationship: ContactRelationship.neighbor,
    email: 'joe@example.com',
    priority: 5,
    status: VerificationStatus.bounced,
  ),
];

void _withContacts(
  TestFakes fakes,
  List<TrustedContact> contacts, {
  String tier = 'premium',
}) {
  fakes.contacts = InMemoryContactsRepository(tier: tier, initial: contacts);
}

/// Mom (accepted), Samantha (waiting), Dad (declined), Ann (opted out) and Joe (bounced),
/// and a plan with stages after 3 hours, 1 day and 2 days: the two late ones are what an
/// instruction can be released at. With [lateStages] 0 only the first stage exists.
void _instructionWorld(
  TestFakes fakes, {
  String tier = 'premium',
  int lateStages = 2,
}) {
  _withContacts(fakes, _everyone(), tier: tier);
  fakes.plan.seed(
    PlanDraft(
      graceMinutes: 180,
      stages: [
        const PlanStageDraft(offsetMinutes: 180, contactIds: ['c1']),
        if (lateStages >= 1)
          const PlanStageDraft(offsetMinutes: 1440, contactIds: ['c1', 'c2']),
        if (lateStages >= 2)
          const PlanStageDraft(offsetMinutes: 2880, contactIds: ['c3']),
      ],
    ),
  );
}

void _instructionWorld0(TestFakes fakes) =>
    _instructionWorld(fakes, lateStages: 0);

/// A world whose plan has exactly the stages [offsets] (minutes after the missed
/// check-in, each telling Mom): a plan with only an early stage offers 1, 2 and 3 days as
/// times to add; a free plan with two stages has no room for another.
void _planOf(TestFakes fakes, List<int> offsets, {String tier = 'premium'}) {
  _withContacts(fakes, _everyone(), tier: tier);
  fakes.plan.seed(
    PlanDraft(
      graceMinutes: offsets.first,
      stages: [
        for (final offset in offsets)
          PlanStageDraft(offsetMinutes: offset, contactIds: const ['c1']),
      ],
    ),
  );
}

/// Chooses the radio with [label] (the [index]th with that text).
Future<void> _time(WidgetTester tester, String label, {int index = 0}) async {
  final finder = find.widgetWithText(RadioListTile<String>, label).at(index);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Instructions in three categories: one shared with two people at different times, one
/// that is switched off, one nobody receives.
void _someInstructions(TestFakes fakes) {
  final stages = fakes.plan.stages;
  fakes.instructions
    ..seed(
      title: 'House emergency',
      body: 'The spare key is with Mrs. Sharma at flat 3B.\nCall her first.',
      category: InstructionCategory.home,
      recipients: {'c1': stages[1].id, 'c2': stages[2].id},
    )
    ..seed(
      title: 'Where the original documents and the spare passport are kept at home',
      category: InstructionCategory.documents,
      status: InstructionStatus.inactive,
      recipients: {'c3': stages[1].id},
    )
    ..seed(title: 'Goldfish', category: InstructionCategory.pets);
}

Future<void> _chip(WidgetTester tester, String label) async {
  final finder = find.widgetWithText(ChoiceChip, label);
  await tester.ensureVisible(finder.first);
  await tester.pump();
  await tester.tap(finder.first);
  await tester.pump();
}

Future<void> _tick(WidgetTester tester, String name) async {
  final finder = find.widgetWithText(CheckboxListTile, name);
  await tester.ensureVisible(finder.first);
  await tester.pump();
  await tester.tap(finder.first);
  await tester.pump();
}

/// Settles the scroll that follows typing (an animated scroll ignores taps) and goes
/// back to the top.
Future<void> _typed(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await _toTop(tester);
}

/// Scrolls the page back to its top: the guidelines measure the visible slices of
/// targets, and typing or tapping scrolls the focused field into view.
Future<void> _toTop(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable);
  if (scrollable.evaluate().isNotEmpty) {
    tester.state<ScrollableState>(scrollable.first).position.jumpTo(0);
    await tester.pump();
  }
}

/// Home with an accepted contact, a plan that tells them and check-ins turned on at the
/// test clock (the server only turns them on with a plan like that).
void _activeHome(TestFakes fakes) {
  _withContacts(fakes, [testContact()]);
  fakes.plan.seedStandard(['c1']);
  fakes.server.activateNow();
}

/// Check-ins on and the plan has a hole: [contacts] and no stage, or with
/// [emptyStage] a stage that tells nobody.
void _gapHome(
  TestFakes fakes, {
  List<TrustedContact> contacts = const [],
  bool emptyStage = false,
}) {
  _withContacts(fakes, contacts);
  if (emptyStage) {
    fakes.plan.seed(
      const PlanDraft(
        graceMinutes: 180,
        stages: [PlanStageDraft(offsetMinutes: 180, contactIds: [])],
      ),
    );
  }
  fakes.server.activateNow();
}

/// A tap that was never confirmed and is now too old to send, kept for `user-1` (the
/// account the screen's preferences below sign in as).
void _staleTap(TestFakes fakes) {
  // The in-memory store applies the write at once.
  unawaited(
    fakes.secure.write(
      PendingCheckInStore.storageKey,
      PendingCheckIn(
        userId: 'user-1',
        idempotencyKey: 'old-key',
        reportedAt: fakes.clock.now().subtract(const Duration(hours: 30)),
      ).encode(),
    ),
  );
}

const _gapNoContacts =
    'You have no trusted contact. If you miss a check-in, nobody is told.';
const _gapNoStages =
    'Your plan has no stage. If you miss a check-in, nobody is told.';
const _gapStageEmpty =
    "A stage in your plan has nobody to tell, so it wouldn't reach anyone.";

/// The screen really is in the state it is named for (the gap banner is there).
void _expectGap(String message) =>
    expect(find.text(message), findsOneWidget, reason: 'the gap banner');

/// The screen really is in the state it is named for (the seeded tap was restored).
void _expectExpiredNotice() =>
    expect(find.text("Your earlier check-in wasn't received"), findsOneWidget);

const _signedInAsUser1 = {
  'afterme.onboardingUserId': 'user-1',
  'afterme.onboardingCompleted': true,
};

Future<void> _tapCheckIn(WidgetTester tester) async {
  await tester.ensureVisible(find.byType(CheckInButton));
  await tester.pump();
  await tester.tap(find.byType(CheckInButton));
  await tester.pumpAndSettle();
  // Tapping scrolled the page; the guidelines measure the visible slices of targets.
  await _toTop(tester);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

final _screens = <_Screen>[
  _Screen(
    'welcome (card 3)',
    route: AppRoutes.welcome,
    prepare: (tester, _) async {
      await tapText(tester, 'Next');
      await tapText(tester, 'Next');
    },
  ),
  const _Screen('sign in', route: AppRoutes.signIn),
  _Screen(
    'sign in with an error',
    route: AppRoutes.signIn,
    prepare: (tester, _) async {
      await typeInto(tester, 'Email', 'diwakar@example.com');
      await typeInto(tester, 'Password', 'wrong');
      await tapText(tester, 'Sign in');
      await tester.pumpAndSettle();
    },
  ),
  _Screen(
    'create account (with errors)',
    route: AppRoutes.createAccount,
    prepare: (tester, _) async {
      await typeInto(tester, 'Email', 'bad');
      await tapText(tester, 'Send my code');
      // Tapping scrolled the page; the guidelines measure the visible slices of targets.
      await tester.ensureVisible(find.text("Let's set you up"));
      await tester.pump();
    },
  ),
  _Screen(
    'enter code (wrong code)',
    route: AppRoutes.createAccount,
    prepare: (tester, _) async {
      await _fillSignUp(tester);
      await tapText(tester, 'Send my code');
      await tester.pumpAndSettle();
      await typeInto(tester, '6-digit code', '000000');
      await tapText(tester, 'Confirm');
      await tester.pumpAndSettle();
    },
  ),
  const _Screen('forgot password', route: AppRoutes.forgotPassword),
  _Screen(
    'forgot password (sent)',
    route: AppRoutes.forgotPassword,
    prepare: (tester, _) async {
      await typeInto(
        tester,
        'Email',
        'someone.with.a.long.address@example.com',
      );
      await tapText(tester, 'Send the link');
      await tester.pumpAndSettle();
    },
  ),
  _Screen(
    'reauth sheet',
    signedIn: true,
    route: AppRoutes.settingsAbout,
    prepare: (tester, container) async {
      final context = tester.element(find.byType(Scaffold).last);
      unawaited(showReauthSheet(context));
      await tester.pumpAndSettle();
    },
  ),
  const _Screen(
    'onboarding: contact',
    signedIn: true,
    step: OnboardingStep.contact,
  ),
  _Screen(
    'onboarding: contact (errors)',
    signedIn: true,
    step: OnboardingStep.contact,
    prepare: (tester, _) async {
      await tapText(tester, 'Save and continue');
    },
  ),
  const _Screen(
    'onboarding: schedule',
    signedIn: true,
    step: OnboardingStep.schedule,
  ),
  _Screen(
    'onboarding: plan (with a contact)',
    signedIn: true,
    step: OnboardingStep.plan,
    prepare: (tester, container) async {
      await _addContact(tester, container);
      await tester.pumpAndSettle();
    },
  ),
  const _Screen(
    'onboarding: plan (no contact)',
    signedIn: true,
    step: OnboardingStep.plan,
  ),
  _Screen(
    'onboarding: plan (account with custom delays)',
    signedIn: true,
    step: OnboardingStep.plan,
    configure: (fakes) => _withContacts(fakes, [testContact()]),
  ),
  _Screen(
    'onboarding: plan (changed elsewhere)',
    signedIn: true,
    step: OnboardingStep.plan,
    configure: (fakes) {
      _withContacts(fakes, [testContact()], tier: 'free');
      fakes.plan.failures['save'] = [
        const ConflictFailure(code: 'precondition_failed'),
      ];
    },
    prepare: (tester, _) async {
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      await _toTop(tester);
    },
  ),
  _Screen(
    'onboarding: plan (delay refused)',
    signedIn: true,
    step: OnboardingStep.plan,
    configure: (fakes) {
      _withContacts(fakes, [testContact()], tier: 'free');
      fakes.plan.failures['save'] = [
        const ValidationFailure(
          code: 'validation_failed',
          fieldErrors: [
            ApiFieldError(field: 'grace_minutes', code: 'not_a_preset'),
          ],
        ),
      ];
    },
    prepare: (tester, _) async {
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      await _toTop(tester);
    },
  ),
  const _Screen(
    'onboarding: instruction templates',
    signedIn: true,
    step: OnboardingStep.instruction,
  ),
  _Screen(
    'onboarding: instruction editor',
    signedIn: true,
    step: OnboardingStep.instruction,
    prepare: (tester, container) async {
      await _addContact(tester, container);
      await tester.pumpAndSettle();
      await tapText(tester, 'Where my documents are');
      await tester.pumpAndSettle();
    },
  ),
  _Screen(
    'onboarding: instruction editor (the plan has no stage a day out: times to add)',
    signedIn: true,
    step: OnboardingStep.instruction,
    configure: _instructionWorld0,
    prepare: (tester, _) async {
      await tapText(tester, 'Pets');
      await tester.pumpAndSettle();
      expect(find.textContaining('Choosing a time adds it'), findsOneWidget);
    },
  ),
  _Screen(
    'onboarding: instruction (saved)',
    signedIn: true,
    step: OnboardingStep.instruction,
    configure: (fakes) {
      _instructionWorld(fakes);
      _someInstructions(fakes);
    },
  ),
  const _Screen(
    'onboarding: protect',
    signedIn: true,
    step: OnboardingStep.protect,
  ),
  const _Screen('onboarding: done', signedIn: true, step: OnboardingStep.done),
  const _Screen('people (empty)', signedIn: true, route: AppRoutes.people),
  _Screen(
    'people (every status and a hint)',
    signedIn: true,
    route: AppRoutes.people,
    configure: (fakes) => _withContacts(fakes, _everyone()),
  ),
  _Screen(
    'people (nobody accepted)',
    signedIn: true,
    route: AppRoutes.people,
    configure: (fakes) =>
        _withContacts(fakes, [testContact(status: VerificationStatus.pending)]),
  ),
  _Screen(
    'people (error)',
    signedIn: true,
    route: AppRoutes.people,
    configure: (fakes) =>
        fakes.contacts.failures['list'] = [const NetworkFailure()],
  ),
  _Screen(
    'people: free-plan limit sheet',
    signedIn: true,
    route: AppRoutes.people,
    configure: (fakes) => _withContacts(fakes, [testContact()], tier: 'free'),
    prepare: (tester, _) async {
      await tapText(tester, 'Add contact');
      await tester.pumpAndSettle();
    },
  ),
  const _Screen('add contact', signedIn: true, route: AppRoutes.peopleAdd),
  _Screen(
    'add contact (errors)',
    signedIn: true,
    route: AppRoutes.peopleAdd,
    prepare: (tester, _) async {
      await tapText(tester, 'Save and send invitation');
      await _toTop(tester);
    },
  ),
  _Screen(
    'add contact (Other, server errors on fields)',
    signedIn: true,
    route: AppRoutes.peopleAdd,
    configure: (fakes) =>
        fakes.contacts.failures['create'] = [const CannotBeOwnEmailFailure()],
    prepare: (tester, _) async {
      await tapText(tester, 'Other');
      await typeInto(tester, 'How do you know them?', 'Neighbour upstairs');
      await typeInto(tester, 'Their name', 'Samantha Rao-Whitfield');
      await typeInto(
        tester,
        'Their email',
        'samantha.rao.whitfield@example.com',
      );
      await tapText(tester, 'Save and send invitation');
      await tester.pumpAndSettle();
      await _toTop(tester);
    },
  ),
  _Screen(
    'edit contact (email changed)',
    signedIn: true,
    route: AppRoutes.contactEdit('c2'),
    configure: (fakes) => _withContacts(fakes, _everyone()),
    prepare: (tester, _) async {
      await typeInto(tester, 'Their email', 'samantha.new@example.com');
      await _toTop(tester);
    },
  ),
  _Screen(
    'contact detail (pending)',
    signedIn: true,
    route: AppRoutes.contactDetail('c2'),
    configure: (fakes) => _withContacts(fakes, _everyone()),
  ),
  _Screen(
    'contact detail (accepted)',
    signedIn: true,
    route: AppRoutes.contactDetail('c1'),
    configure: (fakes) => _withContacts(fakes, _everyone()),
  ),
  _Screen(
    'contact detail (declined)',
    signedIn: true,
    route: AppRoutes.contactDetail('c3'),
    configure: (fakes) => _withContacts(fakes, _everyone()),
  ),
  _Screen(
    'contact detail (bounced)',
    signedIn: true,
    route: AppRoutes.contactDetail('c5'),
    configure: (fakes) => _withContacts(fakes, _everyone()),
  ),
  _Screen(
    'contact detail (resend rate limited)',
    signedIn: true,
    route: AppRoutes.contactDetail('c2'),
    configure: (fakes) {
      _withContacts(fakes, _everyone());
      fakes.contacts.failures['resendInvitation'] = [
        const RateLimitedFailure(retryAfter: Duration(hours: 30)),
      ];
    },
    prepare: (tester, _) async {
      await tapText(tester, 'Resend invitation');
      await tester.pumpAndSettle();
    },
  ),
  _Screen(
    'contact detail: remove sheet',
    signedIn: true,
    route: AppRoutes.contactDetail('c2'),
    configure: (fakes) => _withContacts(fakes, _everyone()),
    prepare: (tester, _) async {
      await tapText(tester, 'Remove');
      await tester.pumpAndSettle();
    },
  ),
  _Screen(
    'onboarding: contact (already invited)',
    signedIn: true,
    step: OnboardingStep.contact,
    configure: (fakes) =>
        _withContacts(fakes, [testContact(status: VerificationStatus.pending)]),
  ),
  _Screen(
    'onboarding: contact (Other selected)',
    signedIn: true,
    step: OnboardingStep.contact,
    prepare: (tester, _) async {
      await tapText(tester, 'Other');
      await _toTop(tester);
    },
  ),
  const _Screen(
    'instructions (empty)',
    signedIn: true,
    route: AppRoutes.instructions,
    configure: _instructionWorld,
  ),
  _Screen(
    'instructions (grouped, with notes)',
    signedIn: true,
    route: AppRoutes.instructions,
    configure: (fakes) {
      _instructionWorld(fakes);
      _someInstructions(fakes);
    },
  ),
  _Screen(
    'instructions (one category)',
    signedIn: true,
    route: AppRoutes.instructions,
    configure: (fakes) {
      _instructionWorld(fakes);
      _someInstructions(fakes);
    },
    prepare: (tester, _) async {
      await _chip(tester, 'Pets');
      await tester.pumpAndSettle();
      await _toTop(tester);
    },
  ),
  _Screen(
    'instructions (error)',
    signedIn: true,
    route: AppRoutes.instructions,
    configure: (fakes) =>
        fakes.instructions.failures['list'] = [const NetworkFailure()],
  ),
  _Screen(
    'instructions: free-plan limit sheet',
    signedIn: true,
    route: AppRoutes.instructions,
    configure: (fakes) {
      _instructionWorld(fakes, tier: 'free');
      _someInstructions(fakes);
    },
    prepare: (tester, _) async {
      await tapText(tester, 'Add instruction');
      await tester.pumpAndSettle();
      expect(
        find.text('More instructions are part of Premium'),
        findsOneWidget,
      );
    },
  ),
  const _Screen(
    'add instruction',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: _instructionWorld,
  ),
  _Screen(
    'add instruction (errors)',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: _instructionWorld,
    prepare: (tester, _) async {
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      await _toTop(tester);
    },
  ),
  _Screen(
    'add instruction (text too long)',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: _instructionWorld,
    prepare: (tester, _) async {
      await _chip(tester, 'Work');
      await typeInto(tester, 'Title', 'x' * 125);
      await tester.enterText(
        find.widgetWithText(TextField, 'What should they know?'),
        'y' * 20001,
      );
      await tester.pumpAndSettle();
      await tapText(tester, 'Save instruction');
      await _typed(tester);
    },
  ),
  _Screen(
    'add instruction (Digital accounts guidance)',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: _instructionWorld,
    prepare: (tester, _) async {
      await _chip(tester, 'Digital accounts');
      await _typed(tester);
      expect(find.textContaining("Don't paste passwords."), findsOneWidget);
    },
  ),
  _Screen(
    'add instruction (everyone listed, one time)',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: _instructionWorld,
    prepare: (tester, _) async {
      await _chip(tester, 'Family');
      await _tick(tester, 'Mom');
      await _tick(tester, 'Samantha Rao-Whitfield');
      await tester.pumpAndSettle();
      await _toTop(tester);
    },
  ),
  _Screen(
    'add instruction (a time for each person)',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: _instructionWorld,
    prepare: (tester, _) async {
      await _tick(tester, 'Mom');
      await _tick(tester, 'Samantha Rao-Whitfield');
      await tapText(tester, 'Choose a time for each person');
      await tester.pumpAndSettle();
      await _toTop(tester);
    },
  ),
  const _Screen(
    'add instruction (no stage a day out: only times to add)',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: _instructionWorld0,
  ),
  const _Screen(
    'add instruction (no trusted contact)',
    signedIn: true,
    route: AppRoutes.instructionNew,
  ),
  _Screen(
    'add instruction (the server refuses)',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: (fakes) {
      _instructionWorld(fakes);
      fakes.instructions.failures['create'] = [
        const ValidationFailure(
          code: 'validation_failed',
          fieldErrors: [
            ApiFieldError(field: 'title', code: 'invalid_characters'),
            ApiFieldError(
              field: 'recipients[0].release_stage_id',
              code: 'release_stage_too_early',
            ),
          ],
        ),
      ];
    },
    prepare: (tester, _) async {
      await _chip(tester, 'Home');
      await typeInto(tester, 'Title', 'House emergency');
      await tester.enterText(
        find.widgetWithText(TextField, 'What should they know?'),
        'The spare key is with a neighbour.',
      );
      await tester.pumpAndSettle();
      await _tick(tester, 'Mom');
      await tester.pumpAndSettle();
      final radio = find.byType(RadioListTile<String>).first;
      await tester.ensureVisible(radio);
      await tester.pump();
      await tester.tap(radio);
      await tester.pump();
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      await _toTop(tester);
    },
  ),
  _Screen(
    'add instruction: examples sheet',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: _instructionWorld,
    prepare: (tester, _) async {
      await tapText(tester, 'Start from an example');
      await tester.pumpAndSettle();
      expect(find.text('Password manager and emergency access'), findsOne);
    },
  ),
  _Screen(
    'add instruction: examples of one category',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: _instructionWorld,
    prepare: (tester, _) async {
      await _chip(tester, 'Insurance');
      await tapText(tester, 'Start from an example');
      await tester.pumpAndSettle();
    },
  ),
  _Screen(
    'add instruction (a draft was kept)',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: _instructionWorld,
    prepare: (tester, container) async {
      await _chip(tester, 'Pets');
      await typeInto(tester, 'Title', 'Goldfish');
      await tester.pumpAndSettle();
      container.read(routerProvider).go(AppRoutes.instructions);
      await tester.pumpAndSettle();
      container.read(routerProvider).go(AppRoutes.instructionNew);
      await tester.pumpAndSettle();
      expect(find.text('We kept what you typed.'), findsOneWidget);
    },
  ),
  _Screen(
    'instruction detail (active)',
    signedIn: true,
    route: AppRoutes.instructionDetail('instruction-1'),
    configure: (fakes) {
      _instructionWorld(fakes);
      _someInstructions(fakes);
    },
  ),
  _Screen(
    'instruction detail (inactive, long title)',
    signedIn: true,
    route: AppRoutes.instructionDetail('instruction-2'),
    configure: (fakes) {
      _instructionWorld(fakes);
      _someInstructions(fakes);
    },
  ),
  _Screen(
    'instruction detail (nobody receives it)',
    signedIn: true,
    route: AppRoutes.instructionDetail('instruction-3'),
    configure: (fakes) {
      _instructionWorld(fakes);
      _someInstructions(fakes);
    },
  ),
  _Screen(
    'instruction detail (cannot be loaded)',
    signedIn: true,
    route: AppRoutes.instructionDetail('instruction-1'),
    configure: (fakes) {
      _instructionWorld(fakes);
      _someInstructions(fakes);
      fakes.instructions.failures['get'] = [const NetworkFailure()];
    },
  ),
  _Screen(
    'instruction detail: delete sheet',
    signedIn: true,
    route: AppRoutes.instructionDetail('instruction-1'),
    configure: (fakes) {
      _instructionWorld(fakes);
      _someInstructions(fakes);
    },
    prepare: (tester, _) async {
      await tapText(tester, 'Delete');
      await tester.pumpAndSettle();
    },
  ),
  _Screen(
    'instruction detail: password sheet (switching off)',
    signedIn: true,
    route: AppRoutes.instructionDetail('instruction-1'),
    configure: (fakes) {
      _instructionWorld(fakes);
      _someInstructions(fakes);
      fakes.server.activateNow();
    },
    prepare: (tester, _) async {
      final toggle = find.byType(Switch);
      await tester.ensureVisible(toggle);
      await tester.pump();
      await tester.tap(toggle);
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
    },
  ),
  _Screen(
    'add instruction: password sheet (choosing who receives it)',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: (fakes) {
      _instructionWorld(fakes);
      fakes.server.activateNow();
    },
    prepare: (tester, _) async {
      await _chip(tester, 'Home');
      await typeInto(tester, 'Title', 'House emergency');
      await tester.enterText(
        find.widgetWithText(TextField, 'What should they know?'),
        'The spare key is with a neighbour.',
      );
      await tester.pumpAndSettle();
      await _tick(tester, 'Mom');
      await tester.pumpAndSettle();
      final radio = find.byType(RadioListTile<String>).first;
      await tester.ensureVisible(radio);
      await tester.pump();
      await tester.tap(radio);
      await tester.pump();
      await tapText(tester, 'Save instruction');
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
    },
  ),
  _Screen(
    'edit instruction',
    signedIn: true,
    route: AppRoutes.instructionEdit('instruction-1'),
    configure: (fakes) {
      _instructionWorld(fakes);
      _someInstructions(fakes);
    },
  ),
  _Screen(
    'edit instruction (one that is gone)',
    signedIn: true,
    route: AppRoutes.instructionEdit('instruction-1'),
    configure: (fakes) {
      _instructionWorld(fakes);
      _someInstructions(fakes);
      fakes.instructions.failures['update'] = [const NotFoundFailure()];
    },
    prepare: (tester, _) async {
      await typeInto(tester, 'Title', 'House emergency (updated)');
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      await _toTop(tester);
    },
  ),
  _Screen(
    'plan tab (stages that share instructions)',
    signedIn: true,
    route: AppRoutes.plan,
    configure: (fakes) {
      _instructionWorld(fakes);
      _someInstructions(fakes);
    },
  ),
  _Screen(
    'add instruction (only times to add, one chosen)',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: (fakes) => _planOf(fakes, [180]),
    prepare: (tester, _) async {
      await _tick(tester, 'Mom');
      expect(find.textContaining('Choosing a time adds it'), findsOneWidget);
      await _time(tester, "If you haven't checked in for 2 days");
      expect(find.textContaining('Saving adds this time'), findsOneWidget);
      await _toTop(tester);
    },
  ),
  _Screen(
    'add instruction (stages of the plan and a time to add)',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: (fakes) => _planOf(fakes, [180, 1440, 2880]),
    prepare: (tester, _) async {
      await _tick(tester, 'Mom');
      await _tick(tester, 'Samantha Rao-Whitfield');
      await tapText(tester, 'Choose a time for each person');
      await tester.pumpAndSettle();
      await _time(tester, "If you haven't checked in for 3 days", index: 1);
      await _toTop(tester);
    },
  ),
  _Screen(
    'add instruction (free plan, no room to add a time)',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: (fakes) => _planOf(fakes, [180, 360], tier: 'free'),
  ),
  _Screen(
    'add instruction (free plan, two new times: the limit)',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: (fakes) => _planOf(fakes, [180], tier: 'free'),
    prepare: (tester, _) async {
      await _chip(tester, 'Home');
      await typeInto(tester, 'Title', 'House emergency');
      await tester.enterText(
        find.widgetWithText(TextField, 'What should they know?'),
        'The spare key is with a neighbour.',
      );
      await tester.pumpAndSettle();
      await _tick(tester, 'Mom');
      await _tick(tester, 'Samantha Rao-Whitfield');
      await tapText(tester, 'Choose a time for each person');
      await tester.pumpAndSettle();
      await _time(tester, "If you haven't checked in for 1 day", index: 0);
      await _time(tester, "If you haven't checked in for 2 days", index: 1);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      await _toTop(tester);
      expect(
        find.textContaining('The free plan has room for 2 stages'),
        findsOne,
      );
    },
  ),
  _Screen(
    'add instruction (the plan has the new time, the instruction was refused)',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: (fakes) {
      _planOf(fakes, [180]);
      fakes.instructions.failures['create'] = [const NetworkFailure()];
    },
    prepare: (tester, _) async {
      await _chip(tester, 'Home');
      await typeInto(tester, 'Title', 'House emergency');
      await tester.enterText(
        find.widgetWithText(TextField, 'What should they know?'),
        'The spare key is with a neighbour.',
      );
      await tester.pumpAndSettle();
      await _tick(tester, 'Mom');
      await _time(tester, "If you haven't checked in for 1 day");
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      await _toTop(tester);
      expect(find.textContaining('Your plan now has the new time'), findsOne);
    },
  ),
  _Screen(
    'add instruction: password sheet (adding a time to the plan)',
    signedIn: true,
    route: AppRoutes.instructionNew,
    configure: (fakes) {
      _planOf(fakes, [180]);
      fakes.server.activateNow();
    },
    prepare: (tester, _) async {
      await _chip(tester, 'Home');
      await typeInto(tester, 'Title', 'House emergency');
      await tester.enterText(
        find.widgetWithText(TextField, 'What should they know?'),
        'The spare key is with a neighbour.',
      );
      await tester.pumpAndSettle();
      await _tick(tester, 'Mom');
      await _time(tester, "If you haven't checked in for 1 day");
      await tapText(tester, 'Save instruction');
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(find.textContaining('Adding this time to your plan'), findsOne);
    },
  ),
  _Screen(
    'onboarding: instruction editor (Standard plan, a time to add chosen)',
    signedIn: true,
    step: OnboardingStep.instruction,
    configure: (fakes) {
      _withContacts(fakes, [testContact()], tier: 'free');
      fakes.plan.seedStandard(['c1']);
    },
    prepare: (tester, _) async {
      await tapText(tester, 'Pets');
      await tester.pumpAndSettle();
      await _time(tester, "If you haven't checked in for 1 day");
      await _toTop(tester);
    },
  ),
  const _Screen('home (checklist)', signedIn: true, route: AppRoutes.home),
  _Screen(
    'home (ready to turn on)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) => _withContacts(fakes, [testContact()]),
  ),
  _Screen(
    'home (turn on: something missing)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) {
      _withContacts(fakes, [testContact()]);
      // No plan has been saved, so the server also says no_stages.
      fakes.server.extraRequirements = ['future_code'];
    },
    prepare: (tester, _) async {
      await tapText(tester, 'Turn on check-ins');
      await tester.pumpAndSettle();
    },
  ),
  _Screen(
    'home (active)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) {
      _activeHome(fakes);
      fakes.server.lastCheckinAt = DateTime.utc(2026, 10, 8, 11, 30);
    },
  ),
  _Screen(
    'home (due soon, contact pending)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) {
      _withContacts(fakes, [testContact(status: VerificationStatus.pending)]);
      fakes.plan.seedStandard(['c1']);
      fakes.server
        ..activateNow()
        ..nextDueAt = fakes.server.now.add(const Duration(minutes: 45));
    },
  ),
  _Screen(
    'home (overdue)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) {
      _activeHome(fakes);
      fakes.server.nextDueAt = fakes.server.now.subtract(
        const Duration(minutes: 5),
      );
    },
  ),
  _Screen(
    'home (contact declined)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) {
      _withContacts(fakes, _everyone());
      fakes.plan.seedStandard(['c1']);
      fakes.server.activateNow();
    },
  ),
  _Screen(
    'home (no trusted contact: nobody would be told)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) => _gapHome(fakes, emptyStage: true),
    prepare: (tester, _) async => _expectGap(_gapNoContacts),
  ),
  _Screen(
    'home (plan has no stage)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) => _gapHome(fakes, contacts: [testContact()]),
    prepare: (tester, _) async => _expectGap(_gapNoStages),
  ),
  _Screen(
    'home (a stage tells nobody)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) =>
        _gapHome(fakes, contacts: [testContact()], emptyStage: true),
    prepare: (tester, _) async => _expectGap(_gapStageEmpty),
  ),
  _Screen(
    'home (gap, contact pending, due soon)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) {
      _gapHome(
        fakes,
        contacts: [testContact(status: VerificationStatus.pending)],
      );
      fakes.server.nextDueAt = fakes.server.now.add(
        const Duration(minutes: 45),
      );
    },
  ),
  _Screen(
    'home (gap, contact declined, offline, not received yet)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) {
      _gapHome(
        fakes,
        contacts: [testContact(status: VerificationStatus.declined)],
      );
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
    },
    prepare: (tester, container) async {
      // A tap that is not received, then a refresh that fails: every banner at once.
      await _tapCheckIn(tester);
      final server =
          container.read(checkInRepositoryProvider) as FakeCheckInServer;
      server.failures['home'] = [const NetworkFailure()];
      await container.read(homeControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();
      await _toTop(tester);
      _expectGap(_gapNoStages);
      expect(find.text('Offline — showing last known status'), findsOneWidget);
      expect(find.text("Not received yet — we'll keep trying"), findsOneWidget);
    },
  ),
  _Screen(
    'home (gap, earlier check-in expired)',
    signedIn: true,
    route: AppRoutes.home,
    prefs: _signedInAsUser1,
    configure: (fakes) {
      _gapHome(fakes, contacts: [testContact()]);
      _staleTap(fakes);
    },
    prepare: (tester, _) async {
      _expectExpiredNotice();
      _expectGap(_gapNoStages);
    },
  ),
  _Screen(
    'home (checked in)',
    signedIn: true,
    route: AppRoutes.home,
    configure: _activeHome,
    prepare: (tester, _) => _tapCheckIn(tester),
  ),
  _Screen(
    'home (not received yet)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) {
      _activeHome(fakes);
      fakes.server.failures['checkIn'] = [const NetworkFailure()];
    },
    prepare: (tester, _) => _tapCheckIn(tester),
  ),
  _Screen(
    'home (rate limited)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) {
      _activeHome(fakes);
      fakes.server.failures['checkIn'] = [
        const RateLimitedFailure(retryAfter: Duration(minutes: 20)),
      ];
    },
    prepare: (tester, _) => _tapCheckIn(tester),
  ),
  _Screen(
    'home (earlier check-in expired)',
    signedIn: true,
    route: AppRoutes.home,
    prefs: _signedInAsUser1,
    configure: (fakes) {
      _activeHome(fakes);
      _staleTap(fakes);
    },
    prepare: (tester, _) async => _expectExpiredNotice(),
  ),
  _Screen(
    'home (cannot load, earlier check-in expired)',
    signedIn: true,
    route: AppRoutes.home,
    prefs: _signedInAsUser1,
    configure: (fakes) {
      fakes.server.failures['home'] = [
        const NetworkFailure(),
        const NetworkFailure(),
      ];
      _staleTap(fakes);
    },
    prepare: (tester, _) async => _expectExpiredNotice(),
  ),
  _Screen(
    'home (offline, last known status)',
    signedIn: true,
    route: AppRoutes.home,
    configure: _activeHome,
    prepare: (tester, container) async {
      // The next read fails: the screen keeps the last good state and says so.
      final server =
          container.read(checkInRepositoryProvider) as FakeCheckInServer;
      server.failures['home'] = [const NetworkFailure()];
      await container.read(homeControllerProvider.notifier).refresh();
      await tester.pumpAndSettle();
    },
  ),
  _Screen(
    'home (cannot load, I\'M OK still works)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) => fakes.server.failures['home'] = [
      const NetworkFailure(),
      const NetworkFailure(),
    ],
  ),
  _Screen(
    'home (incident placeholder)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) {
      _activeHome(fakes);
      fakes.server.openIncident(details: {'id': 'i-1'});
    },
  ),
  _Screen(
    'home (confirm you\'re safe)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) {
      _activeHome(fakes);
      fakes.server
        ..openIncident(details: {'id': 'i-1'})
        ..contactsMessaged = true;
    },
    prepare: (tester, _) => _tapCheckIn(tester),
  ),
  _Screen(
    'home (status this version does not know)',
    signedIn: true,
    route: AppRoutes.home,
    configure: (fakes) {
      _activeHome(fakes);
      fakes.server.status = CheckInStatus.unknown;
    },
  ),
  const _Screen(
    'settings > check-in schedule (off)',
    signedIn: true,
    route: AppRoutes.settingsSchedule,
  ),
  _Screen(
    'settings > check-in schedule (on, unsaved change)',
    signedIn: true,
    route: AppRoutes.settingsSchedule,
    configure: _activeHome,
    prepare: (tester, _) async {
      await tapText(tester, 'Every week');
      await _toTop(tester);
    },
  ),
  _Screen(
    'settings > check-in schedule (incident, locked)',
    signedIn: true,
    route: AppRoutes.settingsSchedule,
    configure: (fakes) {
      _activeHome(fakes);
      fakes.server.openIncident();
    },
  ),
  _Screen(
    'settings > check-in schedule (changed elsewhere)',
    signedIn: true,
    route: AppRoutes.settingsSchedule,
    configure: (fakes) => fakes.server.failures['save'] = [
      const ConflictFailure(code: 'precondition_failed'),
    ],
    prepare: (tester, _) async {
      await tapText(tester, 'Every week');
      await tapText(tester, 'Save changes');
      await tester.pumpAndSettle();
      await _toTop(tester);
    },
  ),
  _Screen(
    'settings > check-in schedule: turn off dialog',
    signedIn: true,
    route: AppRoutes.settingsSchedule,
    configure: _activeHome,
    prepare: (tester, _) async {
      await tapText(tester, 'Turn off check-ins');
      await tester.pumpAndSettle();
    },
  ),
  _Screen(
    'settings > check-in schedule: password sheet',
    signedIn: true,
    route: AppRoutes.settingsSchedule,
    configure: _activeHome,
    prepare: (tester, _) async {
      await tapText(tester, 'Turn off check-ins');
      await tester.pumpAndSettle();
      await tapText(tester, 'Turn off');
      await _frames(tester);
    },
  ),
  _Screen(
    'settings > check-in schedule: password sheet (longer interval)',
    signedIn: true,
    route: AppRoutes.settingsSchedule,
    configure: _activeHome,
    prepare: (tester, _) async {
      await tapText(tester, 'Every week');
      await tapText(tester, 'Save changes');
      await _frames(tester);
    },
  ),
  _Screen(
    'plan step: password sheet (active account)',
    signedIn: true,
    route: OnboardingStep.plan.path,
    configure: _activeHome,
    prepare: (tester, _) async {
      await tapText(tester, '6 hours');
      await tapText(tester, 'Use this plan');
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
    },
  ),
  _Screen(
    'contact detail: password sheet (remove someone who is told)',
    signedIn: true,
    route: AppRoutes.contactDetail('c1'),
    configure: _activeHome,
    prepare: (tester, _) async {
      await tapText(tester, 'Remove');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
    },
  ),
  _Screen(
    'edit contact: password sheet (email of someone who is told)',
    signedIn: true,
    route: AppRoutes.contactEdit('c1'),
    configure: _activeHome,
    prepare: (tester, _) async {
      await typeInto(tester, 'Their email', 'mum@example.com');
      await tapText(tester, 'Save changes');
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
    },
  ),
  _Screen(
    'settings > check-in schedule (cannot load)',
    signedIn: true,
    route: AppRoutes.settingsSchedule,
    configure: (fakes) =>
        fakes.server.failures['get'] = [const NetworkFailure()],
  ),
  _Screen(
    'settings > check-in history (rows and Show more)',
    signedIn: true,
    route: AppRoutes.settingsCheckInHistory,
    configure: (fakes) {
      for (var i = 0; i < 22; i++) {
        fakes.server.addHistory(
          CheckInHistoryItem(
            id: 'h$i',
            kind: i == 3 ? CheckInKind.safe : CheckInKind.ok,
            source: i.isEven ? CheckInSource.app : CheckInSource.web,
            receivedAt: DateTime.utc(
              2026,
              10,
              8,
              12,
            ).subtract(Duration(days: i)),
          ),
        );
      }
    },
  ),
  const _Screen(
    'settings > check-in history (empty)',
    signedIn: true,
    route: AppRoutes.settingsCheckInHistory,
  ),
  _Screen(
    'settings > check-in history (error)',
    signedIn: true,
    route: AppRoutes.settingsCheckInHistory,
    configure: (fakes) =>
        fakes.server.failures['history'] = [const NetworkFailure()],
  ),
  _Screen(
    'onboarding: done (check-ins turned on)',
    signedIn: true,
    step: OnboardingStep.done,
    configure: (fakes) {
      _withContacts(fakes, [testContact()]);
      fakes.plan.seedStandard(['c1']);
    },
  ),
  // No contact and no plan: both ways out are offered.
  const _Screen(
    'onboarding: done (contact and plan missing)',
    signedIn: true,
    step: OnboardingStep.done,
  ),
  _Screen(
    'onboarding: done (a plan stage is missing)',
    signedIn: true,
    step: OnboardingStep.done,
    configure: (fakes) => _withContacts(fakes, [testContact()]),
  ),
  _Screen(
    'onboarding: done (a stage that tells no one)',
    signedIn: true,
    step: OnboardingStep.done,
    configure: (fakes) {
      _withContacts(fakes, [testContact()]);
      fakes.plan.seed(
        const PlanDraft(
          graceMinutes: 180,
          stages: [PlanStageDraft(offsetMinutes: 180, contactIds: [])],
        ),
      );
    },
  ),
  const _Screen(
    'plan tab (no stages yet)',
    signedIn: true,
    route: AppRoutes.plan,
  ),
  _Screen(
    'plan tab (two stages)',
    signedIn: true,
    route: AppRoutes.plan,
    configure: (fakes) {
      _withContacts(fakes, _everyone());
      fakes.plan.seed(
        const PlanDraft(
          graceMinutes: 180,
          stages: [
            PlanStageDraft(offsetMinutes: 180, contactIds: ['c1', 'c2']),
            PlanStageDraft(offsetMinutes: 1440, contactIds: ['c3']),
          ],
        ),
      );
    },
  ),
  _Screen(
    'plan tab (cannot load)',
    signedIn: true,
    route: AppRoutes.plan,
    configure: (fakes) => fakes.plan.failures['get'] = [const NetworkFailure()],
  ),
  const _Screen('settings', signedIn: true, route: AppRoutes.settings),
  const _Screen('profile', signedIn: true, route: AppRoutes.settingsProfile),
  _Screen(
    'profile (timezone suggestion)',
    signedIn: true,
    route: AppRoutes.settingsProfile,
    configure: (fakes) =>
        fakes.device.deviceTimezone = 'America/Argentina/Buenos_Aires',
  ),
  const _Screen('security', signedIn: true, route: AppRoutes.settingsSecurity),
  const _Screen(
    'change password',
    signedIn: true,
    route: AppRoutes.settingsChangePassword,
  ),
  _Screen(
    'change password (errors)',
    signedIn: true,
    route: AppRoutes.settingsChangePassword,
    prepare: (tester, _) async {
      await tapText(tester, 'Change password');
    },
  ),
  const _Screen(
    'change email',
    signedIn: true,
    route: AppRoutes.settingsChangeEmail,
  ),
  _Screen(
    'change email (code)',
    signedIn: true,
    route: AppRoutes.settingsChangeEmail,
    prepare: (tester, container) async {
      authOf(container).reauthenticated = true;
      await typeInto(tester, 'New email address', 'new@example.com');
      await tapText(tester, 'Send the code');
      await tester.pumpAndSettle();
    },
  ),
  const _Screen('sessions', signedIn: true, route: AppRoutes.settingsSessions),
  const _Screen(
    'app lock (off)',
    signedIn: true,
    route: AppRoutes.settingsAppLock,
  ),
  const _Screen(
    'app lock (on)',
    signedIn: true,
    route: AppRoutes.settingsAppLock,
    prefs: {'afterme.appLockEnabled': true},
  ),
  const _Screen(
    'notifications',
    signedIn: true,
    route: AppRoutes.settingsNotifications,
  ),
  const _Screen('about', signedIn: true, route: AppRoutes.settingsAbout),
  _Screen(
    'timezone picker',
    signedIn: true,
    route: AppRoutes.settingsProfile,
    prepare: (tester, _) async {
      await tapText(tester, 'Timezone');
      await tester.pumpAndSettle();
    },
  ),
  _Screen(
    'country picker',
    signedIn: true,
    route: AppRoutes.settingsProfile,
    prepare: (tester, _) async {
      await tapText(tester, 'Country');
      await tester.pumpAndSettle();
    },
  ),
  _Screen(
    'sign out dialog',
    signedIn: true,
    route: AppRoutes.settings,
    prepare: (tester, _) async {
      await tapText(tester, 'Sign out');
      await tester.pumpAndSettle();
    },
  ),
  _Screen(
    'lock screen',
    signedIn: true,
    route: AppRoutes.home,
    prefs: const {'afterme.appLockEnabled': true},
    configure: (fakes) => fakes.localAuth.outcomes.add(AuthOutcome.failed),
  ),
  _Screen(
    'lock screen (no screen lock)',
    signedIn: true,
    route: AppRoutes.home,
    prefs: const {'afterme.appLockEnabled': true},
    configure: (fakes) {
      fakes.localAuth.lockCapability = LockCapability.noScreenLock;
      fakes.localAuth.outcomes.add(AuthOutcome.notAvailable);
    },
  ),
];

Future<ProviderContainer> _open(
  WidgetTester tester,
  _Screen screen, {
  required Size size,
  required double textScale,
  Brightness brightness = Brightness.light,
}) async {
  final fakes = TestFakes();
  fakes.prefs = freshPreferences({
    if (screen.step != null) ...{
      'afterme.onboardingUserId': 'user-1',
      'afterme.onboardingCompleted': false,
      'afterme.onboardingStep': screen.step!.name,
    },
    ...screen.prefs,
  });
  screen.configure?.call(fakes);
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  final container = await pumpAfterMe(
    tester,
    fakes: fakes,
    status: screen.signedIn ? AuthStatus.signedIn : AuthStatus.signedOut,
    size: size,
    textScale: textScale,
    // Real Roboto glyph widths (the test engine's default font is a wide square one).
    extraOverrides: [fontFamilyProvider.overrideWithValue('Roboto')],
  );
  if (screen.route != null) {
    container.read(routerProvider).go(screen.route!);
    await tester.pumpAndSettle();
  }
  if (screen.prepare != null) {
    await screen.prepare!(tester, container);
  }
  await _frames(tester);
  return container;
}

/// A line break inside a word: two neighbouring characters, neither of them whitespace
/// (or a hyphen/slash, where breaking is allowed), sit on different lines. That only
/// happens when one word is wider than the available width and the engine splits it.
void _expectNoMidWordBreaks(WidgetTester tester, String reason) {
  bool breakAllowed(String c) => RegExp(r'[\s\-/]').hasMatch(c);
  for (final element in find.byType(Text).evaluate()) {
    final render = element.renderObject;
    if (render is! RenderParagraph || !render.attached || !render.hasSize) {
      continue;
    }
    final text = render.text.toPlainText();
    double? previousTop;
    for (var i = 0; i < text.length; i++) {
      // `max` boxes span the whole line height, so characters of one line share a top.
      final boxes = render.getBoxesForSelection(
        TextSelection(baseOffset: i, extentOffset: i + 1),
        boxHeightStyle: ui.BoxHeightStyle.max,
      );
      if (boxes.isEmpty) {
        previousTop = null;
        continue;
      }
      final top = boxes.first.top;
      if (previousTop != null && top > previousTop + 1) {
        expect(
          breakAllowed(text[i - 1]) || breakAllowed(text[i]),
          isTrue,
          reason:
              '$reason: "$text" is broken inside a word at "${text[i - 1]}|${text[i]}"',
        );
      }
      previousTop = top;
    }
  }
}

void main() {
  setUpAll(loadRoboto);

  const sizes = {
    'Galaxy 360x780': Size(360, 780),
    'small 320x690': Size(320, 690),
  };

  group('2.0 text scale, real Roboto: no overflow, no mid-word breaks', () {
    for (final screen in _screens) {
      for (final MapEntry(key: sizeName, value: size) in sizes.entries) {
        testWidgets('${screen.name} on $sizeName', (tester) async {
          await _open(tester, screen, size: size, textScale: 2);
          expect(tester.takeException(), isNull);
          _expectNoMidWordBreaks(tester, '${screen.name} on $sizeName');
        });
      }
    }
  });

  // The guidelines only measure semantics nodes that are on screen, so a tall surface
  // (the whole scroll content built and visible: consent boxes, legal links, submit and
  // sign-out buttons at the end of long forms) is checked next to the realistic phone.
  //
  // The contrast guideline samples the screen at 1 pixel per dp. A tall surface centres
  // short pages, which can put small text on a half pixel and blur its thin strokes below
  // 4.5:1 even though the colours pass. That depends only on the parity of the surface
  // height, so a failure on the tall surface is checked once more one dp taller; a real
  // contrast, size or label problem fails both.
  group('accessibility guidelines', () {
    const surfaces = {
      'tall 360x2800': Size(360, 2800),
      'Galaxy 360x780': Size(360, 780),
    };
    Future<void> check(
      WidgetTester tester,
      _Screen screen,
      Size size,
      Brightness brightness,
    ) async {
      await _open(
        tester,
        screen,
        size: size,
        textScale: 1,
        brightness: brightness,
      );
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    }

    for (final screen in _screens) {
      for (final MapEntry(key: surfaceName, value: size) in surfaces.entries) {
        for (final (modeName, brightness) in [
          ('light', Brightness.light),
          ('dark', Brightness.dark),
        ]) {
          testWidgets('${screen.name} ($modeName, $surfaceName)', (
            tester,
          ) async {
            final handle = tester.ensureSemantics();
            try {
              await check(tester, screen, size, brightness);
            } on TestFailure {
              if (size.height < 1000) {
                rethrow;
              }
              await check(
                tester,
                screen,
                Size(size.width, size.height + 1),
                brightness,
              );
            }
            handle.dispose();
          });
        }
      }
    }
  });
}
