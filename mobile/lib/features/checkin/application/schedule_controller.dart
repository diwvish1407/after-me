import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/session_epoch.dart';
import '../../auth/application/me_controller.dart';
import '../../home/application/home_inputs.dart';
import '../../incidents/application/safe_controller.dart';
import '../data/schedule_repository.dart';
import 'checkin_controller.dart';

/// The signed-in person's check-in schedule (`GET /checkin/schedule`) and every change
/// to it or to its on/off switch.
///
/// The snapshot is replaced only with what the server answered, and its `ETag` is the
/// `If-Match` of the next change. Every method throws an `AppFailure` on error. A 412
/// (the schedule was changed somewhere else) reads the latest version first, so the
/// screen shows what is really saved when it explains that.
class ScheduleController extends AsyncNotifier<ScheduleSnapshot?> {
  /// A read or a change that was started for the account that signed out must never
  /// land in the one that signed in after it.
  final SessionEpoch _session = SessionEpoch();

  bool _alive(int session) => ref.mounted && _session.isCurrent(session);

  @override
  Future<ScheduleSnapshot?> build() async {
    _session.next();
    if (ref.watch(authControllerProvider) != AuthStatus.signedIn) {
      return null;
    }
    // Home follows this counter (not this controller, whose read a listener would
    // start): a settings change or an on/off switch moves the aggregate. A schedule that
    // was only read again after a check-in (same version) is what Home already applied
    // from the answer.
    listenSelf((previous, next) {
      final before = previous?.value;
      final after = next.value;
      if (before != null &&
          after != null &&
          (before.version != after.version || before.status != after.status)) {
        ref.read(homeInputChangesProvider.notifier).bump();
      }
    });
    // A timezone change recomputes the deadline on the server, which also changes the
    // version: read it again so the next save carries the right ETag.
    ref.listen(timezoneChangesProvider, (previous, next) {
      reload();
    });
    // A confirmed check-in moves the last check-in and the deadline on the server (the
    // version stays): read them again so this screen agrees with Home.
    ref.listen(checkInControllerProvider, (previous, next) {
      if (next.phase == CheckInPhase.success &&
          previous?.phase != CheckInPhase.success) {
        reload();
      }
    });
    // I'M SAFE restarts the schedule exactly as a check-in does, and the incident that
    // locked it is over.
    ref.listen(safeControllerProvider, (previous, next) {
      if (next.phase == SafePhase.success &&
          previous?.phase != SafePhase.success) {
        reload();
      }
    });
    final repository = ref.watch(scheduleRepositoryProvider);
    try {
      return await repository.get();
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  ScheduleRepository get _repository => ref.read(scheduleRepositoryProvider);

  Future<T> _run<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  /// Reads the schedule again and returns the failure, or null. The snapshot already on
  /// screen stays when the refresh fails.
  Future<AppFailure?> reload() async {
    final session = _session.current;
    if (!state.hasValue) {
      state = const AsyncLoading<ScheduleSnapshot?>();
    }
    try {
      final snapshot = await _run(_repository.get);
      if (!_alive(session)) {
        return null;
      }
      state = AsyncData(snapshot);
      return null;
    } on AppFailure catch (failure) {
      if (!_alive(session)) {
        return null;
      }
      if (!state.hasValue) {
        state = AsyncError<ScheduleSnapshot?>(failure, StackTrace.current);
      }
      return failure;
    }
  }

  /// The snapshot to base a change on: the one on hand, or a fresh read.
  Future<ScheduleSnapshot> _base() async {
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

  /// Saves the schedule. While check-ins are on the server restarts the clock from now.
  /// A 412 re-reads the schedule and rethrows.
  Future<ScheduleSnapshot> save(CheckInSchedule schedule) async {
    final base = await _base();
    final session = _session.current;
    try {
      final saved = await _run(
        () => _repository.save(schedule, ifMatch: base.ifMatch),
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
    }
  }

  /// Turns check-ins on. Already on is a 200 with nothing changed. A 409
  /// `activation_requirements_unmet` is an [ActivationRequirementsFailure].
  Future<ScheduleSnapshot> activate() async {
    final session = _session.current;
    final saved = await _run(_repository.activate);
    if (_alive(session)) {
      state = AsyncData(saved);
    }
    return saved;
  }

  /// Turns check-ins off. The server wants a recent re-authentication (403
  /// `reauth_required`): wrap the call in `withReauth`.
  Future<ScheduleSnapshot> deactivate() async {
    final session = _session.current;
    final saved = await _run(_repository.deactivate);
    if (_alive(session)) {
      state = AsyncData(saved);
    }
    return saved;
  }
}

final scheduleControllerProvider =
    AsyncNotifierProvider<ScheduleController, ScheduleSnapshot?>(
      ScheduleController.new,
    );
