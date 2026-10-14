import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/session_epoch.dart';
import '../../../core/freshness/stale_data.dart';
import '../../contacts/application/contacts_controller.dart';
import '../../home/application/home_inputs.dart';
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
  /// A read or a save that was started for the account that signed out must never land
  /// in the one that signed in after it.
  final SessionEpoch _session = SessionEpoch();

  bool _alive(int session) => ref.mounted && _session.isCurrent(session);

  @override
  Future<Plan?> build() async {
    _session.next();
    if (ref.watch(authControllerProvider) != AuthStatus.signedIn) {
      return null;
    }
    // Home follows this counter (not this controller): the aggregate counts the plan's
    // stages and judges its readiness, so a saved plan, or the latest one read after a
    // 412, moves it.
    listenSelf((previous, next) {
      final before = previous?.value;
      final after = next.value;
      if (before != null && after != null && before.version != after.version) {
        ref.read(homeInputChangesProvider.notifier).bump();
      }
    });
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
    final session = _session.current;
    if (!state.hasValue) {
      state = const AsyncLoading<Plan?>();
    }
    try {
      final plan = await _run(_repository.get);
      if (!_alive(session)) {
        return null;
      }
      state = AsyncData(plan);
      ref.read(staleDataProvider.notifier).clear(DataArea.plan);
      return null;
    } on AppFailure catch (failure) {
      if (!_alive(session)) {
        return null;
      }
      if (!state.hasValue) {
        state = AsyncError<Plan?>(failure, StackTrace.current);
      } else {
        ref.read(staleDataProvider.notifier).mark(DataArea.plan);
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
    final session = _session.current;
    final loaded = await _run(_repository.get);
    if (_alive(session)) {
      state = AsyncData(loaded);
    }
    return loaded;
  }

  /// Replaces the plan with [draft]. A 412 re-reads the plan and rethrows; a 404 reads
  /// the contacts and the plan again and rethrows. A 409 `incident_open`, a 403
  /// `plan_limit_reached` and a 422 `validation_failed` (with its field errors) are
  /// rethrown as they are.
  ///
  /// A 403 `reauth_required` is rethrown too, with nothing re-read and nothing changed:
  /// the server asks for the password when check-ins are on and [draft] really changes
  /// the plan (SECURITY.md §7), after it checked ownership and validation. Wrap the call
  /// in `withReauth` (reason `ReauthReason.plan`): the same call, made again, sends the
  /// same `If-Match`. An unchanged plan, or any save while check-ins are off
  /// (onboarding), never asks.
  ///
  /// Without [basedOn] the change is made on the plan on hand. The plan editor passes
  /// the plan its draft was started from: the `If-Match` is then that plan's version, so
  /// a plan that was changed meanwhile (another device, a contact removed, a stage added
  /// for an instruction) is a 412 the person is told about, never silently overwritten,
  /// and the same call made again after the password sends the very same header.
  Future<Plan> save(PlanDraft draft, {Plan? basedOn}) async {
    final base = basedOn ?? await _base();
    final session = _session.current;
    try {
      final saved = await _run(
        () => _repository.save(draft, ifMatch: base.ifMatch),
      );
      if (_alive(session)) {
        state = AsyncData(saved);
      }
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
