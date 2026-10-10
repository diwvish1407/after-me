import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/preferences_store.dart';

/// The steps after the account exists (USER_FLOWS.md §3 steps 4-9). Steps 1-3 (welcome,
/// create account, code) are the public sign-up screens.
enum OnboardingStep {
  contact('/onboarding/contact'),
  schedule('/onboarding/schedule'),
  plan('/onboarding/plan'),
  instruction('/onboarding/instruction'),
  protect('/onboarding/protect'),
  done('/onboarding/done');

  const OnboardingStep(this.path);

  final String path;

  /// The step after this one, or null after the last.
  OnboardingStep? get next => index + 1 < OnboardingStep.values.length
      ? OnboardingStep.values[index + 1]
      : null;

  static OnboardingStep? tryParse(String? name) {
    for (final step in OnboardingStep.values) {
      if (step.name == name) {
        return step;
      }
    }
    return null;
  }
}

@immutable
class OnboardingState {
  const OnboardingState({
    this.loaded = false,
    this.completed = true,
    this.step = OnboardingStep.contact,
  });

  /// The saved progress has been read.
  final bool loaded;

  /// Nothing to resume: either onboarding was finished or this account never started
  /// it on this device (a returning user who just signed in).
  final bool completed;

  /// The step to resume at while [completed] is false.
  final OnboardingStep step;

  bool get needsOnboarding => loaded && !completed;

  OnboardingState copyWith({
    bool? loaded,
    bool? completed,
    OnboardingStep? step,
  }) => OnboardingState(
    loaded: loaded ?? this.loaded,
    completed: completed ?? this.completed,
    step: step ?? this.step,
  );

  @override
  bool operator ==(Object other) =>
      other is OnboardingState &&
      other.loaded == loaded &&
      other.completed == completed &&
      other.step == step;

  @override
  int get hashCode => Object.hash(loaded, completed, step);
}

/// Onboarding progress, saved after every step and restored on launch.
///
/// Only the step name, a completed flag and an opaque account id are stored. The
/// password and the verification code live in memory in the sign-up controller and are
/// never written anywhere; contact details are not progress and are not stored either.
class OnboardingController extends Notifier<OnboardingState> {
  PreferencesStore get _prefs => ref.read(preferencesStoreProvider);

  Future<void>? _loading;

  @override
  OnboardingState build() {
    _loading = _load();
    return const OnboardingState();
  }

  /// Completes when the saved progress has been read.
  Future<void> get loaded => _loading ?? Future<void>.value();

  Future<void> _load() async {
    var next = const OnboardingState(loaded: true);
    try {
      final userId = await _prefs.getString(PreferenceKey.onboardingUserId);
      if (userId != null && userId.isNotEmpty) {
        final completed =
            await _prefs.getBool(PreferenceKey.onboardingCompleted) ?? true;
        final step = OnboardingStep.tryParse(
          await _prefs.getString(PreferenceKey.onboardingStep),
        );
        next = OnboardingState(
          loaded: true,
          completed: completed,
          step: step ?? OnboardingStep.contact,
        );
      }
    } on Object {
      // Unreadable preferences: do not trap the user in onboarding.
    }
    if (ref.mounted) {
      state = next;
    }
  }

  Future<String?> _storedUserId() async {
    try {
      return await _prefs.getString(PreferenceKey.onboardingUserId);
    } on Object {
      return null;
    }
  }

  /// A brand-new account was just created: start at the first step. Called before the
  /// session starts, so the router never shows Home first.
  Future<void> beginForNewAccount(String userId) async {
    await loaded;
    state = const OnboardingState(
      loaded: true,
      completed: false,
      step: OnboardingStep.contact,
    );
    await _persist(userId: userId);
  }

  /// An existing account signed in. Unfinished onboarding of the same account is
  /// resumed; anything else counts as complete (the readiness checklist on Home covers
  /// what is missing).
  Future<void> accountSignedIn(String userId) async {
    await loaded;
    if (await _storedUserId() == userId) {
      return;
    }
    state = const OnboardingState(loaded: true);
    await _persist(userId: userId);
  }

  /// Marks [step] done. Saved progress only moves **forward**: completing an earlier
  /// step (a detour from the plan step to add a contact, say) never lowers it, so a
  /// relaunch resumes at the furthest step reached. Finishes after the last step.
  Future<void> completeStep(OnboardingStep step) async {
    await loaded;
    final next = step.next;
    if (state.completed) {
      return;
    }
    if (next == null) {
      await finish();
      return;
    }
    if (next.index > state.step.index) {
      state = state.copyWith(step: next);
      await _persist();
    }
  }

  /// Onboarding is over; Home takes it from here.
  Future<void> finish() async {
    await loaded;
    state = state.copyWith(completed: true);
    await _persist();
  }

  Future<void> _persist({String? userId}) async {
    try {
      if (userId != null) {
        await _prefs.setString(PreferenceKey.onboardingUserId, userId);
      }
      await _prefs.setBool(
        PreferenceKey.onboardingCompleted,
        value: state.completed,
      );
      await _prefs.setString(PreferenceKey.onboardingStep, state.step.name);
    } on Object {
      // Progress is a convenience; failing to save must not block the user.
    }
  }
}

final onboardingControllerProvider =
    NotifierProvider<OnboardingController, OnboardingState>(
      OnboardingController.new,
    );
