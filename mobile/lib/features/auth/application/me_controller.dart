import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/session_epoch.dart';
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
