import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/session_epoch.dart';
import '../../../core/time/clock.dart';
import '../../checkin/application/checkin_controller.dart';
import '../../checkin/data/models/checkin_models.dart';
import '../../contacts/application/contacts_controller.dart';
import '../../incidents/application/safe_controller.dart';
import '../../incidents/data/models/incident_models.dart';
import '../../instructions/application/instructions_controller.dart';
import '../data/home_repository.dart';
import 'home_inputs.dart';

/// The last good Home aggregate and what is needed to read its times correctly.
@immutable
class HomeData {
  const HomeData({
    required this.snapshot,
    required this.serverOffset,
    this.stale = false,
  });

  final HomeSnapshot snapshot;

  /// `server_time - the phone's clock` when [snapshot] arrived. Every "is it due
  /// soon" decision uses the phone's clock plus this offset, so a phone with a wrong
  /// clock still shows the server's idea of the time.
  final Duration serverOffset;

  /// The latest refresh failed (offline, server trouble): this is the last known
  /// status, kept in memory, and Home says so.
  final bool stale;

  /// The server's current time, estimated from the phone's clock [deviceNow].
  DateTime serverNow(DateTime deviceNow) => deviceNow.add(serverOffset);

  HomeData copyWith({
    HomeSnapshot? snapshot,
    Duration? serverOffset,
    bool? stale,
  }) => HomeData(
    snapshot: snapshot ?? this.snapshot,
    serverOffset: serverOffset ?? this.serverOffset,
    stale: stale ?? this.stale,
  );
}

/// The Home aggregate (`GET /home`).
///
/// The first load failing is an error state; a later refresh failing keeps the last
/// good data and marks it [HomeData.stale] ("Offline, showing last known status"). The
/// aggregate is read again after a confirmed check-in, a schedule change, a plan change,
/// a contact change and a timezone change, and by pull-to-refresh and when the app
/// returns.
class HomeController extends AsyncNotifier<HomeData?> {
  /// Counts the changes applied to the aggregate (a check-in, I'M SAFE, a `safe_required`
  /// answer). A read that started before one may be older than what is on screen.
  int _epoch = 0;

  /// Counts sessions: a read that was started for the account that signed out must never
  /// land in the one that signed in after it.
  final SessionEpoch _session = SessionEpoch();
  Future<AppFailure?>? _refreshing;

  @override
  Future<HomeData?> build() async {
    final session = _session.next();
    // Another account's read in flight is not this one's: it is not joined.
    _refreshing = null;
    if (ref.watch(authControllerProvider) != AuthStatus.signedIn) {
      return null;
    }
    ref
      ..listen(checkInControllerProvider, (previous, next) {
        final result = next.result;
        if (next.phase == CheckInPhase.success &&
            result != null &&
            result != previous?.result) {
          _applyCheckIn(result);
        }
        // The server says contacts were already told, which the aggregate on screen
        // may not: read it again so Home shows the I'M SAFE path. A read that is already
        // on its way may be older than that answer, so it is read once more after it.
        if (next.phase == CheckInPhase.safeRequired &&
            previous?.phase != CheckInPhase.safeRequired) {
          _epoch++;
          unawaited(refresh());
        }
      })
      ..listen(safeControllerProvider, (previous, next) {
        final result = next.result;
        if (next.phase == SafePhase.success &&
            result != null &&
            result != previous?.result) {
          _applyMarkedSafe(result);
        }
        // The incident was already closed (somewhere else, or by the worker): Home must
        // not keep showing it, and no "confirm you're safe" about it may stay behind.
        if (next.alreadyClosed && !(previous?.alreadyClosed ?? false)) {
          ref
              .read(checkInControllerProvider.notifier)
              .dismissSafeRequiredFor(next.incidentId);
          unawaited(refresh());
        }
      })
      // The aggregate is built from the schedule, the plan, the contacts and the profile:
      // those controllers bump this counter when what they hold really changed (a
      // listener on them would start their reads at every cold start; see
      // `HomeInputChanges`).
      ..listen(homeInputChangesProvider, (previous, next) {
        unawaited(refresh());
      })
      // The aggregate counts the active instructions and judges recipients who have not
      // accepted. This follows the changes, not the list: the list's read needs the
      // password, and Home does not start it.
      ..listen(instructionChangesProvider, (previous, next) {
        unawaited(refresh());
      });
    try {
      final snapshot = await ref.watch(homeRepositoryProvider).load();
      if (ref.mounted && _session.isCurrent(session)) {
        _reconcile(snapshot);
      }
      return _data(snapshot);
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  HomeData _data(HomeSnapshot snapshot) => HomeData(
    snapshot: snapshot,
    serverOffset: snapshot.serverTime.difference(ref.read(clockProvider)()),
  );

  /// Reads Home again. Returns the failure, or null. With data on hand a failure marks
  /// it stale instead of replacing it; without, the failure becomes the state.
  Future<AppFailure?> refresh() {
    final running = _refreshing;
    if (running != null) {
      return running;
    }
    late final Future<AppFailure?> future;
    future = _refresh().whenComplete(() {
      // Only its own entry: another account's read may have taken the slot meanwhile.
      if (identical(_refreshing, future)) {
        _refreshing = null;
      }
    });
    return _refreshing = future;
  }

  Future<AppFailure?> _refresh() async {
    if (ref.read(authControllerProvider) != AuthStatus.signedIn) {
      return null;
    }
    final session = _session.current;
    final epoch = _epoch;
    try {
      final snapshot = await ref.read(homeRepositoryProvider).load();
      if (!ref.mounted || !_session.isCurrent(session)) {
        // Another account's answer: nothing of it is applied or reported.
        return null;
      }
      if (epoch != _epoch) {
        // A check-in was applied while this read was on its way, so it may be older
        // than what is on screen. Read once more.
        _refreshing = null;
        return await refresh();
      }
      state = AsyncData(_data(snapshot));
      _reconcile(snapshot);
      return null;
    } on Object catch (error) {
      final failure = toAppFailure(error);
      if (!ref.mounted || !_session.isCurrent(session)) {
        return null;
      }
      final current = state.value;
      if (current != null) {
        // Whatever the failure, this is no longer confirmed to be current.
        state = AsyncData(current.copyWith(stale: true));
      } else {
        state = AsyncError<HomeData?>(failure, StackTrace.current);
      }
      return failure;
    }
  }

  /// What a read that was just applied says about what other controllers hold.
  void _reconcile(HomeSnapshot snapshot) {
    _reconcileSafeRequired(snapshot);
    _reconcileContacts(snapshot.planSummary);
  }

  /// A `safe_required` answer is "contacts were already told, use I'M SAFE" **for one
  /// incident**. When that incident is closed somewhere else (the web I'M SAFE, the
  /// lost-phone flow, the operator) the answer outlives it, and it must not keep Home
  /// asking for I'M SAFE, nor make the next incident (nobody told yet) read as "your
  /// contacts have been notified". The read that just arrived is the truth: the answer
  /// stays only while it still describes the open incident.
  void _reconcileSafeRequired(HomeSnapshot snapshot) {
    final checkIn = ref.read(checkInControllerProvider);
    if (checkIn.phase != CheckInPhase.safeRequired) {
      return;
    }
    final controller = ref.read(checkInControllerProvider.notifier);
    final raw = snapshot.incident;
    if (raw == null) {
      // No open incident. (A schedule that says "incident open" without one cannot
      // happen through the API; what the server said is kept then.)
      if (snapshot.checkin.status != CheckInStatus.incidentOpen) {
        controller.dismissSafeRequired();
      }
      return;
    }
    final named = checkIn.failure?.problem?.incidentId;
    final id = raw['id'];
    if (named != null && id is String && id != named) {
      // Another incident is open now: the answer was about one that is over.
      controller.dismissSafeRequired();
      return;
    }
    final incident = snapshot.incidentDetails;
    if (incident == null) {
      // This version cannot read it: nothing is judged from it.
      return;
    }
    // An answer that named its incident stays while that incident is open (contacts are
    // never "un-told"). One that did not cannot be tied to this incident, so an incident
    // that says nobody was told settles it.
    if (incident.isClosed || (named == null && !incident.needsSafe)) {
      controller.dismissSafeRequired();
    }
  }

  /// A contact can accept (or decline) out of band, which only the server sees: the
  /// People tab would keep saying "Pending" while Home says "1 of 1 accepted". When the
  /// counts of the aggregate disagree with the list on hand, the list is read again. It
  /// is read silently (the list stays on screen until the new one replaces it).
  void _reconcileContacts(PlanSummary summary) {
    // Only a list that is on hand can disagree: `read` would start its read.
    if (!ref.exists(contactsControllerProvider)) {
      return;
    }
    final contacts = ref.read(contactsControllerProvider).value;
    if (contacts == null) {
      return;
    }
    final verified = contacts.where((c) => c.isAccepted).length;
    if (verified != summary.contactsVerified ||
        contacts.length != summary.contactsTotal) {
      unawaited(ref.read(contactsControllerProvider.notifier).reload());
    }
  }

  /// Puts a confirmed check-in on screen straight away (the server's own numbers), then
  /// reads the aggregate to catch up with everything else.
  ///
  /// The clock offset is **not** taken from the check-in response: after an offline
  /// retry the server replays the original answer (`Idempotent-Replayed: true`), whose
  /// `server_time` can be hours old. Only `GET /home` calibrates the offset.
  void _applyCheckIn(CheckInResult result) {
    final current = state.value;
    if (current == null) {
      unawaited(refresh());
      return;
    }
    _epoch++;
    final checkin = current.snapshot.checkin;
    state = AsyncData(
      current.copyWith(
        stale: false,
        snapshot: current.snapshot.copyWith(
          // A resolved incident closes; otherwise the status is what it was.
          incident: result.incidentResolved ? null : current.snapshot.incident,
          checkin: checkin.copyWith(
            status:
                result.incidentResolved &&
                    checkin.status == CheckInStatus.incidentOpen
                ? CheckInStatus.active
                : checkin.status,
            nextDueAt: result.nextDueAt,
            lastCheckinAt: result.checkin.receivedAt,
          ),
        ),
      ),
    );
    unawaited(refresh());
  }

  /// Puts a confirmed I'M SAFE on screen straight away (the server's own numbers: the
  /// incident is closed and the schedule restarted), then reads the aggregate to catch
  /// up with everything else.
  void _applyMarkedSafe(SafeResult result) {
    // Whatever the check-in tap said about I'M SAFE being needed is over.
    ref.read(checkInControllerProvider.notifier).dismissSafeRequired();
    final current = state.value;
    if (current == null) {
      unawaited(refresh());
      return;
    }
    _epoch++;
    final checkin = current.snapshot.checkin;
    state = AsyncData(
      current.copyWith(
        stale: false,
        snapshot: current.snapshot.copyWith(
          incident: null,
          checkin: checkin.copyWith(
            status: checkin.status == CheckInStatus.incidentOpen
                ? (result.nextDueAt == null
                      ? CheckInStatus.inactive
                      : CheckInStatus.active)
                : checkin.status,
            nextDueAt: result.nextDueAt,
            lastCheckinAt: result.serverTime,
          ),
        ),
      ),
    );
    unawaited(refresh());
  }
}

final homeControllerProvider = AsyncNotifierProvider<HomeController, HomeData?>(
  HomeController.new,
);

/// The server's current time as best known: the phone's clock plus the offset of the
/// last `GET /home` (the phone's clock alone before that). Used wherever a day such as
/// "Tomorrow" is derived from the present.
final serverNowProvider = Provider<DateTime Function()>((ref) {
  final offset =
      ref.watch(homeControllerProvider.select((v) => v.value?.serverOffset)) ??
      Duration.zero;
  final clock = ref.watch(clockProvider);
  return () => clock().add(offset);
});

/// A Hold blocks contact-facing work right now (`service.interruption`), as of the last
/// read of Home. False before there is a read, and for a server that does not say.
final serviceInterruptionProvider = Provider<bool>(
  (ref) =>
      ref.watch(
        homeControllerProvider.select(
          (v) => v.value?.snapshot.serviceInterruption,
        ),
      ) ??
      false,
);
