import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../features/auth/application/account_session.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../design_system/app_button.dart';
import '../../design_system/empty_state.dart';
import '../../design_system/status_banner.dart';
import 'app_lock_controller.dart';
import 'local_auth_gateway.dart';

/// The screen that covers the app while it is locked. It shows nothing from the account.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen>
    with WidgetsBindingObserver {
  bool _prompted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Ask once when the lock appears; the person can ask again with the button.
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoPrompt());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _autoPrompt();
    }
  }

  Future<void> _autoPrompt() async {
    if (!mounted || _prompted) {
      return;
    }
    // The system prompt cannot be shown while the activity is not in the foreground
    // (cold start, or the first frame after the app went to the background); wait for
    // the resume instead of getting a spurious "unavailable" answer.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return;
    }
    _prompted = true;
    await _unlock();
  }

  Future<void> _unlock() {
    final l10n = AppLocalizations.of(context);
    return ref
        .read(appLockControllerProvider.notifier)
        .unlock(l10n.appLockUnlockReason);
  }

  Future<void> _turnOff() async {
    final l10n = AppLocalizations.of(context);
    // The controller re-checks that the phone really has no screen lock before it agrees.
    await ref
        .read(appLockControllerProvider.notifier)
        .disable(l10n.appLockDisableReason, force: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final lock = ref.watch(appLockControllerProvider);
    final outcome = lock.lastOutcome;
    final message = switch (outcome) {
      AuthOutcome.failed => l10n.lockFailed,
      AuthOutcome.lockedOut => l10n.lockLockedOut,
      AuthOutcome.canceled => l10n.lockCanceled,
      AuthOutcome.unavailableNow => l10n.lockUnavailableNow,
      _ => null,
    };
    // "Turn off" only when the phone confirmed it has no screen lock, never because one
    // prompt could not be shown.
    final unavailable =
        outcome == AuthOutcome.notAvailable &&
        lock.capability == LockCapability.noScreenLock;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: CenteredScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              EmptyState(
                icon: Icons.lock_outline_rounded,
                title: l10n.lockTitle,
                message: unavailable ? l10n.lockUnavailable : l10n.lockBody,
              ),
              if (message != null) ...[
                const SizedBox(height: AppSpacing.md),
                StatusBanner(
                  kind: StatusBannerKind.info,
                  message: message,
                  liveRegion: true,
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              if (unavailable)
                AppButton.primary(
                  label: l10n.lockTurnOff,
                  onPressed: _turnOff,
                  expand: true,
                )
              else
                AppButton.primary(
                  label: l10n.lockUnlock,
                  icon: Icons.fingerprint_rounded,
                  isLoading: lock.authenticating,
                  onPressed: _unlock,
                  expand: true,
                ),
              const SizedBox(height: AppSpacing.xs),
              AppButton.text(
                label: l10n.signOut,
                onPressed: () => ref.read(accountSessionProvider).signOut(),
                expand: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
