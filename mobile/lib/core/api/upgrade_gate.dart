import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the server has refused this version of the app (`426 upgrade_required`).
///
/// It is raised by the API client the moment **any** request is answered with 426 (a
/// repository does not have to know about it) and cleared when a later request
/// succeeds. While it is raised the app shows the blocking "Update AfterMe" screen
/// above everything else (`UpgradeRequiredGate`).
///
/// Raising it changes nothing else: a pending check-in stays in storage (it is sent once
/// the app is up to date), and the screens under the gate keep their state, so nothing
/// the person has typed is lost.
class UpgradeGate extends Notifier<bool> {
  @override
  bool build() => false;

  /// The server answered 426.
  void raise() => state = true;

  /// A request succeeded: the version is accepted.
  void clear() => state = false;
}

final upgradeGateProvider = NotifierProvider<UpgradeGate, bool>(
  UpgradeGate.new,
);
