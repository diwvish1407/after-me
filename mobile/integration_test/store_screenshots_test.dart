// The Play listing's phone screenshots (PLAY_STORE §5), captured from the real app.
// NOT part of the integration suite (its name does not match mob6*_test.dart): run it
// with tool/screenshots.sh, which starts a throwaway backend on its own port and
// database (`afterme_shots`), builds the dev flavor with SCREENSHOT_MODE=true, and drives
// this file with `flutter drive` and test_driver/screenshots_driver.dart, which crops and
// writes each capture to store/screenshots/.
//
// Fictional people only: Asha (the account), Meera (her trusted contact), Ravi (named in
// an instruction), `@example.com` addresses. Never real user data.
//
// The order of the files is the order of PLAY_STORE §5's list:
//   01 Home "You're checked in"      02 one tap on I'M OK
//   03 the plan                      04 who gets what (an instruction and its recipient)
//   05 the grace state (we remind you first)
//   06 the contact accepted          07 what AfterMe keeps (privacy)
import 'package:afterme/core/config/app_config.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/backend.dart';
import 'support/harness.dart';
import 'support/journeys.dart';

const _asha = 'Asha';
const _meera = 'Meera';

const _instruction = InstructionSpec(
  title: 'Looking after Biscuit',
  body:
      'Biscuit eats one cup of dry food at 8 AM and 6 PM. The bag is in the hall '
      'cupboard. Ravi next door has a spare key and knows his walk.',
);

/// The emulator never shows the system's notification dialog in these runs, so Home
/// would carry "Notifications are off" in every capture. A person who allowed
/// notifications, which is what the listing shows, does not see it: once onboarding is
/// done, this answers "granted" (it never opens a system dialog).
class _NotificationsAllowedLater implements NotificationPermissionGateway {
  bool granted = false;

  @override
  Future<NotificationPermission> status() async =>
      granted ? NotificationPermission.granted : NotificationPermission.denied;

  @override
  Future<NotificationPermission> request() => status();

  @override
  Future<bool> openSettings() async => false;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final backend = Backend.fromEnvironment();
  tearDownAll(backend.close);

  integrationTest('store screenshots', backend, (h) async {
    if (!AppConfig.fromEnvironment().screenshotMode) {
      await h.fail(
        'Run with --dart-define=SCREENSHOT_MODE=true (tool/screenshots.sh does): the '
        'screenshots must come from a screenshot build.',
      );
    }

    // On Android the Flutter surface has to become an image before it can be captured.
    await binding.convertFlutterSurfaceToImage();

    Future<void> shoot(String name) async {
      // Every capture shows its screen from the top (a tap may have scrolled it).
      for (final element in find.byType(Scrollable).evaluate()) {
        final state = (element as StatefulElement).state;
        if (state is ScrollableState &&
            state.position.pixels != state.position.minScrollExtent) {
          state.position.jumpTo(state.position.minScrollExtent);
        }
      }
      await h.settle(const Duration(milliseconds: 1500));
      final view = h.tester.view;
      // The "Screenshot mode" strip (README) takes the status-bar inset plus 20 dp at
      // the top: the driver cuts exactly that much, so the capture starts at the app.
      final strip = view.padding.top + 20 * view.devicePixelRatio;
      // (On Android takeScreenshot carries no arguments, so the crop rides in the name;
      // test_driver/screenshots_driver.dart reads it back and names the file without it.)
      await binding.takeScreenshot('$name@cropTop=${strip.ceil()}');
    }

    const account = TestAccount.fixed(
      email: 'asha@example.com',
      password: 'quiet harbour lantern 2026',
      contactEmail: 'meera@example.com',
    );
    final permission = _NotificationsAllowedLater();
    await h.launch(
      overrides: [
        notificationPermissionGatewayProvider.overrideWithValue(permission),
      ],
    );
    await signUpThroughUi(h, account, name: _asha);
    await onboardToActivePlan(
      h,
      account,
      contactName: _meera,
      relationship: l10n.relationshipFriend,
      instruction: _instruction,
    );

    permission.granted = true;
    await h.container
        .read(notificationPermissionControllerProvider.notifier)
        .refresh();

    // 01: Home, checked in and calm.
    await h.waitFor(find.text(l10n.checkInLabelIdle), reason: "I'M OK on Home");
    await h.tapText(l10n.checkInLabelIdle);
    await h.waitFor(
      find.text(l10n.checkInLabelSuccess),
      reason: '"Checked in" on the button',
      timeout: const Duration(seconds: 30),
    );
    // 02: one tap on I'M OK, the moment it is confirmed.
    await shoot('02_im_ok');
    await h.waitFor(
      find.textContaining(RegExp('Last check-in|Checked in')),
      reason: 'the last check-in on Home',
      onPoll: h.refreshHome,
    );
    await h.waitFor(
      find.text(l10n.homeStatusActiveTitle),
      reason: '"You\'re checked in"',
      onPoll: h.refreshHome,
    );
    await h.settle(
      const Duration(seconds: 4),
    ); // the success state settles back
    await shoot('01_home_checked_in');

    // 03: the plan, as a timeline.
    await h.tapTab(l10n.navPlan);
    await h.waitForTextContaining(_meera);
    await shoot('03_plan');

    // 04: who gets what: the instruction and who receives it, and when.
    await h.tapTab(l10n.navInstructions);
    // The tab asks for the password (a sheet), or says the list is hidden with a button
    // that asks for it, or (within five minutes of the last time) shows the list.
    bool showing(String text) => find.text(text).evaluate().isNotEmpty;
    await h.waitFor(
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data == l10n.reauthTitle ||
                w.data == l10n.instructionsShow ||
                w.data == _instruction.title),
      ),
      reason: 'the password sheet, the hidden list or the list',
    );
    if (!showing(l10n.reauthTitle) && showing(l10n.instructionsShow)) {
      await h.tapButton(l10n.instructionsShow);
      await h.waitForText(l10n.reauthTitle);
    }
    if (showing(l10n.reauthTitle)) {
      await h.typeInto(l10n.fieldPassword, account.password);
      await h.tapButton(l10n.reauthConfirm);
    }
    await h.waitForText(
      _instruction.title,
      timeout: const Duration(seconds: 30),
    );
    await h.tapText(_instruction.title);
    await h.waitForText(l10n.instructionDetailSharedWith);
    await shoot('04_who_gets_what');
    await h.tester.pageBack();
    await h.pump(const Duration(seconds: 1));

    // 06: the contact has accepted.
    await h.tapTab(l10n.navPeople);
    await h.waitForText(l10n.contactStatusAccepted);
    await shoot('06_contact_accepted');

    // 07: what AfterMe keeps.
    await h.tapTab(l10n.navSettings);
    await h.tapText(l10n.settingsPrivacyKeeps);
    await h.waitForText(l10n.privacyKeepsNeverTitle);
    await shoot('07_privacy');
    await h.tester.pageBack();
    await h.pump(const Duration(seconds: 1));

    // 05: a missed check-in, during the grace period: nobody has been told, and the
    // person is reminded first. (Last, because it moves the test clock.)
    await h.tapTab(l10n.navHome);
    await missDeadline(h);
    await h.pullToRefresh();
    await h.waitFor(
      find.textContaining('You missed your'),
      reason: 'the grace headline',
      onPoll: h.refreshHome,
    );
    await h.waitFor(
      find.textContaining('$_meera will be notified'),
      reason: 'who will be notified, and when',
      onPoll: h.refreshHome,
    );
    await shoot('05_grace_reminded_first');
  });
}
