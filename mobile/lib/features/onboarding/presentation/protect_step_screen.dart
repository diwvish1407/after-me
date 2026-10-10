import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/design_system/design_system.dart';
import '../../../core/security/app_lock/app_lock_controller.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/onboarding_controller.dart';
import 'notification_prompt.dart';
import 'onboarding_scaffold.dart';

/// Step 8: stay protected. App lock, notification permission (with a pre-prompt) and a
/// battery tip. Everything here is optional.
class ProtectStepScreen extends ConsumerStatefulWidget {
  const ProtectStepScreen({super.key});

  @override
  ConsumerState<ProtectStepScreen> createState() => _ProtectStepScreenState();
}

class _ProtectStepScreenState extends ConsumerState<ProtectStepScreen> {
  bool _busy = false;
  String? _notice;

  Future<void> _toggleLock(bool on) async {
    final l10n = AppLocalizations.of(context);
    final lock = ref.read(appLockControllerProvider.notifier);
    setState(() {
      _busy = true;
      _notice = null;
    });
    String? notice;
    if (on) {
      notice = switch (await lock.enable(l10n.appLockEnableReason)) {
        EnableLockResult.enabled => null,
        EnableLockResult.notAvailable => l10n.appLockNoScreenLock,
        EnableLockResult.notConfirmed => l10n.appLockNotConfirmed,
      };
    } else {
      notice = await lock.disable(l10n.appLockDisableReason)
          ? null
          : l10n.appLockNotConfirmed;
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _notice = notice;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final lock = ref.watch(appLockControllerProvider);
    return OnboardingScaffold(
      step: OnboardingStep.protect,
      title: l10n.protectStepTitle,
      subtitle: l10n.protectStepBody,
      primaryLabel: l10n.actionContinue,
      onPrimary: () => advanceFrom(context, ref, OnboardingStep.protect),
      children: [
        SectionCard(
          title: l10n.securityAppLock,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.protectAppLockBody),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.appLockSwitch),
                value: lock.enabled,
                onChanged: _busy ? null : _toggleLock,
              ),
              if (_notice != null)
                StatusBanner(kind: StatusBannerKind.info, message: _notice!),
            ],
          ),
        ),
        Gap.md,
        const NotificationPrompt(),
        Gap.md,
        SectionCard(
          title: l10n.batteryTipTitle,
          child: Text(l10n.batteryTipBody),
        ),
      ],
    );
  }
}
