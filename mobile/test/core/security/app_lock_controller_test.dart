import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/security/app_lock/app_lock_controller.dart';
import 'package:afterme/core/security/app_lock/local_auth_gateway.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

class _Setup {
  _Setup({
    bool enabled = false,
    int? timeout,
    AuthStatus auth = AuthStatus.signedIn,
  }) : fakes = TestFakes() {
    fakes.prefs = freshPreferences({
      if (enabled) 'afterme.appLockEnabled': true,
      'afterme.appLockTimeoutMinutes': ?timeout,
    });
    container = ProviderContainer.test(
      overrides: testOverrides(authStatus: auth, fakes: fakes),
    );
    container.listen(authControllerProvider, (_, _) {});
    container.listen(appLockControllerProvider, (_, _) {});
  }

  final TestFakes fakes;
  late final ProviderContainer container;

  AppLockController get controller =>
      container.read(appLockControllerProvider.notifier);

  AppLockState get state => container.read(appLockControllerProvider);

  Future<void> load() => controller.loaded;

  FixedAuthController get auth =>
      container.read(authControllerProvider.notifier) as FixedAuthController;

  void background() => controller.didChangeLifecycle(AppLifecycleState.paused);

  void resume() => controller.didChangeLifecycle(AppLifecycleState.resumed);
}

void main() {
  group('loading', () {
    test('starts unloaded, unlocked and disabled by default', () async {
      final s = _Setup();
      expect(s.state.loaded, isFalse);
      await s.load();
      expect(s.state.loaded, isTrue);
      expect(s.state.enabled, isFalse);
      expect(s.state.locked, isFalse);
      expect(s.state.timeout, AppLockTimeout.fiveMinutes);
      expect(s.fakes.privacy.enabled, isFalse);
    });

    test('an enabled lock starts locked on a cold start', () async {
      final s = _Setup(enabled: true, timeout: 1);
      await s.load();
      expect(s.state.enabled, isTrue);
      expect(s.state.locked, isTrue);
      expect(s.state.timeout, AppLockTimeout.oneMinute);
      expect(s.fakes.privacy.enabled, isTrue);
    });

    test('an unknown stored timeout falls back to the default', () {
      expect(AppLockTimeout.fromMinutes(7), AppLockTimeout.fiveMinutes);
      expect(AppLockTimeout.fromMinutes(null), AppLockTimeout.fiveMinutes);
      expect(AppLockTimeout.fromMinutes(0), AppLockTimeout.immediately);
      expect(AppLockTimeout.immediately.duration, Duration.zero);
    });
  });

  group('lifecycle', () {
    test('returning before the timeout keeps the app unlocked', () async {
      final s = _Setup(enabled: true);
      await s.load();
      await s.controller.unlock('reason');
      expect(s.state.locked, isFalse);

      s.background();
      s.fakes.clock.advance(const Duration(minutes: 4, seconds: 59));
      s.resume();
      expect(s.state.locked, isFalse);
    });

    test('returning after the timeout locks', () async {
      final s = _Setup(enabled: true);
      await s.load();
      await s.controller.unlock('reason');

      s.background();
      s.fakes.clock.advance(const Duration(minutes: 5));
      s.resume();
      expect(s.state.locked, isTrue);
    });

    test('the one-minute timeout', () async {
      final s = _Setup(enabled: true, timeout: 1);
      await s.load();
      await s.controller.unlock('reason');
      s.background();
      s.fakes.clock.advance(const Duration(seconds: 59));
      s.resume();
      expect(s.state.locked, isFalse);
      s.background();
      s.fakes.clock.advance(const Duration(seconds: 60));
      s.resume();
      expect(s.state.locked, isTrue);
    });

    test(
      '"immediately" locks as soon as the app leaves the foreground',
      () async {
        final s = _Setup(enabled: true, timeout: 0);
        await s.load();
        await s.controller.unlock('reason');
        s.background();
        expect(s.state.locked, isTrue, reason: 'before the recents snapshot');
      },
    );

    test('hidden counts as background; inactive and detached do not', () async {
      final s = _Setup(enabled: true, timeout: 0);
      await s.load();
      await s.controller.unlock('reason');
      s.controller.didChangeLifecycle(AppLifecycleState.inactive);
      s.controller.didChangeLifecycle(AppLifecycleState.detached);
      expect(s.state.locked, isFalse);
      s.controller.didChangeLifecycle(AppLifecycleState.hidden);
      expect(s.state.locked, isTrue);
    });

    test('a disabled lock never locks', () async {
      final s = _Setup();
      await s.load();
      s.background();
      s.fakes.clock.advance(const Duration(hours: 5));
      s.resume();
      expect(s.state.locked, isFalse);
    });

    test('the system prompt does not lock the app behind it', () async {
      final s = _Setup(enabled: true, timeout: 0);
      await s.load();
      await s.controller.unlock('reason');
      // While authenticating the activity pauses; nothing may lock.
      await s.controller.enable('x'); // authenticating toggles on and off
      expect(s.state.locked, isFalse);
    });

    test('runWithoutLocking ignores a trip to the background', () async {
      final s = _Setup(enabled: true, timeout: 0);
      await s.load();
      await s.controller.unlock('reason');
      await s.controller.runWithoutLocking(() async {
        s.background();
        s.resume();
      });
      expect(s.state.locked, isFalse);
      // And it returns the action's value and re-arms afterwards.
      expect(await s.controller.runWithoutLocking(() async => 42), 42);
      s.background();
      expect(s.state.locked, isTrue);
    });

    test('runWithoutLocking re-arms even when the action throws', () async {
      final s = _Setup(enabled: true, timeout: 0);
      await s.load();
      await s.controller.unlock('reason');
      await expectLater(
        s.controller.runWithoutLocking<void>(() async => throw StateError('x')),
        throwsStateError,
      );
      s.background();
      expect(s.state.locked, isTrue);
    });

    test('a long background trip while locked keeps it locked', () async {
      final s = _Setup(enabled: true);
      await s.load();
      expect(s.state.locked, isTrue);
      s.background();
      s.resume();
      expect(s.state.locked, isTrue);
    });
  });

  group('unlock', () {
    test('success unlocks and uses the reason', () async {
      final s = _Setup(enabled: true);
      await s.load();
      expect(await s.controller.unlock('Unlock AfterMe'), AuthOutcome.success);
      expect(s.state.locked, isFalse);
      expect(s.state.authenticating, isFalse);
      expect(s.fakes.localAuth.reasons, ['Unlock AfterMe']);
    });

    test('failures keep it locked and remember the outcome', () async {
      final s = _Setup(enabled: true);
      await s.load();
      for (final outcome in [
        AuthOutcome.failed,
        AuthOutcome.canceled,
        AuthOutcome.lockedOut,
        AuthOutcome.unavailableNow,
      ]) {
        s.fakes.localAuth.outcomes.add(outcome);
        expect(await s.controller.unlock('r'), outcome);
        expect(s.state.locked, isTrue);
        expect(s.state.lastOutcome, outcome);
      }
      expect(await s.controller.unlock('r'), AuthOutcome.success);
      expect(s.state.lastOutcome, isNull);
    });

    test('"not available" counts only when the phone has no screen lock', () async {
      final s = _Setup(enabled: true);
      await s.load();
      // The prompt says "not available" but the phone still has a screen lock:
      // that is a glitch, retryable, never "no screen lock".
      s.fakes.localAuth.outcomes.add(AuthOutcome.notAvailable);
      expect(await s.controller.unlock('r'), AuthOutcome.unavailableNow);
      expect(s.state.lastOutcome, AuthOutcome.unavailableNow);

      s.fakes.localAuth.lockCapability = LockCapability.noScreenLock;
      s.fakes.localAuth.outcomes.add(AuthOutcome.notAvailable);
      expect(await s.controller.unlock('r'), AuthOutcome.notAvailable);
      expect(s.state.capability, LockCapability.noScreenLock);
      expect(s.state.locked, isTrue);
    });

    test('a second prompt while one is up is ignored', () async {
      final s = _Setup(enabled: true);
      await s.load();
      final first = s.controller.unlock('r');
      expect(await s.controller.unlock('r'), AuthOutcome.canceled);
      await first;
      expect(s.fakes.localAuth.prompts, 1);
    });
  });

  group('enable and disable', () {
    test('enable needs a screen lock', () async {
      final s = _Setup();
      s.fakes.localAuth.lockCapability = LockCapability.noScreenLock;
      await s.load();
      expect(await s.controller.enable('r'), EnableLockResult.notAvailable);
      expect(s.state.enabled, isFalse);
      expect(s.state.capability, LockCapability.noScreenLock);
      expect(s.fakes.localAuth.prompts, 0);
    });

    test('enable asks the person to confirm and then persists', () async {
      final s = _Setup();
      await s.load();
      s.fakes.localAuth.outcomes.add(AuthOutcome.canceled);
      expect(await s.controller.enable('r'), EnableLockResult.notConfirmed);
      expect(s.state.enabled, isFalse);

      s.fakes.localAuth.outcomes.add(AuthOutcome.notAvailable);
      expect(await s.controller.enable('r'), EnableLockResult.notAvailable);

      expect(await s.controller.enable('r'), EnableLockResult.enabled);
      expect(s.state.enabled, isTrue);
      expect(s.state.locked, isFalse);
      expect(s.fakes.privacy.enabled, isTrue);
      expect(await s.fakes.prefs.getBool(PreferenceKey.appLockEnabled), isTrue);
    });

    test('disable asks to confirm while the device can verify', () async {
      final s = _Setup(enabled: true);
      await s.load();
      await s.controller.unlock('r');

      s.fakes.localAuth.outcomes.add(AuthOutcome.failed);
      expect(await s.controller.disable('r'), isFalse);
      expect(s.state.enabled, isTrue);

      expect(await s.controller.disable('r'), isTrue);
      expect(s.state.enabled, isFalse);
      expect(
        await s.fakes.prefs.getBool(PreferenceKey.appLockEnabled),
        isFalse,
      );
      expect(s.fakes.privacy.enabled, isFalse);
    });

    test(
      'with no screen lock left, the person may choose to continue unlocked',
      () async {
        final s = _Setup(enabled: true);
        s.fakes.localAuth.lockCapability = LockCapability.noScreenLock;
        await s.load();
        expect(s.state.locked, isTrue);
        expect(
          await s.controller.disable('r'),
          isTrue,
          reason: 'nothing to verify with',
        );
        expect(s.state.enabled, isFalse);
        expect(s.state.locked, isFalse);
        expect(s.fakes.localAuth.prompts, 0);
      },
    );

    test('force (the lock screen choice) skips the prompt only without a screen lock', () async {
      final s = _Setup(enabled: true);
      s.fakes.localAuth.lockCapability = LockCapability.noScreenLock;
      await s.load();
      expect(await s.controller.disable('r', force: true), isTrue);
      expect(s.fakes.localAuth.prompts, 0);
      expect(s.state.locked, isFalse);
      expect(s.state.enabled, isFalse);
    });

    test('a forced disable is refused while the phone can verify', () async {
      final s = _Setup(enabled: true);
      await s.load();
      expect(await s.controller.disable('r', force: true), isFalse);
      expect(s.state.enabled, isTrue);
      expect(s.state.locked, isTrue);
      expect(s.fakes.localAuth.prompts, 0);
      expect(await s.fakes.prefs.getBool(PreferenceKey.appLockEnabled), isTrue);
    });

    test(
      'a transient prompt error never lets disable skip the check',
      () async {
        final s = _Setup(enabled: true);
        await s.load();
        await s.controller.unlock('r');
        for (final outcome in [
          AuthOutcome.unavailableNow,
          AuthOutcome.notAvailable, // the phone still reports a screen lock
        ]) {
          s.fakes.localAuth.outcomes.add(outcome);
          expect(await s.controller.disable('r'), isFalse, reason: '$outcome');
          expect(s.state.enabled, isTrue);
        }
      },
    );

    test('the timeout is stored', () async {
      final s = _Setup(enabled: true);
      await s.load();
      await s.controller.setTimeout(AppLockTimeout.immediately);
      expect(s.state.timeout, AppLockTimeout.immediately);
      expect(
        await s.fakes.prefs.getInt(PreferenceKey.appLockTimeoutMinutes),
        0,
      );
    });
  });

  group('sign-in and sign-out', () {
    test(
      'signing in fresh does not start locked; signing out clears the lock',
      () async {
        final s = _Setup(enabled: true, auth: AuthStatus.signedOut);
        await s.load();
        expect(s.state.locked, isTrue, reason: 'cold start with a lock set');
        s.auth.set(AuthStatus.signedIn);
        expect(
          s.state.locked,
          isFalse,
          reason: 'the password just proved who it is',
        );

        await s.controller.disable('r');
        await s.controller.enable('r');
        s.background();
        s.fakes.clock.advance(const Duration(hours: 1));
        s.resume();
        expect(s.state.locked, isTrue);
        s.auth.set(AuthStatus.signedOut);
        expect(s.state.locked, isFalse);
      },
    );

    test('a restored session (unknown -> signedIn) stays locked', () async {
      final s = _Setup(enabled: true, auth: AuthStatus.unknown);
      await s.load();
      s.auth.set(AuthStatus.signedIn);
      expect(s.state.locked, isTrue);
    });
  });

  test('refreshCapability reports the device state', () async {
    final s = _Setup();
    await s.load();
    expect(await s.controller.refreshCapability(), LockCapability.available);
    s.fakes.localAuth.lockCapability = LockCapability.noScreenLock;
    expect(await s.controller.refreshCapability(), LockCapability.noScreenLock);
    expect(s.state.capability, LockCapability.noScreenLock);
  });
}
