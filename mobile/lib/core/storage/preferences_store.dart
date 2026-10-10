import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The only keys that may be written to `shared_preferences`.
///
/// Preferences are **not** encrypted. Only non-sensitive values belong here: app-lock
/// settings, onboarding progress and times/counts of the last known home summary
/// (ARCHITECTURE.md §5.4). Tokens, contact details and instruction content never do.
/// Using an enum (instead of free-form strings) keeps that list reviewable.
enum PreferenceKey {
  /// The onboarding step to resume at (Phase 2). A step name, never user data.
  onboardingStep,

  /// Whether onboarding is finished for [onboardingUserId] (Phase 2).
  onboardingCompleted,

  /// The account the onboarding progress belongs to (an opaque id, no email).
  onboardingUserId,

  /// Whether the local app lock is enabled (Phase 2).
  appLockEnabled,

  /// App-lock background timeout in minutes (Phase 2).
  appLockTimeoutMinutes,

  /// Whether the notification pre-prompt was shown and the system dialog answered
  /// (Phase 2). The stored result is a status name only.
  notificationPermissionResult;

  String get storageKey => 'afterme.$name';
}

/// Typed wrapper over [SharedPreferencesAsync] for non-sensitive values.
class PreferencesStore {
  PreferencesStore(this._prefs);

  final SharedPreferencesAsync _prefs;

  Future<String?> getString(PreferenceKey key) =>
      _prefs.getString(key.storageKey);

  Future<void> setString(PreferenceKey key, String value) =>
      _prefs.setString(key.storageKey, value);

  Future<bool?> getBool(PreferenceKey key) => _prefs.getBool(key.storageKey);

  Future<void> setBool(PreferenceKey key, {required bool value}) =>
      _prefs.setBool(key.storageKey, value);

  Future<int?> getInt(PreferenceKey key) => _prefs.getInt(key.storageKey);

  Future<void> setInt(PreferenceKey key, int value) =>
      _prefs.setInt(key.storageKey, value);

  Future<void> remove(PreferenceKey key) => _prefs.remove(key.storageKey);

  /// Removes every AfterMe preference (used when the account is deleted).
  Future<void> clear() => _prefs.clear(
    allowList: {for (final key in PreferenceKey.values) key.storageKey},
  );
}

final preferencesStoreProvider = Provider<PreferencesStore>(
  (ref) => PreferencesStore(SharedPreferencesAsync()),
);
