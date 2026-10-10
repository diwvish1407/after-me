import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/core/platform/contact_picker.dart';
import 'package:afterme/core/security/app_lock/app_lock_controller.dart';
import 'package:afterme/core/security/app_lock/local_auth_gateway.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:afterme/features/onboarding/application/setup_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/fake_platform.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

/// Starts the app signed in with onboarding at [step] (as after sign-up).
Future<ProviderContainer> _atStep(
  WidgetTester tester,
  OnboardingStep step, {
  TestFakes? fakes,
  List<Override> extra = const [],
}) async {
  final f = fakes ?? TestFakes();
  f.prefs = freshPreferences({
    'afterme.onboardingUserId': 'user-1',
    'afterme.onboardingCompleted': false,
    'afterme.onboardingStep': step.name,
  });
  return pumpAfterMe(
    tester,
    fakes: f,
    status: AuthStatus.signedIn,
    extraOverrides: extra,
  );
}

Finder _field(String label) => find.widgetWithText(TextField, label);

/// A few frames. `pumpAndSettle` cannot be used while a button shows its busy spinner
/// behind the password sheet: an indeterminate indicator never settles.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _addContact(WidgetTester tester) async {
  await typeInto(tester, 'Their name', 'Mom');
  await tapText(tester, 'Parent');
  await typeInto(tester, 'Their email', 'mom@example.com');
  await tapText(tester, 'Save and continue');
  await tester.pumpAndSettle();
}

void main() {
  group('routing and progress', () {
    testWidgets('resumes at the saved step after a relaunch', (tester) async {
      await _atStep(tester, OnboardingStep.plan);
      expect(find.text('Your plan'), findsOneWidget);
      expect(find.text('Step 6 of 9'), findsOneWidget);
    });

    testWidgets('other signed-in routes lead back to the saved step', (
      tester,
    ) async {
      final container = await _atStep(tester, OnboardingStep.schedule);
      container.read(routerProvider).go(AppRoutes.home);
      await tester.pumpAndSettle();
      expect(find.text('When should you check in?'), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });

    testWidgets('the step indicator is announced', (tester) async {
      final handle = tester.ensureSemantics();
      await _atStep(tester, OnboardingStep.contact);
      expect(find.bySemanticsLabel('Step 4 of 9'), findsOneWidget);
      handle.dispose();
    });
  });

  group('contact step', () {
    testWidgets('needs a name, a relationship and an email', (tester) async {
      final fakes = TestFakes();
      await _atStep(tester, OnboardingStep.contact, fakes: fakes);
      await tapText(tester, 'Save and continue');
      expect(
        tester.widget<TextField>(_field('Their name')).decoration?.errorText,
        'Please fill this in.',
      );
      expect(
        tester.widget<TextField>(_field('Their email')).decoration?.errorText,
        'Please fill this in.',
      );
      expect(find.text('Choose how you know them.'), findsOneWidget);
      await typeInto(tester, 'Their email', 'bad');
      await tapText(tester, 'Save and continue');
      expect(
        tester.widget<TextField>(_field('Their email')).decoration?.errorText,
        'Enter a valid email address.',
      );
    });

    testWidgets('saves the contact, explains the invitation and moves on', (
      tester,
    ) async {
      final fakes = TestFakes();
      final container = await _atStep(
        tester,
        OnboardingStep.contact,
        fakes: fakes,
      );
      expect(
        find.textContaining("They'll get an invitation to accept first"),
        findsOneWidget,
      );
      await _addContact(tester);
      expect(find.text('When should you check in?'), findsOneWidget);
      final setup = container.read(setupControllerProvider).value!;
      expect(setup.contacts.single.displayName, 'Mom');
      expect(setup.contacts.single.email, 'mom@example.com');
      expect(
        await fakes.prefs.getString(PreferenceKey.onboardingStep),
        'schedule',
        reason: 'progress is saved after the step',
      );
    });

    testWidgets('skip for now moves on without a contact', (tester) async {
      final container = await _atStep(tester, OnboardingStep.contact);
      await tapText(tester, 'Skip for now');
      await tester.pumpAndSettle();
      expect(find.text('When should you check in?'), findsOneWidget);
      expect(
        container.read(setupControllerProvider).value!.hasContact,
        isFalse,
      );
    });

    testWidgets(
      '"Pick from my contacts" fills the form from the system picker',
      (tester) async {
        final fakes = TestFakes();
        fakes.picker.result = const PickedContact(
          name: 'Brother',
          email: 'bro@example.com',
        );
        await _atStep(tester, OnboardingStep.contact, fakes: fakes);
        await tapText(tester, 'Pick from my contacts');
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(_field('Their name')).controller!.text,
          'Brother',
        );
        expect(
          tester.widget<TextField>(_field('Their email')).controller!.text,
          'bro@example.com',
        );
        expect(fakes.picker.picks, 1);
      },
    );

    testWidgets('cancelling the picker changes nothing; no picker says so', (
      tester,
    ) async {
      final fakes = TestFakes();
      await _atStep(tester, OnboardingStep.contact, fakes: fakes);
      await tapText(tester, 'Pick from my contacts');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_field('Their name')).controller!.text,
        '',
      );

      fakes.picker.unavailable = true;
      await tapText(tester, 'Pick from my contacts');
      await tester.pumpAndSettle();
      expect(
        find.textContaining("couldn't open your contacts"),
        findsOneWidget,
      );
    });

    testWidgets('the picker does not trigger the app lock', (tester) async {
      final fakes = TestFakes();
      fakes.prefs = freshPreferences({
        'afterme.onboardingUserId': 'user-1',
        'afterme.onboardingCompleted': false,
        'afterme.onboardingStep': 'contact',
        'afterme.appLockEnabled': true,
        'afterme.appLockTimeoutMinutes': 0,
      });
      fakes.localAuth.outcomes.add(AuthOutcome.canceled);
      final container = await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedIn,
      );
      await tester.pumpAndSettle();
      expect(
        container.read(appLockControllerProvider).locked,
        isTrue,
        reason: 'cold start',
      );
      await container.read(appLockControllerProvider.notifier).unlock('r');
      await tester.pumpAndSettle();
      fakes.picker.result = const PickedContact(
        name: 'B',
        email: 'b@example.com',
      );
      await tapText(tester, 'Pick from my contacts');
      await tester.pumpAndSettle();
      expect(container.read(appLockControllerProvider).locked, isFalse);
    });

    testWidgets('a failure to save is shown and the form is kept', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.contacts.failures['create'] = [const NetworkFailure()];
      await _atStep(tester, OnboardingStep.contact, fakes: fakes);
      await typeInto(tester, 'Their name', 'Mom');
      await tapText(tester, 'Friend');
      await typeInto(tester, 'Their email', 'mom@example.com');
      await tapText(tester, 'Save and continue');
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(
        tester.widget<TextField>(_field('Their name')).controller!.text,
        'Mom',
      );
      expect(
        find.text("Who should we tell if you don't check in?"),
        findsOneWidget,
      );
    });

    testWidgets('with a contact already added the step just continues', (
      tester,
    ) async {
      final container = await _atStep(tester, OnboardingStep.contact);
      await _addContact(tester);
      container.read(routerProvider).go(OnboardingStep.contact.path);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Mom will get an invitation to accept.'),
        findsOneWidget,
      );
      await tapText(tester, 'Continue');
      await tester.pumpAndSettle();
      expect(find.text('When should you check in?'), findsOneWidget);
    });
  });

  group('schedule step', () {
    testWidgets(
      'has big defaults: every day by 8:00 PM, reminder an hour before',
      (tester) async {
        await _atStep(tester, OnboardingStep.schedule);
        expect(find.text('8:00 PM'), findsWidgets);
        expect(find.text('Check in every day by 8:00 PM.'), findsOneWidget);
        expect(find.text("We'll remind you an hour before."), findsOneWidget);
        expect(find.text('Times are in Asia/Kolkata.'), findsOneWidget);
      },
    );

    testWidgets('interval and time can be changed and are saved', (
      tester,
    ) async {
      final container = await _atStep(tester, OnboardingStep.schedule);
      await tapText(tester, 'Every week');
      expect(find.text('Check in every week by 8:00 PM.'), findsOneWidget);
      await tapText(tester, '8:00 PM');
      await tester.pumpAndSettle();
      // The time picker's dial: pick via keyboard entry is fiddly; accept the default OK.
      expect(find.byType(TimePickerDialog), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tapText(tester, 'Save schedule');
      await tester.pumpAndSettle();
      final schedule = container.read(setupControllerProvider).value!.schedule!;
      expect(schedule.intervalDays, 7);
      expect(schedule.dueMinutes, 20 * 60);
      expect(schedule.timezone, 'Asia/Kolkata');
      expect(find.text('Your plan'), findsOneWidget);
    });

    testWidgets('saves while check-ins are off without asking for the '
        'password', (tester) async {
      final fakes = TestFakes();
      final container = await _atStep(
        tester,
        OnboardingStep.schedule,
        fakes: fakes,
      );
      await tapText(tester, 'Every 3 days');
      await tapText(tester, 'Save schedule');
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsNothing);
      expect(fakes.auth.calls.where((c) => c == 'reauth'), isEmpty);
      expect(fakes.server.intervalDays, 3);
      expect(
        container.read(setupControllerProvider).value!.schedule!.intervalDays,
        3,
      );
      expect(find.text('Your plan'), findsOneWidget);
    });

    testWidgets('if the server ever asks for the password, the sheet appears '
        'and the same save is repeated', (tester) async {
      final fakes = TestFakes();
      fakes.server.failures['save'] = [
        const ForbiddenFailure(code: 'reauth_required'),
      ];
      await _atStep(tester, OnboardingStep.schedule, fakes: fakes);
      await tapText(tester, 'Every week');
      await tapText(tester, 'Save schedule');
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(find.textContaining('confirm your password'), findsNothing);
      expect(fakes.server.intervalDays, 1);

      await typeInto(tester, 'Password', fakes.auth.password);
      await tapText(tester, 'Confirm');
      await tester.pumpAndSettle();
      expect(fakes.server.intervalDays, 7);
      expect(fakes.server.calls.where((c) => c == 'save'), hasLength(2));
      expect(find.text('Your plan'), findsOneWidget);
    });

    testWidgets('closing the sheet keeps the person here with the edits and '
        'saves nothing', (tester) async {
      final fakes = TestFakes();
      fakes.server.failures['save'] = [
        const ForbiddenFailure(code: 'reauth_required'),
      ];
      await _atStep(tester, OnboardingStep.schedule, fakes: fakes);
      await tapText(tester, 'Every week');
      await tapText(tester, 'Save schedule');
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsNothing);
      expect(find.text('When should you check in?'), findsOneWidget);
      expect(find.text('Check in every week by 8:00 PM.'), findsOneWidget);
      expect(fakes.server.intervalDays, 1);
      expect(find.textContaining('confirm your password'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save schedule'),
            )
            .onPressed,
        isNotNull,
        reason: 'not stuck busy',
      );

      // Saving again works (the server asks no more).
      await tapText(tester, 'Save schedule');
      await tester.pumpAndSettle();
      expect(fakes.server.intervalDays, 7);
      expect(find.text('Your plan'), findsOneWidget);
    });

    testWidgets('dismissing the time picker keeps the time', (tester) async {
      await _atStep(tester, OnboardingStep.schedule);
      await tapText(tester, '8:00 PM');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Check in every day by 8:00 PM.'), findsOneWidget);
    });

    testWidgets('is not skippable', (tester) async {
      await _atStep(tester, OnboardingStep.schedule);
      expect(find.text('Skip for now'), findsNothing);
    });
  });

  group('plan step', () {
    testWidgets('without a contact it explains and offers to add one', (
      tester,
    ) async {
      await _atStep(tester, OnboardingStep.plan);
      expect(
        find.textContaining("haven't added a trusted contact"),
        findsOneWidget,
      );
      await tapText(tester, 'Add a trusted contact');
      await tester.pumpAndSettle();
      expect(
        find.text("Who should we tell if you don't check in?"),
        findsOneWidget,
      );
    });

    testWidgets(
      'adding a contact from here returns to this step and keeps the progress',
      (tester) async {
        final fakes = TestFakes();
        final container = await _atStep(
          tester,
          OnboardingStep.plan,
          fakes: fakes,
        );
        await tapText(tester, 'Add a trusted contact');
        await tester.pumpAndSettle();
        await _addContact(tester);
        expect(find.text('Your plan'), findsOneWidget);
        expect(find.text('Step 6 of 9'), findsOneWidget);
        expect(
          container.read(onboardingControllerProvider).step,
          OnboardingStep.plan,
        );
        expect(
          await fakes.prefs.getString(PreferenceKey.onboardingStep),
          'plan',
        );
        expect(find.text('At 11:00 PM, Mom is notified.'), findsOneWidget);
      },
    );

    testWidgets('previews the plan in plain words with the contact name', (
      tester,
    ) async {
      final container = await _atStep(tester, OnboardingStep.contact);
      await _addContact(tester);
      await tapText(tester, 'Save schedule');
      await tester.pumpAndSettle();
      expect(find.text('Standard plan'), findsOneWidget);
      expect(
        find.text('If you miss 8:00 PM, we remind you first.'),
        findsOneWidget,
      );
      expect(find.text('At 11:00 PM, Mom is notified.'), findsOneWidget);
      expect(find.text('Checking in before then stops it.'), findsOneWidget);

      await tapText(tester, '6 hours');
      expect(
        find.text('At 2:00 AM the next day, Mom is notified.'),
        findsOneWidget,
      );
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      expect(
        container.read(setupControllerProvider).value!.plan!.graceMinutes,
        360,
      );
      expect(find.text('Add a first instruction'), findsOneWidget);
    });

    testWidgets(
      'can be skipped, and continuing without a contact skips saving',
      (tester) async {
        final container = await _atStep(tester, OnboardingStep.plan);
        await tapText(tester, 'Continue');
        await tester.pumpAndSettle();
        expect(find.text('Add a first instruction'), findsOneWidget);
        expect(
          container.read(setupControllerProvider).value!.plan!.stages,
          isEmpty,
          reason: 'nothing was saved',
        );
      },
    );
  });

  group('instruction step', () {
    testWidgets('lists the six starters and a prominent skip', (tester) async {
      await _atStep(tester, OnboardingStep.instruction);
      for (final title in [
        'Who to call first',
        'Home and keys',
        'Pets',
        'Work handover',
        'Where my documents are',
        'Insurance',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.textContaining("Don't write passwords here"), findsOneWidget);
      expect(find.text('Skip for now'), findsOneWidget);
    });

    testWidgets('skip moves on', (tester) async {
      await _atStep(tester, OnboardingStep.instruction);
      await tapText(tester, 'Skip for now');
      await tester.pumpAndSettle();
      expect(find.text('Stay protected'), findsOneWidget);
    });

    testWidgets('writing one: template, recipients, release stage, save', (
      tester,
    ) async {
      final container = await _atStep(tester, OnboardingStep.contact);
      await _addContact(tester);
      container.read(routerProvider).go(OnboardingStep.instruction.path);
      await tester.pumpAndSettle();

      await tapText(tester, 'Home and keys');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_field('Title')).controller!.text,
        'Home and keys',
      );
      expect(
        find.text('If you haven\'t checked in for 2 days'),
        findsOneWidget,
      );
      await tapText(tester, "If you haven't checked in for 3 days");
      await typeInto(tester, 'Title', 'House keys');
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();

      final setup = container.read(setupControllerProvider).value!;
      expect(setup.instructions.single.title, 'House keys');
      expect(setup.instructions.single.releaseAfterHours, 72);
      expect(setup.instructions.single.recipientContactIds, [
        setup.contacts.single.id,
      ]);
      expect(find.text('Stay protected'), findsOneWidget);
    });

    testWidgets('title and body are required; a recipient is required', (
      tester,
    ) async {
      final container = await _atStep(tester, OnboardingStep.contact);
      await _addContact(tester);
      container.read(routerProvider).go(OnboardingStep.instruction.path);
      await tester.pumpAndSettle();
      await tapText(tester, 'Pets');
      await tester.pumpAndSettle();
      await typeInto(tester, 'Title', '');
      await tapText(tester, 'Save instruction');
      expect(
        tester.widget<TextField>(_field('Title')).decoration?.errorText,
        'Please fill this in.',
      );

      await typeInto(tester, 'Title', 'Pets');
      await tester.enterText(
        find.widgetWithText(TextField, 'What should they know?'),
        '',
      );
      await tester.pump();
      await tapText(tester, 'Save instruction');
      expect(find.text('Please fill this in.'), findsWidgets);

      await tester.enterText(
        find.widgetWithText(TextField, 'What should they know?'),
        'Feed twice',
      );
      await tester.pump();
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'Mom'),
          )
          .onChanged!(false);
      await tester.pump();
      expect(find.text('Choose at least one person.'), findsOneWidget);
      await tapText(tester, 'Save instruction');
      expect(
        container.read(setupControllerProvider).value!.instructions,
        isEmpty,
      );
    });

    testWidgets('without a contact it cannot be saved and says why', (
      tester,
    ) async {
      await _atStep(tester, OnboardingStep.instruction);
      await tapText(tester, 'Insurance');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Add a trusted contact first'),
        findsOneWidget,
      );
      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save instruction'),
      );
      expect(save.onPressed, isNull);
      await tapText(tester, 'Choose a different starter');
      expect(find.text('Who to call first'), findsOneWidget);
    });

    testWidgets('after saving, returning shows what was saved', (tester) async {
      final container = await _atStep(tester, OnboardingStep.contact);
      await _addContact(tester);
      container.read(routerProvider).go(OnboardingStep.instruction.path);
      await tester.pumpAndSettle();
      await tapText(tester, 'Pets');
      await tester.pumpAndSettle();
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      container.read(routerProvider).go(OnboardingStep.instruction.path);
      await tester.pumpAndSettle();
      expect(find.textContaining('Saved: Pets'), findsOneWidget);
      await tapText(tester, 'Continue');
      await tester.pumpAndSettle();
      expect(find.text('Stay protected'), findsOneWidget);
    });
  });

  group('protect step', () {
    testWidgets('app lock, notifications and the battery tip', (tester) async {
      final fakes = TestFakes();
      final container = await _atStep(
        tester,
        OnboardingStep.protect,
        fakes: fakes,
      );
      expect(find.text('Require unlock'), findsOneWidget);
      expect(find.text('Reminders'), findsOneWidget);
      expect(find.textContaining('battery'), findsWidgets);

      await tester.ensureVisible(find.byType(Switch));
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(container.read(appLockControllerProvider).enabled, isTrue);

      expect(
        fakes.notifications.requests,
        0,
        reason: 'explained before asking',
      );
      await tapText(tester, 'Allow notifications');
      await tester.pumpAndSettle();
      expect(fakes.notifications.requests, 1);
      expect(find.text('Notifications are on.'), findsOneWidget);
    });

    testWidgets('no screen lock: explains and leaves the lock off', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.localAuth.lockCapability = LockCapability.noScreenLock;
      final container = await _atStep(
        tester,
        OnboardingStep.protect,
        fakes: fakes,
      );
      await tester.ensureVisible(find.byType(Switch));
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(container.read(appLockControllerProvider).enabled, isFalse);
      expect(find.textContaining('has no screen lock yet'), findsOneWidget);
    });

    testWidgets('an unconfirmed lock change is explained; turning off works', (
      tester,
    ) async {
      final fakes = TestFakes();
      final container = await _atStep(
        tester,
        OnboardingStep.protect,
        fakes: fakes,
      );
      fakes.localAuth.outcomes.add(AuthOutcome.canceled);
      await tester.ensureVisible(find.byType(Switch));
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(
        find.textContaining("couldn't confirm it was you"),
        findsOneWidget,
      );
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(container.read(appLockControllerProvider).enabled, isTrue);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(container.read(appLockControllerProvider).enabled, isFalse);
      // Enabling again with a failed confirmation changes nothing.
      fakes.localAuth.outcomes.add(AuthOutcome.failed);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(container.read(appLockControllerProvider).enabled, isFalse);
      expect(
        find.textContaining("couldn't confirm it was you"),
        findsOneWidget,
      );
    });

    testWidgets(
      'a denied permission can be asked again; a blocked one opens settings',
      (tester) async {
        final fakes = TestFakes(
          notifications: FakeNotificationPermissionGateway(
            afterRequest: NotificationPermission.denied,
          ),
        );
        await _atStep(tester, OnboardingStep.protect, fakes: fakes);
        await tapText(tester, 'Allow notifications');
        await tester.pumpAndSettle();
        expect(find.text('Notifications are off.'), findsOneWidget);
        expect(
          find.text('Allow notifications'),
          findsOneWidget,
          reason: 'can ask again',
        );

        fakes.notifications.afterRequest =
            NotificationPermission.permanentlyDenied;
        await tapText(tester, 'Allow notifications');
        await tester.pumpAndSettle();
        expect(find.text('Allow notifications'), findsNothing);
        await tapText(tester, 'Open phone settings');
        expect(fakes.notifications.settingsOpened, 1);
      },
    );

    testWidgets(
      'coming back from the system settings shows the new notification status',
      (tester) async {
        final fakes = TestFakes(
          notifications: FakeNotificationPermissionGateway(
            current: NotificationPermission.permanentlyDenied,
          ),
        );
        await _atStep(tester, OnboardingStep.protect, fakes: fakes);
        expect(find.text('Open phone settings'), findsOneWidget);
        fakes.notifications.current = NotificationPermission.granted;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(find.text('Notifications are on.'), findsOneWidget);
        expect(find.text('Open phone settings'), findsNothing);
      },
    );

    testWidgets('continue moves to the last step', (tester) async {
      await _atStep(tester, OnboardingStep.protect);
      await tapText(tester, 'Continue');
      await tester.pumpAndSettle();
      expect(find.text('Almost there'), findsOneWidget);
    });
  });

  group('done step', () {
    Future<ProviderContainer> allSetUp(
      WidgetTester tester,
      TestFakes fakes,
    ) async {
      final container = await _atStep(
        tester,
        OnboardingStep.contact,
        fakes: fakes,
      );
      await _addContact(tester);
      await tapText(tester, 'Save schedule');
      await tester.pumpAndSettle();
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      await tapText(tester, 'Skip for now');
      await tester.pumpAndSettle();
      await tapText(tester, 'Continue');
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets(
      'asks the server to activate, says the invitation went out and that '
      'instructions are a preview',
      (tester) async {
        final fakes = TestFakes();
        final container = await allSetUp(tester, fakes);
        expect(find.text("You're set"), findsOneWidget);
        expect(
          find.text(
            'Check-ins are on. Mom has been sent an invitation. Instructions are still a preview, so nothing will be shared yet.',
          ),
          findsOneWidget,
        );
        expect(fakes.server.calls.where((c) => c == 'activate'), hasLength(1));
        expect(fakes.server.status, CheckInStatus.active);
        expect(
          container.read(setupControllerProvider).value!.scheduleActive,
          isTrue,
        );
        expect(find.text('Mom (parent) is invited'), findsOneWidget);
        expect(find.text('Check in every day by 8:00 PM.'), findsOneWidget);
        expect(
          find.text('We wait 3 hours before telling your contact'),
          findsOneWidget,
        );
        expect(find.text('No instruction yet (optional)'), findsOneWidget);
      },
    );

    testWidgets('Go to Home finishes onboarding for good', (tester) async {
      final fakes = TestFakes();
      final container = await allSetUp(tester, fakes);
      await tapText(tester, 'Go to Home');
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text("You're checked in"), findsOneWidget);
      expect(find.text('Tomorrow · 8:00 PM'), findsOneWidget);
      expect(container.read(onboardingControllerProvider).completed, isTrue);
      expect(
        await fakes.prefs.getBool(PreferenceKey.onboardingCompleted),
        isTrue,
      );
    });

    testWidgets('with something missing it does not claim to be active', (
      tester,
    ) async {
      final container = await _atStep(tester, OnboardingStep.done);
      expect(find.text('Almost there'), findsOneWidget);
      expect(
        find.text(
          "Check-ins aren't on yet. Still needed: a trusted contact, a plan stage. You can finish from Home.",
        ),
        findsOneWidget,
      );
      expect(find.text('No trusted contact yet'), findsOneWidget);
      // The server always has a schedule; it is shown as it is.
      expect(find.text('Check in every day by 8:00 PM.'), findsOneWidget);
      expect(find.text('No plan yet'), findsOneWidget);
      expect(
        container.read(setupControllerProvider).value!.scheduleActive,
        isFalse,
      );
      await tapText(tester, 'Go to Home');
      await tester.pumpAndSettle();
      expect(find.text("Let's finish your plan"), findsOneWidget);
    });
  });

  group('home checklist', () {
    testWidgets('shows what is missing and opens the same steps', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.prefs = freshPreferences();
      await pumpAfterMe(tester, fakes: fakes, status: AuthStatus.signedIn);
      expect(find.text("Let's finish your plan"), findsOneWidget);
      expect(find.text('Add a trusted contact'), findsOneWidget);
      // The server always has a schedule: it is shown, with a way to change it.
      expect(find.text('Check in every day by 8:00 PM.'), findsOneWidget);
      expect(find.text('Change'), findsOneWidget);
      expect(find.text('Review your plan'), findsOneWidget);
      expect(find.text('Turn on check-ins'), findsOneWidget);

      await tapText(tester, 'Add');
      await tester.pumpAndSettle();
      expect(
        find.text("Who should we tell if you don't check in?"),
        findsOneWidget,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets(
      'completed items are ticked and the checklist disappears when done',
      (tester) async {
        final fakes = TestFakes();
        fakes.prefs = freshPreferences();
        final container = await pumpAfterMe(
          tester,
          fakes: fakes,
          status: AuthStatus.signedIn,
        );
        final c = container.read(setupControllerProvider.notifier);
        await container.read(setupControllerProvider.future);
        await tapText(tester, 'Add');
        await tester.pumpAndSettle();
        await _addContact(tester);
        expect(
          find.byType(HomeScreen),
          findsOneWidget,
          reason: 'a re-opened step returns Home',
        );
        expect(find.text('Add a trusted contact'), findsOneWidget);
        expect(find.bySemanticsLabel('Done'), findsNothing);
        expect(c, isNotNull);
      },
    );
  });
}
