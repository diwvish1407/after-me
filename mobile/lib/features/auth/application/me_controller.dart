import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/session_epoch.dart';
import '../../home/application/home_inputs.dart';
import '../data/auth_repository.dart';
import '../data/models/account_models.dart';

/// The signed-in account (`GET /me`). Rebuilt (and so emptied) whenever the sign-in
/// status changes, so one user's profile is never shown to the next.
class MeController extends AsyncNotifier<MeResponse?> {
  /// An answer for the account that signed out must never land in the one that signed
  /// in after it.
  final SessionEpoch _session = SessionEpoch();

  bool _alive(int session) => ref.mounted && _session.isCurrent(session);

  @override
  Future<MeResponse?> build() async {
    _session.next();
    if (ref.watch(authControllerProvider) != AuthStatus.signedIn) {
      return null;
    }
    // Home follows this counter (not this controller, whose read a listener would
    // start): a new timezone moves the deadline, a new name is shown on Home.
    listenSelf((previous, next) {
      final before = previous?.value?.profile;
      final after = next.value?.profile;
      if (before == null || after == null) {
        return;
      }
      if (before.timezone != after.timezone) {
        ref.read(timezoneChangesProvider.notifier).bump();
      }
      if (before.timezone != after.timezone ||
          before.displayName != after.displayName) {
        ref.read(homeInputChangesProvider.notifier).bump();
      }
    });
    try {
      return await ref.read(authRepositoryProvider).me();
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  /// Re-reads the account from the server.
  Future<void> refresh() async {
    final session = _session.current;
    state = const AsyncLoading<MeResponse?>();
    final result = await AsyncValue.guard(() async {
      try {
        return await ref.read(authRepositoryProvider).me();
      } on Object catch (error) {
        throw toAppFailure(error);
      }
    });
    if (_alive(session)) {
      state = result;
    }
  }

  /// Applies a server response that carries the account (profile patch, email change).
  void apply(MeResponse me) => state = AsyncData(me);

  /// Saves profile changes. Throws an `AppFailure`.
  Future<MeResponse> patchProfile(ProfilePatch patch) async {
    final session = _session.current;
    try {
      final me = await ref.read(authRepositoryProvider).patchProfile(patch);
      if (_alive(session)) {
        apply(me);
      }
      return me;
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }
}

final meControllerProvider = AsyncNotifierProvider<MeController, MeResponse?>(
  MeController.new,
);

/// Goes up when the profile's timezone changed. The schedule follows this counter (a new
/// timezone recomputes the deadline on the server and with it the schedule's version),
/// not [meControllerProvider]: a listener on the account would start `GET /v1/me` every
/// time the schedule is opened.
class TimezoneChanges extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final timezoneChangesProvider = NotifierProvider<TimezoneChanges, int>(
  TimezoneChanges.new,
);
