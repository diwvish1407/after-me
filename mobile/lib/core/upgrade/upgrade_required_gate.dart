import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/dimens.dart';
import '../../app/theme/tokens.dart';
import '../../l10n/gen/app_localizations.dart';
import '../api/upgrade_gate.dart';
import '../config/app_config.dart';
import '../design_system/app_button.dart';
import '../design_system/empty_state.dart';
import '../links/url_opener.dart';
import 'upgrade_recheck.dart';

/// Covers the whole app with the "Update AfterMe" screen while the server refuses this
/// version of the app (`426 upgrade_required`, USER_FLOWS.md §14).
///
/// It sits **above the Navigator** (in `MaterialApp.builder`, inside the app lock), like
/// `AppLockGate`: the app below is kept alive but is not painted, cannot be tapped and
/// is hidden from screen readers. Its state is untouched, so a form the person was in
/// keeps what they typed; a pending check-in stays in storage and is sent after the
/// update. [onRecheck] asks the server again and says what it found: accepted (the gate
/// goes), refused (still 426) or inconclusive (no usable answer: nothing is claimed).
class UpgradeRequiredGate extends ConsumerStatefulWidget {
  const UpgradeRequiredGate({
    required this.child,
    required this.onRecheck,
    super.key,
  });

  final Widget child;

  /// Makes one request so the server can say whether this version is accepted now, and
  /// reports what it found. A refused or inconclusive result keeps the gate; the screen
  /// words each differently.
  final Future<UpgradeRecheck> Function() onRecheck;

  @override
  ConsumerState<UpgradeRequiredGate> createState() =>
      _UpgradeRequiredGateState();
}

class _UpgradeRequiredGateState extends ConsumerState<UpgradeRequiredGate>
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

  /// The Back button must not reach the hidden Navigator while the gate is up: popping
  /// its pages would throw away what the person has not saved.
  @override
  Future<bool> didPopRoute() async => ref.read(upgradeGateProvider);

  @override
  Widget build(BuildContext context) {
    final gated = ref.watch(upgradeGateProvider);
    if (gated) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Offstage(
          offstage: gated,
          child: TickerMode(
            enabled: !gated,
            child: ExcludeSemantics(
              excluding: gated,
              child: ExcludeFocus(excluding: gated, child: widget.child),
            ),
          ),
        ),
        if (gated)
          Positioned.fill(
            child: UpgradeRequiredScreen(onRecheck: widget.onRecheck),
          ),
      ],
    );
  }
}

/// The blocking screen: what is wrong in one sentence, what is kept, and the way to the
/// update. Nothing here asks for anything and nothing is lost by leaving it.
class UpgradeRequiredScreen extends ConsumerStatefulWidget {
  const UpgradeRequiredScreen({required this.onRecheck, super.key});

  final Future<UpgradeRecheck> Function() onRecheck;

  @override
  ConsumerState<UpgradeRequiredScreen> createState() =>
      _UpgradeRequiredScreenState();
}

class _UpgradeRequiredScreenState extends ConsumerState<UpgradeRequiredScreen> {
  bool _checking = false;

  /// What the last "Check again" found, while the gate is still up.
  UpgradeRecheck? _found;
  bool _openFailed = false;

  Future<void> _open() async {
    final opened = await ref
        .read(urlOpenerProvider)
        .open(ref.read(appConfigProvider).playStoreUrl);
    if (mounted) {
      setState(() => _openFailed = !opened);
    }
  }

  Future<void> _recheck() async {
    setState(() {
      _checking = true;
      _found = null;
    });
    var found = UpgradeRecheck.inconclusive;
    try {
      found = await widget.onRecheck();
    } on Object {
      // No answer: nothing is known.
    }
    if (mounted) {
      setState(() {
        _checking = false;
        // Accepted lifts the gate and this screen goes with it; if it is still here
        // the server did not (yet) say so.
        _found = ref.read(upgradeGateProvider) ? found : null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: CenteredScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              EmptyState(
                icon: Icons.system_update_outlined,
                title: l10n.upgradeTitle,
                message: l10n.upgradeBody,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                l10n.upgradeKept,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(color: t.textMuted),
              ),
              if (_openFailed || _found != null) ...[
                const SizedBox(height: AppSpacing.md),
                Semantics(
                  liveRegion: true,
                  container: true,
                  child: Text(
                    _openFailed
                        ? l10n.upgradeOpenFailed
                        : _found == UpgradeRecheck.refused
                        ? l10n.upgradeStillOld
                        : l10n.upgradeCheckFailed,
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              AppButton.primary(
                label: l10n.upgradeOpenStore,
                icon: Icons.open_in_new_rounded,
                onPressed: () => unawaited(_open()),
                expand: true,
              ),
              const SizedBox(height: AppSpacing.xs),
              AppButton.text(
                label: l10n.upgradeCheckAgain,
                isLoading: _checking,
                onPressed: () => unawaited(_recheck()),
                expand: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
