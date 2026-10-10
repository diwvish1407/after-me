import 'dart:async';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/security/app_lock/app_lock_controller.dart';
import 'package:afterme/core/security/app_lock/local_auth_gateway.dart';
import 'package:afterme/core/security/app_lock/lock_screen.dart';
import 'package:afterme/features/auth/presentation/reauth_sheet.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

TestFakes _lockedFakes({
  int timeout = 5,
  List<AuthOutcome> outcomes = const [],
}) {
  final fakes = TestFakes();
  fakes.prefs = freshPreferences({
    'afterme.appLockEnabled': true,
    'afterme.appLockTimeoutMinutes': timeout,
  });
  fakes.localAuth.outcomes.addAll(outcomes);
  return fakes;
}

/// The app goes to the background and straight back (the platform's valid sequence).
void _leaveAndReturn(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void main() {
  group('cold start', () {
    testWidgets(
      'an enabled lock covers the app, asks once, and unlocks on success',
      (tester) async {
        final fakes = _lockedFakes(outcomes: [AuthOutcome.canceled]);
        final handle = tester.ensureSemantics();
        final container = await pumpAfterMe(
          tester,
          fakes: fakes,
          status: AuthStatus.signedIn,
        );
        expect(find.text('AfterMe is locked'), findsOneWidget);
        expect(fakes.localAuth.prompts, 1, reason: 'asked once on its own');
        // Nothing from the app is visible, tappable or readable.
        expect(find.text('Hello, Diwakar'), findsNothing, reason: 'offstage');
        expect(find.bySemanticsLabel(RegExp('Hello')), findsNothing);
        expect(find.text('Unlock whenever you\'re ready.'), findsOneWidget);

        await tester.tap(find.text('Unlock'));
        await tester.pumpAndSettle();
        expect(find.text('AfterMe is locked'), findsNothing);
        expect(find.text('Hello, Diwakar'), findsOneWidget);
        expect(container.read(appLockControllerProvider).locked, isFalse);
        expect(fakes.localAuth.reasons.last, 'Unlock AfterMe');
        handle.dispose();
      },
    );

    testWidgets('while the settings load the app is covered, never flashed', (
      tester,
    ) async {
      final fakes = _lockedFakes();
      await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedIn,
        settle: false,
      );
      expect(find.text('Hello, Diwakar'), findsNothing);
      expect(find.text('Home'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('Hello, Diwakar'), findsOneWidget);
    });

    testWidgets('signed out is never covered', (tester) async {
      final fakes = _lockedFakes(outcomes: [AuthOutcome.canceled]);
      await pumpAfterMe(tester, fakes: fakes, status: AuthStatus.signedOut);
      expect(find.text('AfterMe is locked'), findsNothing);
      expect(find.text('Get started'), findsOneWidget);
      expect(fakes.localAuth.prompts, 0);
    });

    testWidgets(
      'failed, locked-out and cancelled attempts are explained calmly',
      (tester) async {
        final fakes = _lockedFakes(outcomes: [AuthOutcome.failed]);
        await pumpAfterMe(tester, fakes: fakes, status: AuthStatus.signedIn);
        expect(find.text("That didn't work. Try again."), findsOneWidget);

        fakes.localAuth.outcomes.add(AuthOutcome.lockedOut);
        await tester.tap(find.text('Unlock'));
        await tester.pumpAndSettle();
        expect(
          find.text('Too many attempts. Wait a moment, then try again.'),
          findsOneWidget,
        );
        expect(find.text('AfterMe is locked'), findsOneWidget);
      },
    );

    testWidgets(
      'a device that lost its screen lock offers to continue unlocked',
      (tester) async {
        final fakes = _lockedFakes(outcomes: [AuthOutcome.notAvailable]);
        fakes.localAuth.lockCapability = LockCapability.noScreenLock;
        final container = await pumpAfterMe(
          tester,
          fakes: fakes,
          status: AuthStatus.signedIn,
        );
        expect(
          find.textContaining('no longer has a screen lock'),
          findsOneWidget,
        );
        expect(find.text('Unlock'), findsNothing);
        await tester.tap(find.text('Turn off app lock and continue'));
        await tester.pumpAndSettle();
        expect(container.read(appLockControllerProvider).enabled, isFalse);
        expect(find.text('Hello, Diwakar'), findsOneWidget);
      },
    );

    testWidgets(
      'a prompt that could not be shown (uiUnavailable) offers Try again and never Turn off',
      (tester) async {
        final fakes = _lockedFakes(outcomes: [AuthOutcome.unavailableNow]);
        final container = await pumpAfterMe(
          tester,
          fakes: fakes,
          status: AuthStatus.signedIn,
        );
        expect(
          find.text("The unlock screen couldn't be shown just now. Try again."),
          findsOneWidget,
        );
        expect(find.text('Turn off app lock and continue'), findsNothing);
        expect(find.text('Unlock'), findsOneWidget);
        expect(container.read(appLockControllerProvider).enabled, isTrue);

        // Even an "unavailable" answer on a phone that still has a screen lock.
        fakes.localAuth.outcomes.add(AuthOutcome.notAvailable);
        await tester.tap(find.text('Unlock'));
        await tester.pumpAndSettle();
        expect(find.text('Turn off app lock and continue'), findsNothing);
        expect(find.text('AfterMe is locked'), findsOneWidget);
        expect(container.read(appLockControllerProvider).enabled, isTrue);
      },
    );

    testWidgets('the first prompt waits until the app is in the foreground', (
      tester,
    ) async {
      final fakes = _lockedFakes(outcomes: [AuthOutcome.canceled]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await pumpAfterMe(tester, fakes: fakes, status: AuthStatus.signedIn);
      expect(find.text('AfterMe is locked'), findsOneWidget);
      expect(fakes.localAuth.prompts, 0, reason: 'activity not resumed yet');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fakes.localAuth.prompts, 1);
    });

    testWidgets('Sign out is always available on the lock screen', (
      tester,
    ) async {
      final fakes = _lockedFakes(outcomes: [AuthOutcome.canceled]);
      final container = await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedIn,
      );
      expect(container.read(authControllerProvider), AuthStatus.signedIn);
      (container.read(authControllerProvider.notifier) as FixedAuthController)
          .set(AuthStatus.signedOut);
      await tester.pumpAndSettle();
      expect(find.text('AfterMe is locked'), findsNothing);
    });

    testWidgets('the Sign out button on the lock screen signs out', (
      tester,
    ) async {
      final fakes = _lockedFakes(outcomes: [AuthOutcome.canceled]);
      await pumpAfterMe(tester, fakes: fakes, status: AuthStatus.signedIn);
      await tester.tap(find.text('Sign out'));
      await tester.pump();
      expect(fakes.auth.calls, contains('logout'));
    });
  });

  group('background and resume', () {
    testWidgets('returns locked after the timeout, unlocked before it', (
      tester,
    ) async {
      final fakes = _lockedFakes();
      final container = await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedIn,
      );
      expect(find.text('Hello, Diwakar'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      fakes.clock.advance(const Duration(minutes: 2));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        find.text('Hello, Diwakar'),
        findsOneWidget,
        reason: 'only 2 of 5 minutes',
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      fakes.clock.advance(const Duration(minutes: 6));
      fakes.localAuth.outcomes.add(AuthOutcome.canceled);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('AfterMe is locked'), findsOneWidget);
      expect(container.read(appLockControllerProvider).locked, isTrue);
    });

    testWidgets(
      '"immediately" covers the app as soon as it leaves the foreground',
      (tester) async {
        final fakes = _lockedFakes(timeout: 0);
        final container = await pumpAfterMe(
          tester,
          fakes: fakes,
          status: AuthStatus.signedIn,
        );
        fakes.localAuth.outcomes.add(AuthOutcome.canceled);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(
          container.read(appLockControllerProvider).locked,
          isTrue,
          reason: 'locked before the recents snapshot, not after resuming',
        );
        // Frames stop while paused; the lock screen is there when the app returns.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(find.text('AfterMe is locked'), findsOneWidget);
      },
    );

    testWidgets('the lock covers an open bottom sheet too', (tester) async {
      final fakes = _lockedFakes(timeout: 0);
      final container = await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedIn,
      );
      container.read(routerProvider).go(AppRoutes.settingsAbout);
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold).last);
      unawaited(showReauthSheet(context));
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you").hitTestable(), findsOneWidget);

      fakes.localAuth.outcomes.add(AuthOutcome.canceled);
      _leaveAndReturn(tester);
      await tester.pumpAndSettle();
      expect(find.text('AfterMe is locked'), findsOneWidget);
      expect(find.text("Confirm it's you").hitTestable(), findsNothing);
      expect(find.text('Confirm').hitTestable(), findsNothing);

      // Unlocking brings the sheet back as it was.
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you").hitTestable(), findsOneWidget);
    });

    testWidgets(
      'while locked, the keyboard cannot reach the hidden app and Back does nothing',
      (tester) async {
        final fakes = _lockedFakes(timeout: 0);
        final container = await pumpAfterMe(
          tester,
          fakes: fakes,
          status: AuthStatus.signedIn,
        );
        container.read(routerProvider).go(AppRoutes.settings);
        await tester.pumpAndSettle();
        final location = container
            .read(routerProvider)
            .routerDelegate
            .currentConfiguration
            .uri
            .toString();
        expect(find.text('Sign out'), findsOneWidget);

        fakes.localAuth.outcomes.add(AuthOutcome.canceled);
        _leaveAndReturn(tester);
        await tester.pumpAndSettle();
        expect(find.text('AfterMe is locked'), findsOneWidget);

        for (var i = 0; i < 12; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final focus = FocusManager.instance.primaryFocus;
          expect(
            focus == null ||
                focus.context == null ||
                focus.context!.findAncestorWidgetOfExactType<LockScreen>() !=
                    null,
            isTrue,
            reason: 'focus stayed outside the lock screen at Tab $i',
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.pump();
        }
        expect(
          find.text('Sign out of this phone?'),
          findsNothing,
          reason: 'hidden dialog',
        );
        expect(fakes.auth.calls, isNot(contains('logout')));

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('AfterMe is locked'), findsOneWidget);
        expect(
          container
              .read(routerProvider)
              .routerDelegate
              .currentConfiguration
              .uri
              .toString(),
          location,
          reason: 'Back must not pop the hidden stack',
        );

        // Unlocked, Back works again.
        await tester.tap(find.text('Unlock'));
        await tester.pumpAndSettle();
        expect(find.text('AfterMe is locked'), findsNothing);
      },
    );

    testWidgets('the system prompt (which pauses the app) does not relock it', (
      tester,
    ) async {
      final fakes = _lockedFakes(timeout: 0, outcomes: [AuthOutcome.canceled]);
      final container = await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedIn,
      );
      expect(container.read(appLockControllerProvider).locked, isTrue);
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(container.read(appLockControllerProvider).locked, isFalse);
    });
  });

  test('FLAG_SECURE is requested natively while the lock is on', () async {
    final fakes = _lockedFakes();
    final container = ProviderContainer.test(
      overrides: testOverrides(fakes: fakes),
    );
    container.listen(appLockControllerProvider, (_, _) {});
    await container.read(appLockControllerProvider.notifier).loaded;
    expect(fakes.privacy.calls, [true]);
  });
}
