import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A counter that goes up when something the Home aggregate is built from changed: the
/// schedule (its version or its on/off state), the plan (its version), the contacts (the
/// list), or the profile (name or timezone).
///
/// Home follows **this counter** and never listens to those controllers themselves: a
/// listener starts the controller's read, so listening used to make every cold start of
/// a signed-in phone read the schedule, the contacts, the plan and the account (`GET
/// /v1/me`) on top of `GET /v1/home`, which already carries all of it in summary. Now
/// those controllers load when a screen that needs them opens, and each of them bumps
/// this counter (`listenSelf`, with the same comparison Home made before) when what it
/// holds really changed. The same pattern as `instructionChangesProvider`.
class HomeInputChanges extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final homeInputChangesProvider = NotifierProvider<HomeInputChanges, int>(
  HomeInputChanges.new,
);
