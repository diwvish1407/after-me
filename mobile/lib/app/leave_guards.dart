import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Screens with unsaved work, and the question each asks before it may be left.
///
/// Back and the tab bar already ask (`PopScope`, `AppShell`). Code that moves the person
/// by itself with the router's `go`, which replaces the page stack and so skips every
/// `PopScope`, must ask the same question first: a notification tap is the one case today.
/// A screen registers while it has something to lose and removes itself when it has not
/// or when it goes; nothing here is ever persisted.
///
/// A question is only for what can wait. A tap that is about an open incident must never
/// be held up by one (the person needs I'M OK or I'M SAFE): see `PushType.isUrgent` and
/// `PushCoordinator`, which put Home on top of the screen instead of asking.
class LeaveGuards {
  final Map<Object, _Guard> _guards = {};

  /// Whether any screen has something to lose right now.
  bool get isGuarding => _guards.isNotEmpty;

  /// Whether any screen is in the middle of saving its work.
  bool get isBusy => _guards.values.any((g) => g.isBusy());

  /// [ask] answers true when it is all right to leave [owner]'s screen (the person
  /// chose to, or there turned out to be nothing to lose) and false to stay. [isBusy]
  /// says that the screen is saving right now.
  void register(
    Object owner,
    Future<bool> Function() ask, {
    bool Function()? isBusy,
  }) => _guards[owner] = _Guard(ask, isBusy ?? () => false);

  void unregister(Object owner) => _guards.remove(owner);

  /// Waits, for at most [maxWait], until no screen is saving. Returns whether none is.
  Future<bool> whenIdle({
    Duration maxWait = const Duration(seconds: 10),
    Duration poll = const Duration(milliseconds: 100),
  }) async {
    final deadline = DateTime.now().add(maxWait);
    while (isBusy) {
      if (DateTime.now().isAfter(deadline)) {
        return false;
      }
      await Future<void>.delayed(poll);
    }
    return true;
  }

  /// Asks every guarding screen in turn; false as soon as one says stay.
  Future<bool> confirmLeave() async {
    for (final guard in List.of(_guards.values)) {
      if (!await guard.ask()) {
        return false;
      }
    }
    return true;
  }
}

class _Guard {
  const _Guard(this.ask, this.isBusy);

  final Future<bool> Function() ask;
  final bool Function() isBusy;
}

final leaveGuardsProvider = Provider<LeaveGuards>((ref) => LeaveGuards());
