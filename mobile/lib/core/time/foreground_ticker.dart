import 'dart:async';

import 'package:flutter/widgets.dart';

/// A repeating timer that exists **only while the app is in the foreground**.
///
/// AfterMe does no background work (TEST_PLAN PERF-05, battery): a `Timer.periodic` that
/// keeps running in a pocket would wake the CPU, and the radio too if it reads the
/// server. This is the one place (besides Home's own, which also follows the tab that is
/// on view) where a periodic timer is created, and the static test
/// `test/perf/no_background_work_test.dart` keeps it that way.
///
/// * [start] begins ticking (when the app is in the foreground) and listens to the
///   lifecycle: `paused` and `hidden` cancel the timer, `resumed` starts it again and
///   calls [onForeground] once (what the screen shows is computed from the clock and may
///   have aged while the app was away). `inactive` (a system dialog, the notification
///   shade) changes nothing: the app is still on screen.
/// * [stop] cancels the timer and stops listening; call it from `dispose`.
/// * What a tick does is the owner's business; it should only redraw, or read through a
///   path that is itself bounded.
class ForegroundTicker with WidgetsBindingObserver {
  ForegroundTicker({
    required this.period,
    required this.onTick,
    this.onForeground,
  });

  final Duration period;
  final VoidCallback onTick;

  /// Called when the app returns to the foreground, after the timer was started again.
  final VoidCallback? onForeground;

  Timer? _timer;
  bool _started = false;
  bool _foreground = true;

  /// The timer is running right now (started, and the app is in the foreground).
  bool get isRunning => _timer != null;

  /// Whether [start] was called and [stop] was not.
  bool get isStarted => _started;

  void start() {
    if (_started) {
      return;
    }
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground =
        state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _sync();
  }

  void stop() {
    if (!_started) {
      return;
    }
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _foreground = false;
        _sync();
      case AppLifecycleState.resumed:
        if (!_foreground) {
          _foreground = true;
          _sync();
          onForeground?.call();
        }
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  void _sync() {
    if (_started && _foreground) {
      _timer ??= Timer.periodic(period, (_) => onTick());
    } else {
      _cancel();
    }
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
