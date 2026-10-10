import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../data/auth_repository.dart';
import '../data/models/account_models.dart';

/// The signed-in account (`GET /me`). Rebuilt (and so emptied) whenever the sign-in
/// status changes, so one user's profile is never shown to the next.
class MeController extends AsyncNotifier<MeResponse?> {
  @override
  Future<MeResponse?> build() async {
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
    state = const AsyncLoading<MeResponse?>();
    state = await AsyncValue.guard(() async {
      try {
        return await ref.read(authRepositoryProvider).me();
      } on Object catch (error) {
        throw toAppFailure(error);
      }
    });
  }

  /// Applies a server response that carries the account (profile patch, email change).
  void apply(MeResponse me) => state = AsyncData(me);

  /// Saves profile changes. Throws an `AppFailure`.
  Future<MeResponse> patchProfile(ProfilePatch patch) async {
    try {
      final me = await ref.read(authRepositoryProvider).patchProfile(patch);
      apply(me);
      return me;
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }
}

final meControllerProvider = AsyncNotifierProvider<MeController, MeResponse?>(
  MeController.new,
);
