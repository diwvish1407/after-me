import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../data/auth_repository.dart';
import '../data/models/account_models.dart';

/// Active sessions (`GET /auth/sessions`) of the signed-in account.
class SessionsController extends AsyncNotifier<List<SessionItem>> {
  @override
  Future<List<SessionItem>> build() async {
    if (ref.watch(authControllerProvider) != AuthStatus.signedIn) {
      return const [];
    }
    try {
      return await ref.read(authRepositoryProvider).listSessions();
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  Future<void> refresh() async {
    state = const AsyncLoading<List<SessionItem>>();
    state = await AsyncValue.guard(() async {
      try {
        return await ref.read(authRepositoryProvider).listSessions();
      } on Object catch (error) {
        throw toAppFailure(error);
      }
    });
  }

  /// Signs another device out. The row disappears only once the server confirmed.
  Future<void> revoke(String id) async {
    try {
      await ref.read(authRepositoryProvider).revokeSession(id);
    } on Object catch (error) {
      throw toAppFailure(error);
    }
    final current = state.value ?? const <SessionItem>[];
    state = AsyncData([
      for (final item in current)
        if (item.id != id) item,
    ]);
  }
}

final sessionsControllerProvider =
    AsyncNotifierProvider.autoDispose<SessionsController, List<SessionItem>>(
      SessionsController.new,
    );
