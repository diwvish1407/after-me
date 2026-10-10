import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/design_system/design_system.dart';
import '../../../core/security/app_lock/app_lock_controller.dart';
import '../../../core/security/app_lock/local_auth_gateway.dart';
import '../../../l10n/gen/app_localizations.dart';

/// Settings > Security > App lock: on/off and how long the app may stay in the
/// background before it locks (SECURITY.md §11).
class AppLockSettingsScreen extends ConsumerStatefulWidget {
  const AppLockSettingsScreen({super.key});

  @override
  ConsumerState<AppLockSettingsScreen> createState() =>
      _AppLockSettingsScreenState();
}

class _AppLockSettingsScreenState extends ConsumerState<AppLockSettingsScreen> {
  bool _busy = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    ref.read(appLockControllerProvider.notifier).refreshCapability();
  }

  Future<void> _toggle(bool on) async {
    final l10n = AppLocalizations.of(context);
    final lock = ref.read(appLockControllerProvider.notifier);
    setState(() {
      _busy = true;
      _notice = null;
    });
    String? notice;
    if (on) {
      final result = await lock.enable(l10n.appLockEnableReason);
      notice = switch (result) {
        EnableLockResult.enabled => null,
        EnableLockResult.notAvailable => l10n.appLockNoScreenLock,
        EnableLockResult.notConfirmed => l10n.appLockNotConfirmed,
      };
    } else {
      final off = await lock.disable(l10n.appLockDisableReason);
      notice = off ? null : l10n.appLockNotConfirmed;
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
    final noScreenLock = lock.capability == LockCapability.noScreenLock;
    return FormPage(
      title: l10n.securityAppLock,
      children: [
        BodyText(l10n.appLockIntro),
        Gap.md,
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.appLockSwitch),
          subtitle: Text(lock.enabled ? l10n.appLockOn : l10n.appLockOff),
          value: lock.enabled,
          onChanged: _busy ? null : _toggle,
        ),
        if (_notice != null) ...[
          Gap.sm,
          StatusBanner(kind: StatusBannerKind.attention, message: _notice!),
        ] else if (noScreenLock && !lock.enabled) ...[
          Gap.sm,
          StatusBanner(
            kind: StatusBannerKind.info,
            message: l10n.appLockNoScreenLock,
          ),
        ],
        if (lock.enabled) ...[
          Gap.lg,
          Semantics(
            header: true,
            child: Text(
              l10n.appLockTimeoutTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Gap.xs,
          RadioGroup<AppLockTimeout>(
            groupValue: lock.timeout,
            onChanged: (value) {
              if (value != null) {
                ref.read(appLockControllerProvider.notifier).setTimeout(value);
              }
            },
            child: Column(
              children: [
                for (final option in AppLockTimeout.values)
                  RadioListTile<AppLockTimeout>(
                    contentPadding: EdgeInsets.zero,
                    value: option,
                    title: Text(switch (option) {
                      AppLockTimeout.immediately => l10n.appLockTimeoutNow,
                      AppLockTimeout.oneMinute => l10n.appLockTimeoutOne,
                      AppLockTimeout.fiveMinutes => l10n.appLockTimeoutFive,
                    }),
                  ),
              ],
            ),
          ),
        ],
        Gap.lg,
        BodyText(l10n.appLockFootnote),
      ],
    );
  }
}
