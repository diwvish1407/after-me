import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/application/account_session.dart';
import '../../auth/application/me_controller.dart';
import '../../auth/presentation/legal_links.dart';
import '../../checkin/application/checkin_controller.dart';
import '../../shell/presentation/home_back_button.dart';
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
    final t = context.tokens;
    const purple = Color(0xFF6A3DE8);
    const teal = Color(0xFF00897B);
    final account = [
      SetupRow(
        icon: Icons.person_rounded,
        color: t.primary,
        title: l10n.settingsProfile,
        onTap: () => context.push(AppRoutes.settingsProfile),
      ),
      SetupRow(
        icon: Icons.shield_rounded,
        color: t.ok,
        title: l10n.settingsSecurity,
        onTap: () => context.push(AppRoutes.settingsSecurity),
      ),
      SetupRow(
        icon: Icons.notifications_rounded,
        color: t.attention,
        title: l10n.settingsNotifications,
        onTap: () => context.push(AppRoutes.settingsNotifications),
      ),
      SetupRow(
        icon: Icons.inventory_2_rounded,
        color: purple,
        title: l10n.settingsYourPlan,
        onTap: () => context.push(AppRoutes.settingsYourPlan),
      ),
      SetupRow(
        icon: Icons.list_alt_rounded,
        color: teal,
        title: l10n.settingsActivity,
        onTap: () => context.push(AppRoutes.settingsActivity),
      ),
    ];
    final checkIns = [
      SetupRow(
        icon: Icons.calendar_month_rounded,
        color: purple,
        title: l10n.settingsCheckInSchedule,
        onTap: () => context.push(AppRoutes.settingsSchedule),
      ),
      SetupRow(
        icon: Icons.history_rounded,
        color: t.primary,
        title: l10n.settingsCheckInHistory,
        onTap: () => context.push(AppRoutes.settingsCheckInHistory),
      ),
      SetupRow(
        icon: Icons.event_busy_rounded,
        color: t.escalation,
        title: l10n.settingsIncidents,
        onTap: () => context.push(AppRoutes.settingsIncidents),
      ),
    ];
    final privacy = [
      SetupRow(
        icon: Icons.lock_rounded,
        color: t.primary,
        title: l10n.settingsPrivacyKeeps,
        onTap: () => context.push(AppRoutes.settingsPrivacy),
      ),
      SetupRow(
        icon: Icons.download_rounded,
        color: teal,
        title: l10n.settingsExport,
        onTap: () => context.push(AppRoutes.settingsExport),
      ),
      SetupRow(
        icon: Icons.delete_rounded,
        color: t.escalation,
        title: l10n.settingsDelete,
        onTap: () => context.push(AppRoutes.settingsDelete),
      ),
    ];
    final help = [
      SetupRow(
        icon: Icons.phonelink_erase_rounded,
        color: t.attention,
        title: l10n.settingsLostPhone,
        onTap: () => context.push(AppRoutes.settingsLostPhone),
      ),
      SetupRow(
        icon: Icons.description_rounded,
        color: purple,
        title: l10n.legalTerms,
        onTap: () => openLegalPage(context, ref, LegalPage.terms),
      ),
      SetupRow(
        icon: Icons.privacy_tip_rounded,
        color: t.ok,
        title: l10n.legalPrivacy,
        onTap: () => openLegalPage(context, ref, LegalPage.privacy),
      ),
      SetupRow(
        icon: Icons.info_rounded,
        color: t.primary,
        title: l10n.settingsAbout,
        onTap: () => context.push(AppRoutes.settingsAbout),
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navProfile),
        leading: const HomeBackButton(),
      ),
      body: SafeArea(
        child: CenteredScrollView(
          alignTop: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (me != null)
                GlassCard(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: t.primaryContainer,
                        child: Text(
                          me.profile.displayName.isEmpty
                              ? '?'
                              : me.profile.displayName.characters.first
                                    .toUpperCase(),
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(color: t.primary),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              me.profile.displayName,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            FitText(
                              me.email,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: t.textMuted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              _Section(title: l10n.settingsSectionAccount, rows: account),
              _Section(title: l10n.settingsSectionCheckIns, rows: checkIns),
              _Section(title: l10n.settingsSectionPrivacy, rows: privacy),
              _Section(title: l10n.settingsSectionHelp, rows: help),
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

/// A titled group of rows in one card, like "Your setup" on Home.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows});

  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: AppSpacing.md,
            bottom: AppSpacing.xs,
          ),
          child: Semantics(
            header: true,
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        GlassCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Column(children: rows),
        ),
      ],
    );
  }
}
