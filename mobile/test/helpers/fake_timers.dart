import 'dart:async';

/// A timer that only fires when a test says so.
class FakeTimer implements Timer {
  FakeTimer(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool _active = true;
  int _ticks = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _ticks;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) {
      return;
    }
    _active = false;
    _ticks++;
    _callback();
  }
}

/// Replaces the check-in controller's timers (backoff retries, the success reset).
class FakeTimers {
  final List<FakeTimer> created = [];

  Timer create(Duration delay, void Function() callback) {
    final timer = FakeTimer(delay, callback);
    created.add(timer);
    return timer;
  }

  /// Timers that are still waiting, oldest first.
  List<FakeTimer> get active => [
    for (final timer in created)
      if (timer.isActive) timer,
  ];

  /// Delays of every timer created so far (to assert the backoff).
  List<Duration> get delays => [for (final timer in created) timer.delay];

  /// Fires the oldest waiting timer.
  void fireNext() => active.first.fire();

  /// Fires the waiting timer with the given [delay], if any.
  void fireWithDelay(Duration delay) {
    active.firstWhere((timer) => timer.delay == delay).fire();
  }
}

/// Idempotency keys `key-1`, `key-2`, ...
class FakeKeys {
  int _next = 0;

  final List<String> issued = [];

  String next() {
    final key = 'key-${++_next}';
    issued.add(key);
    return key;
  }
}
