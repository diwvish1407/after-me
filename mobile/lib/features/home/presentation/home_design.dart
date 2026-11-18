import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/design_system/brand.dart';
import '../../../core/security/app_lock/app_lock_controller.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/home_status.dart';
import '../data/models/home_models.dart';

/// The 2026-11 Home (design screens 14-15): greeting and status card, figures, the
/// setup list and quick actions. Purely presentational: the check-in button, incidents
/// and every safety notice stay in `HomeScreen`.

/// "Good morning, Nikhil" by the local hour.
String timeGreeting(AppLocalizations l10n, String name, DateTime local) {
  final hour = local.hour;
  if (hour < 12) {
    return l10n.homeGoodMorning(name);
  }
  if (hour < 17) {
    return l10n.homeGoodAfternoon(name);
  }
  return l10n.homeGoodEvening(name);
}

/// The blue hero: greeting, a line under it, and (except during an incident, which has
/// its own headline) the status card.
class HomeHero extends StatelessWidget {
  const HomeHero({
    required this.name,
    required this.status,
    required this.localNow,
    this.showCard = true,
    super.key,
  });

  final String name;
  final HomeStatus status;
  final DateTime localNow;

  /// The status card under the greeting. Home keeps it below I'M OK, so that the button
  /// stays on the first screen of a small phone (the greeting alone sits above it).
  final bool showCard;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final t = context.tokens;
    final subtitle = switch (status) {
      HomeStatus.incident => l10n.homeSubtitleIncident,
      HomeStatus.dueSoon || HomeStatus.overdue => l10n.homeSubtitlePending,
      _ => l10n.homeSubtitleReady,
    };
    final (title, body, art, tint) = switch (status) {
      HomeStatus.dueSoon || HomeStatus.overdue => (
        l10n.homeHeroDueTitle,
        l10n.homeHeroDueBody,
        BrandIllustration.calendarClock,
        t.attentionContainer,
      ),
      HomeStatus.notActive => (
        l10n.homeHeroSetupTitle,
        l10n.homeHeroSetupBody,
        BrandIllustration.planClipboard,
        t.primaryContainer,
      ),
      _ => (
        l10n.homeHeroPreparedTitle,
        l10n.homeHeroPreparedBody,
        BrandIllustration.shieldHeart,
        t.surface,
      ),
    };
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        gradient: brandHeaderGradient,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (name.isNotEmpty)
            Semantics(
              header: true,
              child: Text(
                timeGreeting(l10n, name, localNow),
                style: text.headlineSmall?.copyWith(color: Colors.white),
              ),
            ),
          Text(subtitle, style: text.bodyMedium?.copyWith(color: Colors.white)),
          if (showCard && status != HomeStatus.incident) ...[
            const SizedBox(height: AppSpacing.md),
            GlassCard(
              color: tint,
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: text.titleLarge),
                        const SizedBox(height: AppSpacing.xxs),
                        Text(body, style: text.bodySmall),
                        if (status == HomeStatus.active) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm,
                              vertical: AppSpacing.xxs,
                            ),
                            decoration: BoxDecoration(
                              color: t.ok,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.check_rounded,
                                  size: 16,
                                  color: t.onPrimary,
                                ),
                                const SizedBox(width: AppSpacing.xxs),
                                Text(
                                  l10n.homeHeroPlanActive,
                                  style: text.labelMedium?.copyWith(
                                    color: t.onPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_roomy(context)) ...[
                    const SizedBox(width: AppSpacing.xs),
                    BrandImage(art, height: 84),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Four figures: contacts, the check-in time, instructions, security.
class HomeStats extends ConsumerWidget {
  const HomeStats({
    required this.snapshot,
    required this.now,
    this.timezone,
    super.key,
  });

  final HomeSnapshot snapshot;
  final DateTime now;
  final String? timezone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final summary = snapshot.planSummary;
    final next = snapshot.checkin.nextDueAt;
    // The app lock is a setting of this phone: no request is needed to show it.
    final mfa = ref.watch(appLockControllerProvider).enabled;
    return _tileRow(context, [
      StatTile(
        icon: Icons.people_alt_rounded,
        value: '${summary.contactsTotal}',
        label: l10n.homeStatContacts,
        onTap: () => context.go(AppRoutes.people),
      ),
      StatTile(
        icon: Icons.event_available_rounded,
        value: next == null
            ? l10n.homeStatOff
            : formatClockTime(context, next, timezone: timezone),
        label: l10n.homeStatCheckIn,
        color: t.primary,
        onTap: () => context.go(AppRoutes.checkIn),
      ),
      StatTile(
        icon: Icons.assignment_turned_in_rounded,
        value: '${summary.instructionsActive}',
        label: l10n.homeStatInstructions,
        onTap: () => context.go(AppRoutes.instructions),
      ),
      StatTile(
        icon: Icons.verified_user_rounded,
        value: mfa ? l10n.homeStatOn : l10n.homeStatOff,
        label: l10n.homeStatSecurity,
        color: mfa ? t.ok : t.textMuted,
        onTap: () => context.push(AppRoutes.settingsTwoStep),
      ),
    ]);
  }
}

/// The "Your setup" card (each row opens its area).
class HomeSetupCard extends ConsumerWidget {
  const HomeSetupCard({required this.snapshot, super.key});

  final HomeSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final summary = snapshot.planSummary;
    final schedule = snapshot.checkin.schedule;
    // The app lock is a setting of this phone: no request is needed to show it.
    final mfa = ref.watch(appLockControllerProvider).enabled;
    String state(bool done) => done ? l10n.homeSetupDone : l10n.homeSetupTodo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A Wrap: at large text sizes the link moves under the heading.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(
              header: true,
              child: Text(l10n.homeSetupTitle, style: text.titleMedium),
            ),
            TextButton(
              onPressed: () => context.go(AppRoutes.settings),
              child: Text(l10n.homeSetupManage),
            ),
          ],
        ),
        GlassCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Column(
            children: [
              SetupRow(
                icon: Icons.people_alt_rounded,
                color: t.primary,
                title: l10n.drawerContacts,
                subtitle: l10n.homeSetupContacts(summary.contactsTotal),
                done: summary.contactsTotal > 0,
                doneLabel: state(summary.contactsTotal > 0),
                onTap: () => context.go(AppRoutes.people),
              ),
              SetupRow(
                icon: Icons.calendar_month_rounded,
                color: const Color(0xFF6A3DE8),
                title: l10n.homeSetupSchedule,
                subtitle: schedule == null
                    ? null
                    : formatMinutesOfDay(context, schedule.dueMinutes),
                done: snapshot.checkin.nextDueAt != null,
                doneLabel: state(snapshot.checkin.nextDueAt != null),
                onTap: () => context.go(AppRoutes.checkIn),
              ),
              SetupRow(
                icon: Icons.emergency_rounded,
                color: t.escalation,
                title: l10n.homeSetupPlan,
                subtitle: l10n.homeSetupPlanBody(summary.stages),
                done: summary.stages > 0,
                doneLabel: state(summary.stages > 0),
                onTap: () => context.go(AppRoutes.plan),
              ),
              SetupRow(
                icon: Icons.description_rounded,
                color: t.primary,
                title: l10n.homeSetupInstructions,
                subtitle: l10n.homeSetupInstructionsBody(
                  summary.instructionsActive,
                ),
                done: summary.instructionsActive > 0,
                doneLabel: state(summary.instructionsActive > 0),
                onTap: () => context.go(AppRoutes.instructions),
              ),
              SetupRow(
                icon: Icons.shield_rounded,
                color: t.ok,
                title: l10n.homeSetupSecurity,
                subtitle: l10n.homeSetupSecurityBody,
                done: mfa,
                doneLabel: state(mfa),
                onTap: () => context.push(AppRoutes.settingsSecurity),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Four shortcuts under the setup list.
class HomeQuickActions extends StatelessWidget {
  const HomeQuickActions({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    return _tileRow(context, [
      StatTile(
        icon: Icons.add_rounded,
        value: '',
        label: l10n.homeQuickAddInstruction,
        onTap: () => context.push(AppRoutes.instructionNew),
      ),
      StatTile(
        icon: Icons.person_add_alt_1_rounded,
        value: '',
        label: l10n.homeQuickAddContact,
        color: const Color(0xFF6A3DE8),
        onTap: () => context.push(AppRoutes.peopleAdd),
      ),
      StatTile(
        icon: Icons.edit_rounded,
        value: '',
        label: l10n.homeQuickEditPlan,
        color: t.attention,
        onTap: () => context.go(AppRoutes.plan),
      ),
      StatTile(
        icon: Icons.settings_rounded,
        value: '',
        label: l10n.homeQuickSettings,
        onTap: () => context.go(AppRoutes.settings),
      ),
    ]);
  }
}

/// The status card on its own (below I'M OK on Home).
class HomeStatusCard extends StatelessWidget {
  const HomeStatusCard({required this.status, super.key});

  final HomeStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final t = context.tokens;
    final (title, body, art, tint) = switch (status) {
      HomeStatus.dueSoon || HomeStatus.overdue => (
        l10n.homeHeroDueTitle,
        l10n.homeHeroDueBody,
        BrandIllustration.calendarClock,
        t.attentionContainer,
      ),
      _ => (
        l10n.homeHeroPreparedTitle,
        l10n.homeHeroPreparedBody,
        BrandIllustration.shieldHeart,
        t.surface,
      ),
    };
    return GlassCard(
      color: tint,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleLarge),
                const SizedBox(height: AppSpacing.xxs),
                Text(body, style: text.bodySmall),
                if (status == HomeStatus.active) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xxs,
                    ),
                    decoration: BoxDecoration(
                      color: t.ok,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      l10n.homeHeroPlanActive,
                      style: text.labelMedium?.copyWith(color: t.onPrimary),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (_roomy(context)) ...[
            const SizedBox(width: AppSpacing.xs),
            BrandImage(art, height: 72),
          ],
        ],
      ),
    );
  }
}

/// At large text sizes the cards drop their picture so the words keep the whole width.
bool _roomy(BuildContext context) => homeRoomy(context);

/// Whether the text is small enough for pictures and side-by-side tiles.
bool homeRoomy(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(16) <= 20;

/// Tiles side by side, or one per line at large text sizes (no word is ever squeezed
/// into a quarter of the screen).
Widget _tileRow(BuildContext context, List<Widget> tiles) {
  if (!_roomy(context)) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, tile) in tiles.indexed) ...[
          if (i > 0) const SizedBox(height: AppSpacing.xs),
          tile,
        ],
      ],
    );
  }
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final (i, tile) in tiles.indexed) ...[
        if (i > 0) const SizedBox(width: AppSpacing.xs),
        Expanded(child: tile),
      ],
    ],
  );
}
