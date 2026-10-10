import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/tokens.dart';
import '../../auth/auth_controller.dart';
import 'app_lock_controller.dart';
import 'lock_screen.dart';

/// Covers the whole app with the [LockScreen] while the lock is on.
///
/// It sits **above the Navigator** (in `MaterialApp.builder`), so the lock also covers
/// bottom sheets, dialogs and anything else on the navigator stack, which a route-based
/// lock screen could not do. While locked, the app below is kept alive but is not
/// painted, cannot be tapped, cannot take focus or the Back button, and is hidden from
/// screen readers.
///
/// It also feeds the app's lifecycle changes into [AppLockController].
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref.read(appLockControllerProvider.notifier).didChangeLifecycle(state);
  }

  /// The Back button must not reach the hidden Navigator while the lock is up. This
  /// observer is registered before the app's Router, so it answers first.
  @override
  Future<bool> didPopRoute() async {
    final signedIn = ref.read(authControllerProvider) == AuthStatus.signedIn;
    return _isCovered(
      signedIn: signedIn,
      lock: ref.read(appLockControllerProvider),
    );
  }

  // Until the settings are read the app stays covered, so a locked app never flashes
  // its content on a cold start.
  static bool _isCovered({
    required bool signedIn,
    required AppLockState lock,
  }) => signedIn && (!lock.loaded || lock.locked);

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(authControllerProvider) == AuthStatus.signedIn;
    final lock = ref.watch(appLockControllerProvider);
    final covered = _isCovered(signedIn: signedIn, lock: lock);
    if (covered) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Offstage(
          offstage: covered,
          child: TickerMode(
            enabled: !covered,
            child: ExcludeSemantics(
              excluding: covered,
              // Offstage children keep focus: keep the keyboard and switch access out.
              child: ExcludeFocus(excluding: covered, child: widget.child),
            ),
          ),
        ),
        if (covered)
          Positioned.fill(
            child: lock.loaded
                ? const LockScreen()
                : ColoredBox(color: context.tokens.bg),
          ),
      ],
    );
  }
}
