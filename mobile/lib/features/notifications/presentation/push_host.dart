import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/push_coordinator.dart';

/// Starts push when the app starts and tells it when the app returns to the foreground.
///
/// It sits in `MaterialApp.builder` and paints nothing of its own: the child is returned as
/// it is. All decisions are in [PushCoordinator].
class PushHost extends ConsumerStatefulWidget {
  const PushHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<PushHost> createState() => _PushHostState();
}

class _PushHostState extends ConsumerState<PushHost>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // After the first frame: the router and every provider it needs exist by then.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(pushCoordinatorProvider).start());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(pushCoordinatorProvider).onResumed());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
