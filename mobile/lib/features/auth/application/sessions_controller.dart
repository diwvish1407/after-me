import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/session_epoch.dart';
import '../data/auth_repository.dart';
import '../data/models/account_models.dart';

/// Active sessions (`GET /auth/sessions`) of the signed-in account.
class SessionsController extends AsyncNotifier<List<SessionItem>> {
  final SessionEpoch _session = SessionEpoch();

  bool _alive(int session) => ref.mounted && _session.isCurrent(session);

  @override
  Future<List<SessionItem>> build() async {
    _session.next();
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
    final session = _session.current;
    state = const AsyncLoading<List<SessionItem>>();
    final result = await AsyncValue.guard(() async {
      try {
        return await ref.read(authRepositoryProvider).listSessions();
      } on Object catch (error) {
        throw toAppFailure(error);
      }
    });
    if (_alive(session)) {
      state = result;
    }
  }

  /// Signs another device out. The row disappears only once the server confirmed.
  Future<void> revoke(String id) async {
    final session = _session.current;
    try {
      await ref.read(authRepositoryProvider).revokeSession(id);
    } on Object catch (error) {
      throw toAppFailure(error);
    }
    if (!_alive(session)) {
      return;
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
