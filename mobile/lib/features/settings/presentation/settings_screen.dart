import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/application/account_session.dart';
import '../../auth/application/me_controller.dart';
import '../../auth/presentation/legal_links.dart';
import '../../checkin/application/checkin_controller.dart';
import 'settings_widgets.dart';

/// USER_FLOWS.md §11: the settings list. Sub-screens live under `/settings/...`.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    // A tap the server has not confirmed stays on this phone and is sent after the next
    // sign-in: the person should know it has not counted yet.
    final unsent = ref.read(checkInControllerProvider).isUnconfirmed;
    final confirmed = await confirmAction(
      context,
      title: l10n.signOutConfirmTitle,
      message: unsent
          ? '${l10n.signOutConfirmBody} ${l10n.signOutConfirmPendingBody}'
          : l10n.signOutConfirmBody,
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
              SettingsTile(
                icon: Icons.event_busy_outlined,
                title: l10n.settingsIncidents,
                subtitle: l10n.settingsIncidentsSubtitle,
                onTap: () => context.push(AppRoutes.settingsIncidents),
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
              SettingsTile(
                icon: Icons.workspace_premium_outlined,
                title: l10n.settingsYourPlan,
                subtitle: l10n.settingsYourPlanSubtitle,
                onTap: () => context.push(AppRoutes.settingsYourPlan),
              ),
              SettingsTile(
                icon: Icons.list_alt_rounded,
                title: l10n.settingsActivity,
                subtitle: l10n.settingsActivitySubtitle,
                onTap: () => context.push(AppRoutes.settingsActivity),
              ),
              SettingsSectionHeader(l10n.settingsSectionPrivacy),
              SettingsTile(
                icon: Icons.lock_outline_rounded,
                title: l10n.settingsPrivacyKeeps,
                subtitle: l10n.settingsPrivacyKeepsSubtitle,
                onTap: () => context.push(AppRoutes.settingsPrivacy),
              ),
              SettingsTile(
                icon: Icons.download_outlined,
                title: l10n.settingsExport,
                subtitle: l10n.settingsExportSubtitle,
                onTap: () => context.push(AppRoutes.settingsExport),
              ),
              SettingsTile(
                icon: Icons.delete_outline_rounded,
                title: l10n.settingsDelete,
                subtitle: l10n.settingsDeleteSubtitle,
                onTap: () => context.push(AppRoutes.settingsDelete),
              ),
              SettingsSectionHeader(l10n.settingsSectionHelp),
              SettingsTile(
                icon: Icons.phonelink_erase_outlined,
                title: l10n.settingsLostPhone,
                subtitle: l10n.settingsLostPhoneSubtitle,
                onTap: () => context.push(AppRoutes.settingsLostPhone),
              ),
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
