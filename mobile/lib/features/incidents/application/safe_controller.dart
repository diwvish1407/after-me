import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/session_epoch.dart';
import '../data/incidents_repository.dart';

/// Where the person's I'M SAFE confirmation stands.
enum SafePhase {
  /// Nothing is in flight.
  idle,

  /// The request is on the wire.
  sending,

  /// The server answered 200 (and only then): the incident is stopped.
  success,

  /// The server did not confirm it. [SafeState.failure] says why; nothing may be shown
  /// as done.
  failed,
}

@immutable
class SafeState {
  const SafeState({
    this.phase = SafePhase.idle,
    this.incidentId,
    this.result,
    this.failure,
  });

  final SafePhase phase;

  /// The incident the confirmation is about.
  final String? incidentId;

  /// The server's answer, in [SafePhase.success].
  final SafeResult? result;

  /// Why it is not confirmed, in [SafePhase.failed].
  final AppFailure? failure;

  bool get isSending => phase == SafePhase.sending;

  /// The incident was already closed (409 `invalid_state`): nothing more to do.
  bool get alreadyClosed =>
      phase == SafePhase.failed && failure is InvalidStateFailure;

  /// The server asked for the password again (403 `reauth_required`).
  bool get needsPassword =>
      phase == SafePhase.failed &&
      failure is ForbiddenFailure &&
      (failure! as ForbiddenFailure).code == 'reauth_required';

  /// The answer did not arrive (offline, a server error, a timeout): whether the server
  /// recorded it is not known, and the same key is sent again to find out. A 429 is not
  /// this: the server answered, and it did not process the request.
  bool get notConfirmed =>
      phase == SafePhase.failed &&
      switch (failure) {
        NetworkFailure() || ServerFailure() || UnknownFailure() => true,
        _ => false,
      };

  @override
  bool operator ==(Object other) =>
      other is SafeState &&
      other.phase == phase &&
      other.incidentId == incidentId &&
      other.result == result &&
      other.failure == failure;

  @override
  int get hashCode => Object.hash(phase, incidentId, result, failure);
}

/// I'M SAFE (USER_FLOWS.md §7): `POST /incidents/{id}/safe`.
///
/// * Success is the server's 200 and nothing else; it never shows "marked safe" before.
/// * One confirmation gets **one** idempotency key. It is kept while the answer is not
///   known (offline, a 5xx, a timeout, a 429, a 401, or a 403 `reauth_required` that
///   needs the password again) and used again by the next [markSafe], so the server
///   stops the incident and tells the contacts once. It is dropped after an answer
///   retrying cannot change (the incident is closed, not found, refused).
/// * While a request is in flight another [markSafe] returns the same request: a double
///   tap sends one.
/// * The key lives in memory. After a restart the next Home read shows the truth (closed,
///   or still open); a new tap then sends a new key, and an incident that was already
///   closed is answered with a calm 409 `invalid_state`.
class SafeController extends Notifier<SafeState> {
  String? _incidentId;
  String? _key;
  Future<SafeResult>? _pending;

  /// An answer for the account that signed out must never land in the one that signed
  /// in after it: it would show B "you're marked safe" for A's incident, and Home would
  /// close B's real incident on screen.
  final SessionEpoch _session = SessionEpoch();

  bool _alive(int session) => ref.mounted && _session.isCurrent(session);

  @override
  SafeState build() {
    // Signing out (or a revoked session) drops everything.
    _session.next();
    ref.watch(authControllerProvider);
    _incidentId = null;
    _key = null;
    _pending = null;
    return const SafeState();
  }

  /// Confirms that the person is safe. Throws the [AppFailure] on error (a
  /// `ForbiddenFailure` with code `reauth_required` is what `withReauth` reacts to; the
  /// same key is then sent again).
  Future<SafeResult> markSafe(String incidentId) {
    final running = _pending;
    if (running != null) {
      return running;
    }
    final future = _send(incidentId);
    _pending = future;
    // Only its own entry: another account's request may have taken the slot meanwhile.
    void done() {
      if (identical(_pending, future)) {
        _pending = null;
      }
    }

    unawaited(future.then<void>((_) => done(), onError: (Object _) => done()));
    return future;
  }

  Future<SafeResult> _send(String incidentId) async {
    final session = _session.current;
    if (_incidentId != incidentId) {
      // Another incident is another intent.
      _incidentId = incidentId;
      _key = null;
    }
    final key = _key ??= ref.read(safeKeyGeneratorProvider)();
    state = SafeState(phase: SafePhase.sending, incidentId: incidentId);
    try {
      final result = await ref
          .read(incidentsRepositoryProvider)
          .markSafe(incidentId, idempotencyKey: key);
      if (_alive(session)) {
        _key = null;
        _incidentId = null;
        state = SafeState(
          phase: SafePhase.success,
          incidentId: incidentId,
          result: result,
        );
      }
      return result;
    } on Object catch (error) {
      final failure = toAppFailure(error);
      if (_alive(session)) {
        if (!_answerMayStillCome(failure)) {
          _key = null;
          _incidentId = null;
        }
        state = SafeState(
          phase: SafePhase.failed,
          incidentId: incidentId,
          failure: failure,
        );
      }
      throw failure;
    }
  }

  /// Whether [failure] leaves the question open (the same key is then sent again) as
  /// opposed to answering it.
  bool _answerMayStillCome(AppFailure failure) => switch (failure) {
    NetworkFailure() ||
    ServerFailure() ||
    UnknownFailure() ||
    RateLimitedFailure() ||
    UnauthorizedFailure() ||
    UpgradeRequiredFailure() => true,
    ForbiddenFailure(:final code) => code == 'reauth_required',
    _ => false,
  };

  /// Forgets a finished or failed attempt when the sheet that showed it closes. A key
  /// that is still waiting for an answer is kept.
  void reset() {
    if (_pending == null) {
      state = const SafeState();
    }
  }
}

final safeControllerProvider = NotifierProvider<SafeController, SafeState>(
  SafeController.new,
);

/// Creates the idempotency key of one I'M SAFE confirmation (a random UUID v4). Tests
/// replace it.
final safeKeyGeneratorProvider = Provider<String Function()>(
  (ref) =>
      () => const Uuid().v4(),
);
