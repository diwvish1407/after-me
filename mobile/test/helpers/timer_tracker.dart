import 'dart:async';

/// Records every `Timer.periodic` (and, separately, every one-shot `Timer` and
/// `Future.delayed`) created inside [run], and whether it is still active.
///
/// Used by the battery tests: they open a screen inside [run], send lifecycle changes
/// through the test binding and ask how many periodic timers are alive. The binding's own
/// fake clock still drives the timers; this only watches them.
class TimerTracker {
  final List<TrackedTimer> _periodic = [];
  final List<TrackedTimer> _oneShot = [];

  /// Every periodic timer created so far, cancelled or not.
  int get periodicCreated => _periodic.length;

  /// Periodic timers that are alive now.
  int get activePeriodic => _periodic.where((t) => t.isActive).length;

  /// The periods of the periodic timers that are alive now.
  List<Duration> get activePeriods => [
    for (final t in _periodic)
      if (t.isActive) t.period,
  ];

  /// One-shot timers created so far.
  int get oneShotCreated => _oneShot.length;

  /// One-shot timers that are still waiting.
  int get activeOneShot => _oneShot.where((t) => t.isActive).length;

  Future<T> run<T>(Future<T> Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createPeriodicTimer: (self, parent, zone, period, callback) {
        late final TrackedTimer tracked;
        final inner = parent.createPeriodicTimer(
          zone,
          period,
          (_) => callback(tracked),
        );
        tracked = TrackedTimer(inner, period);
        _periodic.add(tracked);
        return tracked;
      },
      createTimer: (self, parent, zone, duration, callback) {
        final inner = parent.createTimer(zone, duration, callback);
        final tracked = TrackedTimer(inner, duration);
        _oneShot.add(tracked);
        return tracked;
      },
    ),
  );
}

class TrackedTimer implements Timer {
  TrackedTimer(this._inner, this.period);

  final Timer _inner;
  final Duration period;

  @override
  void cancel() => _inner.cancel();

  @override
  bool get isActive => _inner.isActive;

  @override
  int get tick => _inner.tick;
}
