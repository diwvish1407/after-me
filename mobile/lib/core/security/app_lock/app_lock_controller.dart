import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/auth_controller.dart';
import '../../storage/preferences_store.dart';
import '../../time/clock.dart';
import '../screen_privacy.dart';
import 'local_auth_gateway.dart';

/// How long the app may stay in the background before it locks.
enum AppLockTimeout {
  immediately(0),
  oneMinute(1),
  fiveMinutes(5);

  const AppLockTimeout(this.minutes);

  final int minutes;

  Duration get duration => Duration(minutes: minutes);

  static const AppLockTimeout defaultValue = AppLockTimeout.fiveMinutes;

  static AppLockTimeout fromMinutes(int? minutes) {
    for (final value in AppLockTimeout.values) {
      if (value.minutes == minutes) {
        return value;
      }
    }
    return defaultValue;
  }
}

@immutable
class AppLockState {
  const AppLockState({
    this.loaded = false,
    this.enabled = false,
    this.timeout = AppLockTimeout.defaultValue,
    this.locked = false,
    this.authenticating = false,
    this.lastOutcome,
    this.capability,
  });

  /// The settings were read from preferences.
  final bool loaded;
  final bool enabled;
  final AppLockTimeout timeout;

  /// The app is covered by the lock screen.
  final bool locked;

  /// The system prompt is up.
  final bool authenticating;

  /// The result of the last unlock attempt that did not succeed.
  final AuthOutcome? lastOutcome;

  /// Whether the device has a screen lock; null until checked.
  final LockCapability? capability;

  AppLockState copyWith({
    bool? loaded,
    bool? enabled,
    AppLockTimeout? timeout,
    bool? locked,
    bool? authenticating,
    AuthOutcome? lastOutcome,
    bool clearOutcome = false,
    LockCapability? capability,
  }) => AppLockState(
    loaded: loaded ?? this.loaded,
    enabled: enabled ?? this.enabled,
    timeout: timeout ?? this.timeout,
    locked: locked ?? this.locked,
    authenticating: authenticating ?? this.authenticating,
    lastOutcome: clearOutcome ? null : (lastOutcome ?? this.lastOutcome),
    capability: capability ?? this.capability,
  );
}

/// What happened when the person tried to turn the lock on.
enum EnableLockResult { enabled, notAvailable, notConfirmed }

/// The local app lock (SECURITY.md §11; USER_FLOWS.md §3 step 8).
///
/// It is a convenience on top of the server-side session: it keeps someone who picks up
/// an unlocked phone out of the app. Rules:
/// * locks on a **cold start** when enabled;
/// * locks when the app returns after more than [AppLockState.timeout] in the
///   background (immediately: as soon as it leaves the foreground);
/// * the system prompt and permission dialogs briefly take the app out of the
///   foreground; those do not count ([runWithoutLocking], and [AppLockState.authenticating]);
/// * signing in with a password counts as unlocking; signing out clears the lock.
class AppLockController extends Notifier<AppLockState> {
  DateTime? _backgroundedAt;
  int _suspended = 0;
  Future<void>? _loading;

  PreferencesStore get _prefs => ref.read(preferencesStoreProvider);
  LocalAuthGateway get _auth => ref.read(localAuthGatewayProvider);
  DateTime _now() => ref.read(clockProvider)();

  @override
  AppLockState build() {
    ref.listen<AuthStatus>(authControllerProvider, (previous, next) {
      if (next == AuthStatus.signedOut || previous == AuthStatus.signedOut) {
        // A fresh sign-in just proved who the person is; signed out has nothing to lock.
        _backgroundedAt = null;
        if (state.locked) {
          state = state.copyWith(locked: false);
        }
      }
    });
    _loading = _load();
    return const AppLockState();
  }

  /// Completes when the settings have been read.
  Future<void> get loaded => _loading ?? Future<void>.value();

  Future<void> _load() async {
    var enabled = false;
    var timeout = AppLockTimeout.defaultValue;
    try {
      enabled = await _prefs.getBool(PreferenceKey.appLockEnabled) ?? false;
      timeout = AppLockTimeout.fromMinutes(
        await _prefs.getInt(PreferenceKey.appLockTimeoutMinutes),
      );
    } on Object {
      // Unreadable preferences: fail safe is "locked" only if we cannot tell. We cannot
      // tell, but forcing a lock the person cannot turn off would be worse.
    }
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(
      loaded: true,
      enabled: enabled,
      timeout: timeout,
      // Cold start: an enabled lock starts locked.
      locked: enabled,
    );
    await _syncPrivacy(enabled);
  }

  Future<void> _syncPrivacy(bool enabled) =>
      ref.read(screenPrivacyProvider).setObscureInRecents(enabled: enabled);

  /// Re-checks whether the device still has a screen lock.
  Future<LockCapability> refreshCapability() async {
    final capability = await _auth.capability();
    if (ref.mounted) {
      state = state.copyWith(capability: capability);
    }
    return capability;
  }

  /// Feeds an app lifecycle change into the lock.
  void didChangeLifecycle(AppLifecycleState lifecycle) {
    switch (lifecycle) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _onBackground();
      case AppLifecycleState.resumed:
        _onResume();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _onBackground() {
    if (!state.enabled || state.locked || state.authenticating) {
      return;
    }
    if (_suspended > 0) {
      return;
    }
    _backgroundedAt ??= _now();
    if (state.timeout == AppLockTimeout.immediately) {
      state = state.copyWith(locked: true, clearOutcome: true);
    }
  }

  void _onResume() {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    if (since == null || !state.enabled || state.locked) {
      return;
    }
    if (_now().difference(since) >= state.timeout.duration) {
      state = state.copyWith(locked: true, clearOutcome: true);
    }
  }

  /// Runs [action] (a system permission dialog, the contact picker, ...) without the
  /// resulting trip to the background locking the app.
  Future<T> runWithoutLocking<T>(Future<T> Function() action) async {
    _suspended++;
    try {
      return await action();
    } finally {
      _suspended--;
      _backgroundedAt = null;
    }
  }

  /// Shows the system prompt. Unlocks on success.
  Future<AuthOutcome> unlock(String reason) async {
    if (state.authenticating) {
      return AuthOutcome.canceled;
    }
    state = state.copyWith(authenticating: true, clearOutcome: true);
    var outcome = await _auth.authenticate(reason);
    if (outcome == AuthOutcome.notAvailable) {
      // One prompt result alone never says the phone has no screen lock.
      final capability = await refreshCapability();
      if (capability != LockCapability.noScreenLock) {
        outcome = AuthOutcome.unavailableNow;
      }
    }
    if (!ref.mounted) {
      return outcome;
    }
    state = outcome == AuthOutcome.success
        ? state.copyWith(
            authenticating: false,
            locked: false,
            clearOutcome: true,
          )
        : state.copyWith(authenticating: false, lastOutcome: outcome);
    if (outcome == AuthOutcome.success) {
      _backgroundedAt = null;
    }
    return outcome;
  }

  /// Turns the lock on after the person proves they can unlock it.
  Future<EnableLockResult> enable(String reason) async {
    final capability = await refreshCapability();
    if (capability != LockCapability.available) {
      return EnableLockResult.notAvailable;
    }
    state = state.copyWith(authenticating: true);
    final outcome = await _auth.authenticate(reason);
    if (!ref.mounted) {
      return EnableLockResult.notConfirmed;
    }
    state = state.copyWith(authenticating: false);
    if (outcome == AuthOutcome.notAvailable) {
      return EnableLockResult.notAvailable;
    }
    if (outcome != AuthOutcome.success) {
      return EnableLockResult.notConfirmed;
    }
    await _prefs.setBool(PreferenceKey.appLockEnabled, value: true);
    state = state.copyWith(enabled: true, locked: false);
    await _syncPrivacy(true);
    return EnableLockResult.enabled;
  }

  /// Turns the lock off. When the device can still verify the person, they must do so
  /// first. When it cannot (the screen lock was removed), the person chooses to continue
  /// without the lock and no prompt is possible. Returns true when the lock is off.
  ///
  /// Skipping the prompt is only ever allowed after [LocalAuthGateway.capability] says
  /// the phone has **no screen lock**, checked right now. A transient prompt error never
  /// counts. [force] (the lock screen choice) skips the prompt but not that check.
  Future<bool> disable(String reason, {bool force = false}) async {
    final capability = await refreshCapability();
    if (capability == LockCapability.available) {
      if (force) {
        return false;
      }
      state = state.copyWith(authenticating: true);
      final outcome = await _auth.authenticate(reason);
      if (!ref.mounted) {
        return false;
      }
      state = state.copyWith(authenticating: false);
      if (outcome != AuthOutcome.success) {
        if (outcome != AuthOutcome.notAvailable ||
            await refreshCapability() != LockCapability.noScreenLock) {
          return false;
        }
      }
    }
    await _prefs.setBool(PreferenceKey.appLockEnabled, value: false);
    state = state.copyWith(enabled: false, locked: false, clearOutcome: true);
    _backgroundedAt = null;
    await _syncPrivacy(false);
    return true;
  }

  Future<void> setTimeout(AppLockTimeout timeout) async {
    await _prefs.setInt(PreferenceKey.appLockTimeoutMinutes, timeout.minutes);
    state = state.copyWith(timeout: timeout);
  }
}

final appLockControllerProvider =
    NotifierProvider<AppLockController, AppLockState>(AppLockController.new);
