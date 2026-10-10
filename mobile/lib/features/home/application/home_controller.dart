import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/time/clock.dart';
import '../../auth/application/me_controller.dart';
import '../../checkin/application/checkin_controller.dart';
import '../../checkin/application/schedule_controller.dart';
import '../../checkin/data/models/checkin_models.dart';
import '../../contacts/application/contacts_controller.dart';
import '../../plan/application/plan_controller.dart';
import '../data/home_repository.dart';

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
  int _epoch = 0;
  Future<AppFailure?>? _refreshing;

  @override
  Future<HomeData?> build() async {
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
      })
      ..listen(scheduleControllerProvider, (previous, next) {
        final before = previous?.value;
        final after = next.value;
        // A settings change or an on/off switch. A schedule that was only read again
        // after a check-in (same version) is what Home already applied from the answer.
        if (before != null &&
            after != null &&
            (before.version != after.version ||
                before.status != after.status)) {
          unawaited(refresh());
        }
      })
      ..listen(planControllerProvider, (previous, next) {
        final before = previous?.value;
        final after = next.value;
        // A saved plan, or the latest one read after a 412: the aggregate counts its
        // stages and judges its readiness.
        if (before != null &&
            after != null &&
            before.version != after.version) {
          unawaited(refresh());
        }
      })
      ..listen(contactsControllerProvider, (previous, next) {
        final before = previous?.value;
        final after = next.value;
        if (before != null && after != null && !listEquals(before, after)) {
          unawaited(refresh());
        }
      })
      ..listen(meControllerProvider, (previous, next) {
        final before = previous?.value?.profile.timezone;
        final after = next.value?.profile.timezone;
        if (before != null && after != null && before != after) {
          unawaited(refresh());
        }
      });
    try {
      return _data(await ref.watch(homeRepositoryProvider).load());
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
    final future = _refresh().whenComplete(() => _refreshing = null);
    return _refreshing = future;
  }

  Future<AppFailure?> _refresh() async {
    if (ref.read(authControllerProvider) != AuthStatus.signedIn) {
      return null;
    }
    final epoch = _epoch;
    try {
      final snapshot = await ref.read(homeRepositoryProvider).load();
      if (!ref.mounted) {
        return null;
      }
      if (epoch != _epoch) {
        // A check-in was applied while this read was on its way, so it may be older
        // than what is on screen. Read once more.
        _refreshing = null;
        return await refresh();
      }
      state = AsyncData(_data(snapshot));
      return null;
    } on Object catch (error) {
      final failure = toAppFailure(error);
      if (!ref.mounted) {
        return failure;
      }
      final current = state.value;
      if (current != null) {
        state = AsyncData(current.copyWith(stale: failure.isTransient));
      } else {
        state = AsyncError<HomeData?>(failure, StackTrace.current);
      }
      return failure;
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
