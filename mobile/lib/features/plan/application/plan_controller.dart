import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../contacts/application/contacts_controller.dart';
import '../data/plan_repository.dart';

/// The signed-in person's escalation plan (`GET /plan`) and every change to it.
///
/// The snapshot is replaced only with what the server answered, and its version is the
/// `If-Match` of the next change. Every method throws an `AppFailure` on error. A 412
/// (the plan was changed somewhere else) reads the latest plan first, so the screen shows
/// what is really saved when it explains that; a 404 (a contact in the plan is not the
/// person's any more) reads the contacts and the plan again.
///
/// Home counts the plan's stages and judges its readiness, so it listens to this
/// controller and reads the aggregate again after a change (`HomeController`).
class PlanController extends AsyncNotifier<Plan?> {
  @override
  Future<Plan?> build() async {
    if (ref.watch(authControllerProvider) != AuthStatus.signedIn) {
      return null;
    }
    // Removing a contact takes them out of every stage on the server: read the plan
    // again, so a later save never names someone who is gone (that would be a 404).
    ref.listen(contactsControllerProvider, (previous, next) {
      final before = previous?.value;
      final after = next.value;
      if (before != null &&
          after != null &&
          before.any((c) => !after.any((a) => a.id == c.id))) {
        unawaited(reload());
      }
    });
    final repository = ref.watch(planRepositoryProvider);
    try {
      return await repository.get();
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  PlanRepository get _repository => ref.read(planRepositoryProvider);

  Future<T> _run<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  /// Reads the plan again and returns the failure, or null. The plan already on screen
  /// stays when the refresh fails.
  Future<AppFailure?> reload() async {
    if (!state.hasValue) {
      state = const AsyncLoading<Plan?>();
    }
    try {
      state = AsyncData(await _run(_repository.get));
      return null;
    } on AppFailure catch (failure) {
      if (!state.hasValue) {
        state = AsyncError<Plan?>(failure, StackTrace.current);
      }
      return failure;
    }
  }

  /// The plan to base a change on: the one on hand, or a fresh read.
  Future<Plan> _base() async {
    final current = state.value;
    if (current != null) {
      return current;
    }
    final loaded = await _run(_repository.get);
    state = AsyncData(loaded);
    return loaded;
  }

  /// Replaces the plan with [draft]. A 412 re-reads the plan and rethrows; a 404 reads
  /// the contacts and the plan again and rethrows. A 409 `incident_open`, a 403
  /// `plan_limit_reached` and a 422 `validation_failed` (with its field errors) are
  /// rethrown as they are.
  Future<Plan> save(PlanDraft draft) async {
    final base = await _base();
    try {
      final saved = await _run(
        () => _repository.save(draft, ifMatch: base.ifMatch),
      );
      state = AsyncData(saved);
      return saved;
    } on ConflictFailure catch (failure) {
      if (failure.code == 'precondition_failed' ||
          failure.code == 'precondition_required') {
        await reload();
      }
      rethrow;
    } on NotFoundFailure {
      await ref.read(contactsControllerProvider.notifier).reload();
      await reload();
      rethrow;
    }
  }
}

final planControllerProvider = AsyncNotifierProvider<PlanController, Plan?>(
  PlanController.new,
);
