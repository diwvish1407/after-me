import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/security/app_lock/app_lock_controller.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/application/account_session.dart';
import '../../auth/application/me_controller.dart';
import 'settings_widgets.dart';

/// Settings > Security: password, email, sessions, app lock, log out everywhere.
class SecurityScreen extends ConsumerWidget {
  const SecurityScreen({super.key});

  Future<void> _logoutEverywhere(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await confirmAction(
      context,
      title: l10n.logoutAllTitle,
      message: l10n.logoutAllBody,
      confirmLabel: l10n.logoutAllConfirm,
      cancelLabel: l10n.cancel,
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(accountSessionProvider).signOutEverywhere();
    } on AppFailure catch (failure) {
      messenger.showSnackBar(
        SnackBar(content: Text(failureMessage(l10n, failure))),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final me = ref.watch(meControllerProvider).value;
    final lock = ref.watch(appLockControllerProvider);
    return FormPage(
      title: l10n.settingsSecurity,
      children: [
        SettingsTile(
          icon: Icons.password_rounded,
          title: l10n.securityChangePassword,
          onTap: () => context.push(AppRoutes.settingsChangePassword),
        ),
        SettingsTile(
          icon: Icons.alternate_email_rounded,
          title: l10n.securityChangeEmail,
          subtitleWidget: me == null ? null : FitText(me.email),
          onTap: () => context.push(AppRoutes.settingsChangeEmail),
        ),
        SettingsTile(
          icon: Icons.devices_other_rounded,
          title: l10n.securitySessions,
          subtitle: l10n.securitySessionsSubtitle,
          onTap: () => context.push(AppRoutes.settingsSessions),
        ),
        SettingsTile(
          icon: Icons.fingerprint_rounded,
          title: l10n.securityAppLock,
          subtitle: lock.enabled ? l10n.appLockOn : l10n.appLockOff,
          onTap: () => context.push(AppRoutes.settingsAppLock),
        ),
        Gap.lg,
        AppButton.secondary(
          label: l10n.logoutAll,
          icon: Icons.devices_rounded,
          onPressed: () => _logoutEverywhere(context, ref),
          expand: true,
        ),
        Gap.xs,
        BodyText(l10n.logoutAllHint),
      ],
    );
  }
}
