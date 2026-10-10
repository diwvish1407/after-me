import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/design_system/app_button.dart';
import '../../../core/time/clock.dart';
import '../../../l10n/gen/app_localizations.dart';

/// "Send a new code in 0:42" which becomes a button when the wait is over.
///
/// The remaining time is always computed from [availableAt] and the injected clock, so
/// it stays correct after the app was in the background; the one-second timer only
/// triggers a redraw.
class ResendCountdown extends ConsumerStatefulWidget {
  const ResendCountdown({
    required this.availableAt,
    required this.onResend,
    this.busy = false,
    super.key,
  });

  final DateTime? availableAt;
  final VoidCallback onResend;
  final bool busy;

  @override
  ConsumerState<ResendCountdown> createState() => _ResendCountdownState();
}

class _ResendCountdownState extends ConsumerState<ResendCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Whole seconds left, rounded up; 0 when the wait is over.
  int _secondsLeft() {
    final at = widget.availableAt;
    if (at == null) {
      return 0;
    }
    final left = at.difference(ref.read(clockProvider)());
    if (left <= Duration.zero) {
      return 0;
    }
    return (left.inMilliseconds / 1000).ceil();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final seconds = _secondsLeft();
    if (seconds > 0) {
      final minutes = seconds ~/ 60;
      final rest = (seconds % 60).toString().padLeft(2, '0');
      return Semantics(
        liveRegion: false,
        child: Text(
          l10n.resendCountdown('$minutes:$rest'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: context.tokens.textMuted),
        ),
      );
    }
    return AppButton.text(
      label: l10n.resendCode,
      isLoading: widget.busy,
      onPressed: widget.onResend,
      expand: true,
    );
  }
}
