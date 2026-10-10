import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/application/account_session.dart';
import '../../auth/application/me_controller.dart';
import '../../auth/presentation/legal_links.dart';
import 'settings_widgets.dart';

/// USER_FLOWS.md §11: the settings list. Sub-screens live under `/settings/...`.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await confirmAction(
      context,
      title: l10n.signOutConfirmTitle,
      message: l10n.signOutConfirmBody,
      confirmLabel: l10n.signOutConfirm,
      cancelLabel: l10n.cancel,
    );
    if (confirmed) {
      await ref.read(accountSessionProvider).signOut();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final me = ref.watch(meControllerProvider).value;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.navSettings)),
      body: SafeArea(
        child: CenteredScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (me != null) ...[
                Semantics(
                  container: true,
                  child: Card(
                    child: ListTile(
                      minTileHeight: 64,
                      leading: const Icon(Icons.account_circle_outlined),
                      title: Text(me.profile.displayName),
                      subtitle: FitText(me.email),
                    ),
                  ),
                ),
              ],
              SettingsSectionHeader(l10n.settingsSectionCheckIns),
              SettingsTile(
                icon: Icons.schedule_rounded,
                title: l10n.settingsCheckInSchedule,
                subtitle: l10n.settingsCheckInScheduleSubtitle,
                onTap: () => context.push(AppRoutes.settingsSchedule),
              ),
              SettingsTile(
                icon: Icons.history_rounded,
                title: l10n.settingsCheckInHistory,
                subtitle: l10n.settingsCheckInHistorySubtitle,
                onTap: () => context.push(AppRoutes.settingsCheckInHistory),
              ),
              SettingsSectionHeader(l10n.settingsSectionAccount),
              SettingsTile(
                icon: Icons.person_outline_rounded,
                title: l10n.settingsProfile,
                onTap: () => context.push(AppRoutes.settingsProfile),
              ),
              SettingsTile(
                icon: Icons.shield_outlined,
                title: l10n.settingsSecurity,
                subtitle: l10n.settingsSecuritySubtitle,
                onTap: () => context.push(AppRoutes.settingsSecurity),
              ),
              SettingsTile(
                icon: Icons.notifications_none_rounded,
                title: l10n.settingsNotifications,
                onTap: () => context.push(AppRoutes.settingsNotifications),
              ),
              SettingsSectionHeader(l10n.settingsSectionHelp),
              SettingsTile(
                icon: Icons.description_outlined,
                title: l10n.legalTerms,
                trailing: const Icon(Icons.open_in_new_rounded),
                onTap: () => openLegalPage(context, ref, LegalPage.terms),
              ),
              SettingsTile(
                icon: Icons.privacy_tip_outlined,
                title: l10n.legalPrivacy,
                trailing: const Icon(Icons.open_in_new_rounded),
                onTap: () => openLegalPage(context, ref, LegalPage.privacy),
              ),
              SettingsTile(
                icon: Icons.info_outline_rounded,
                title: l10n.settingsAbout,
                onTap: () => context.push(AppRoutes.settingsAbout),
              ),
              Gap.lg,
              AppButton.secondary(
                label: l10n.signOut,
                icon: Icons.logout_rounded,
                onPressed: () => _signOut(context, ref),
                expand: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
