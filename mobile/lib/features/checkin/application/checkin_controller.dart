import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/api/upgrade_gate.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/time/clock.dart';
import '../data/checkin_repository.dart';
import 'pending_checkin_store.dart';

/// Where the person's I'M OK tap stands.
enum CheckInPhase {
  /// Nothing is in flight.
  idle,

  /// The request is on the wire.
  sending,

  /// The server answered 200 (and only then): the check-in is recorded.
  success,

  /// Not received yet. The same key is retried automatically.
  pending,

  /// The server asked us to slow down (429). The same key is retried after the wait.
  rateLimited,

  /// Contacts were already told, so I'M SAFE is needed instead (409 `safe_required`).
  /// Nothing was recorded.
  safeRequired,

  /// The session cannot be used right now (401 after the silent refresh). The tap is
  /// kept and sent once the person is signed in again.
  signInRequired,

  /// The server refused this check-in for a reason retrying cannot fix. Nothing was
  /// recorded; the person can tap again.
  failed,

  /// The tap was older than [pendingCheckInMaxAge] when it was about to be sent, so it
  /// was dropped without a request (ESCALATION_ENGINE.md §9.1). Nothing was recorded;
  /// the person is told and can tap again.
  expired,
}

@immutable
class CheckInState {
  const CheckInState({
    this.phase = CheckInPhase.idle,
    this.tappedAt,
    this.result,
    this.failure,
    this.retryAt,
    this.retrying = false,
  });

  final CheckInPhase phase;

  /// When the person tapped (the phone's clock), while a tap is unresolved and in
  /// [CheckInPhase.expired].
  final DateTime? tappedAt;

  /// The server's answer, in [CheckInPhase.success].
  final CheckInResult? result;

  /// Why the last attempt did not work, in the failure phases.
  final AppFailure? failure;

  /// In [CheckInPhase.rateLimited]: when trying again can work (the phone's clock).
  final DateTime? retryAt;

  /// In [CheckInPhase.sending]: this is another attempt at a tap that was not
  /// confirmed. The screen keeps saying "Not received yet" meanwhile instead of
  /// briefly looking as if nothing were wrong.
  final bool retrying;

  /// A tap that is not confirmed yet: it must not be lost, and a new tap reuses its key.
  bool get isUnconfirmed =>
      phase == CheckInPhase.sending ||
      phase == CheckInPhase.pending ||
      phase == CheckInPhase.rateLimited ||
      phase == CheckInPhase.signInRequired;

  /// Whether the `safe_required` answer on hand is about the open incident
  /// [incidentId]. It is never about another one: an answer that outlived its incident
  /// must not make the next incident (nobody told yet) read as "contacts have been
  /// notified". An answer that names no incident cannot be told apart and applies to
  /// whatever is open; the next read of Home settles it.
  bool safeRequiredApplies(String incidentId) {
    if (phase != CheckInPhase.safeRequired) {
      return false;
    }
    final named = failure?.problem?.incidentId;
    return named == null || named == incidentId;
  }

  @override
  bool operator ==(Object other) =>
      other is CheckInState &&
      other.phase == phase &&
      other.tappedAt == tappedAt &&
      other.result == result &&
      other.failure == failure &&
      other.retryAt == retryAt &&
      other.retrying == retrying;

  @override
  int get hashCode =>
      Object.hash(phase, tappedAt, result, failure, retryAt, retrying);
}

/// Starts a timer. Injectable so tests fire retries by hand.
typedef CheckInTimerFactory = Timer Function(Duration delay, void Function());

/// How long to wait before automatic retry number 1, 2, 3, ... of an unconfirmed tap.
/// The last value repeats while the app stays open.
const List<Duration> checkInBackoff = [
  Duration(seconds: 5),
  Duration(seconds: 15),
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(minutes: 2),
  Duration(minutes: 5),
];

/// How long the confirmation stays on the button before it goes back to I'M OK.
const Duration checkInSuccessDuration = Duration(seconds: 4);

/// The I'M OK tap (USER_FLOWS.md §5, ESCALATION_ENGINE.md §9.1).
///
/// * `idle -> sending -> success`, and **success only after the server's 200**.
/// * A tap gets one idempotency key. The record (key, time of the tap) is written to
///   storage **before** the request, so the same key is retried after a network error,
///   a 5xx, with backoff while the app is open, when the app comes back to the
///   foreground and after the process was killed. Two taps never produce two keys while
///   one is unconfirmed.
/// * The record is deleted only after a 200 or an answer retrying cannot change
///   (`safe_required`, other 4xx), or when it is older than [pendingCheckInMaxAge]: the
///   server stamps a tap at receipt, so a tap that late would restart the deadline from
///   then. That is checked when a record is restored and before every attempt, nothing
///   is sent for it and the person is told (`expired`).
/// * The app never computes a deadline: it shows what the server answered.
class CheckInController extends Notifier<CheckInState> {
  PendingCheckIn? _record;
  String _userId = '';
  bool _inFlight = false;
  int _failures = 0;
  int _epoch = 0;
  Timer? _retryTimer;
  Timer? _resetTimer;
  Future<void> _restored = Future<void>.value();

  PendingCheckInStore get _store => ref.read(pendingCheckInStoreProvider);
  DateTime _now() => ref.read(clockProvider)();

  @override
  CheckInState build() {
    final signedIn = ref.watch(authControllerProvider) == AuthStatus.signedIn;
    _epoch++;
    _record = null;
    _inFlight = false;
    _failures = 0;
    _cancelTimers();
    ref.onDispose(_cancelTimers);
    _restored = signedIn ? _restore(_epoch) : Future<void>.value();
    // A tap that the server refused because this version is too old is kept; the moment
    // the server accepts the app again (the update screen was lifted by a request that
    // worked) it is sent, with its own key, without waiting for the next foreground.
    ref.listen<bool>(upgradeGateProvider, (previous, next) {
      if (previous == true && !next) {
        unawaited(retryNow());
      }
    });
    return const CheckInState();
  }

  bool _alive(int epoch) => ref.mounted && epoch == _epoch;

  void _cancelTimers() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _resetTimer?.cancel();
    _resetTimer = null;
  }

  /// Picks up a tap that was not confirmed before the app ended and sends it again.
  Future<void> _restore(int epoch) async {
    final userId = await _store.currentUserId();
    final record = await _store.read(userId);
    if (!_alive(epoch)) {
      return;
    }
    _userId = userId;
    if (record == null) {
      return;
    }
    if (record.isStaleAt(_now())) {
      await _expire(record);
      return;
    }
    _record = record;
    state = CheckInState(
      phase: CheckInPhase.pending,
      tappedAt: record.reportedAt,
    );
    unawaited(_attempt(retrying: true));
  }

  /// The person tapped I'M OK. Reuses the key of an unconfirmed earlier tap, unless that
  /// one is too old to count: then this tap is a new one with a new key.
  Future<void> checkIn() async {
    await _restored;
    if (!ref.mounted || _inFlight) {
      return;
    }
    if (_waitingOutRateLimit) {
      return;
    }
    _resetTimer?.cancel();
    // A tap that is still unconfirmed is sent again with its own key; only without one
    // does this tap get a new key. One that is too old to count is not sent: this tap
    // replaces it, and the write below overwrites its record.
    if (_record?.isStaleAt(_now()) ?? false) {
      _record = null;
    }
    final retrying = _record != null;
    _record ??= PendingCheckIn(
      userId: _userId,
      idempotencyKey: ref.read(checkInKeyGeneratorProvider)(),
      reportedAt: _now(),
    );
    _failures = 0;
    await _attempt(retrying: retrying);
  }

  /// The person pressed "Try again", or the app came back to the foreground: sends the
  /// unconfirmed tap again with its own key (or, when it is too old to count, drops it
  /// and says so). Does nothing when there is none.
  Future<void> retryNow() async {
    await _restored;
    if (!ref.mounted || _record == null || _inFlight || _waitingOutRateLimit) {
      return;
    }
    await _attempt(retrying: true);
  }

  /// The app is in the foreground again.
  Future<void> onResumed() => retryNow();

  bool get _waitingOutRateLimit {
    final retryAt = state.retryAt;
    return state.phase == CheckInPhase.rateLimited &&
        retryAt != null &&
        _now().isBefore(retryAt);
  }

  Future<void> _attempt({required bool retrying}) async {
    final record = _record;
    if (record == null || _inFlight) {
      return;
    }
    // Before every retry: a tap can age out while the app stays open offline.
    if (record.isStaleAt(_now())) {
      await _expire(record);
      return;
    }
    final epoch = _epoch;
    _inFlight = true;
    _retryTimer?.cancel();
    state = CheckInState(
      phase: CheckInPhase.sending,
      tappedAt: record.reportedAt,
      retrying: retrying,
    );
    try {
      // Written before the request so a kill during it cannot lose the key.
      await _store.write(record);
      final result = await ref
          .read(checkInRepositoryProvider)
          .checkIn(
            idempotencyKey: record.idempotencyKey,
            clientReportedAt: record.reportedAt,
          );
      if (!_alive(epoch)) {
        return;
      }
      _record = null;
      _failures = 0;
      await _store.clearFor(_userId);
      if (!_alive(epoch)) {
        return;
      }
      state = CheckInState(phase: CheckInPhase.success, result: result);
      _resetTimer?.cancel();
      _resetTimer = ref.read(checkInTimerProvider)(checkInSuccessDuration, () {
        if (ref.mounted && state.phase == CheckInPhase.success) {
          state = const CheckInState();
        }
      });
    } on Object catch (error) {
      if (!_alive(epoch)) {
        return;
      }
      await _settle(record, toAppFailure(error));
    } finally {
      if (epoch == _epoch) {
        _inFlight = false;
      }
    }
  }

  /// Decides what a failed attempt means for the tap.
  Future<void> _settle(PendingCheckIn record, AppFailure failure) async {
    switch (failure) {
      case RateLimitedFailure(:final retryAfter):
        final wait =
            retryAfter == null || retryAfter < const Duration(seconds: 1)
            ? const Duration(minutes: 1)
            : retryAfter;
        state = CheckInState(
          phase: CheckInPhase.rateLimited,
          tappedAt: record.reportedAt,
          failure: failure,
          retryAt: _now().add(wait),
        );
        _scheduleRetry(wait);
      case ConflictFailure(code: 'safe_required'):
        // Contacts were already told: this tap cannot be recorded and retrying cannot
        // change that. I'M SAFE is the way out.
        await _drop();
        state = CheckInState(
          phase: CheckInPhase.safeRequired,
          failure: failure,
        );
      case UnauthorizedFailure():
        state = CheckInState(
          phase: CheckInPhase.signInRequired,
          tappedAt: record.reportedAt,
          failure: failure,
        );
      case UpgradeRequiredFailure():
        // Kept: it is sent once the app is updated.
        state = CheckInState(
          phase: CheckInPhase.failed,
          tappedAt: record.reportedAt,
          failure: failure,
        );
      case NetworkFailure() || ServerFailure() || UnknownFailure():
        _failures++;
        state = CheckInState(
          phase: CheckInPhase.pending,
          tappedAt: record.reportedAt,
          failure: failure,
        );
        _scheduleRetry(
          checkInBackoff[(_failures - 1).clamp(0, checkInBackoff.length - 1)],
        );
      default:
        // An answer retrying cannot change (validation, forbidden, not found, ...).
        await _drop();
        state = CheckInState(phase: CheckInPhase.failed, failure: failure);
    }
  }

  Future<void> _drop() async {
    _record = null;
    _failures = 0;
    await _store.clearFor(_userId);
  }

  /// [record] is too old to count: nothing is sent for it, its retry is cancelled and it
  /// is forgotten, and the person is told.
  Future<void> _expire(PendingCheckIn record) async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _record = null;
    _failures = 0;
    state = CheckInState(
      phase: CheckInPhase.expired,
      tappedAt: record.reportedAt,
    );
    await _store.clearFor(_userId);
  }

  /// The I'M SAFE path took over (or the incident is over): "confirm you're safe" is no
  /// longer what the last tap was answered with.
  void dismissSafeRequired() {
    if (state.phase == CheckInPhase.safeRequired) {
      state = const CheckInState();
    }
  }

  /// The incident [incidentId] is known to be over (a read of it says so, or I'M SAFE for
  /// it was answered "already closed"). Drops a `safe_required` answer that is about it,
  /// or that names no incident; one that names another incident is left alone.
  void dismissSafeRequiredFor(String? incidentId) {
    if (state.phase != CheckInPhase.safeRequired) {
      return;
    }
    final named = state.failure?.problem?.incidentId;
    if (incidentId == null || named == null || named == incidentId) {
      state = const CheckInState();
    }
  }

  /// The person read (or dismissed) the notice of a tap that was too old to count.
  void dismissExpiredNotice() {
    if (state.phase == CheckInPhase.expired) {
      state = const CheckInState();
    }
  }

  void _scheduleRetry(Duration wait) {
    _retryTimer?.cancel();
    _retryTimer = ref.read(checkInTimerProvider)(wait, () {
      _retryTimer = null;
      if (ref.mounted) {
        unawaited(retryNow());
      }
    });
  }
}

final checkInControllerProvider =
    NotifierProvider<CheckInController, CheckInState>(CheckInController.new);

/// Starts timers for retries and the success reset. Tests replace it.
final checkInTimerProvider = Provider<CheckInTimerFactory>((ref) => Timer.new);

/// Creates the idempotency key of a tap (a random UUID v4). Tests replace it.
final checkInKeyGeneratorProvider = Provider<String Function()>(
  (ref) =>
      () => const Uuid().v4(),
);
