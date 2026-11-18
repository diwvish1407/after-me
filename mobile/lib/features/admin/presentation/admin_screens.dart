import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/repository_providers.dart';
import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/design_system/app_button.dart';
import '../../../core/design_system/app_text_field.dart';
import '../../../core/design_system/brand.dart';
import '../../../core/design_system/error_view.dart';
import '../../../core/design_system/form_page.dart';
import '../../../core/design_system/loading_view.dart';
import '../../../core/time/clock.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../data/admin_repository.dart';

final _overviewProvider = FutureProvider.autoDispose<AdminOverview>(
  (ref) => ref.watch(adminRepositoryProvider).overview(),
);

final _usersProvider = FutureProvider.autoDispose
    .family<(List<AdminUser>, int), String>(
      (ref, query) => ref.watch(adminRepositoryProvider).users(query: query),
    );

final _userProvider = FutureProvider.autoDispose
    .family<AdminUserDetail, String>(
      (ref, id) => ref.watch(adminRepositoryProvider).user(id),
    );

final _incidentsProvider = FutureProvider.autoDispose<List<AdminIncident>>(
  (ref) => ref.watch(adminRepositoryProvider).incidents(),
);

/// Asks why (the audit trail keeps it). Null when cancelled.
Future<String?> _askReason(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  final field = TextEditingController();
  final reason = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.adminReasonTitle),
      content: AppTextField(
        label: l10n.adminReasonTitle,
        hint: l10n.adminReasonHint,
        controller: field,
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.adminCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(field.text.trim()),
          child: Text(l10n.adminConfirm),
        ),
      ],
    ),
  );
  field.dispose();
  return reason == null || reason.length < 3 ? null : reason;
}

/// Runs an admin change behind the password step and reports the outcome.
Future<bool> _change(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() action,
) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final done = await withReauth(context, () async {
      await action();
      return true;
    });
    if (done == true) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.adminSaved)));
      return true;
    }
  } on Object catch (error) {
    if (context.mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text(failureMessage(l10n, toAppFailure(error)))),
      );
    }
  }
  return false;
}

/// The admin home: figures, the contact-message pause (Hold), open alerts and every
/// account. Instruction content is never shown here.
class AdminDashboardScreen extends ConsumerStatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  ConsumerState<AdminDashboardScreen> createState() =>
      _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends ConsumerState<AdminDashboardScreen> {
  final _search = TextEditingController();
  String _query = '';
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final t = context.tokens;
    final overview = ref.watch(_overviewProvider);
    final users = ref.watch(_usersProvider(_query));
    return BrandPage(
      title: l10n.adminTitle,
      onRefresh: () async {
        ref
          ..invalidate(_overviewProvider)
          ..invalidate(_usersProvider);
      },
      children: [
        Semantics(
          header: true,
          child: Text(l10n.adminOverview, style: text.titleMedium),
        ),
        Gap.sm,
        switch (overview) {
          AsyncData(:final value) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: AppSpacing.xs,
                crossAxisSpacing: AppSpacing.xs,
                childAspectRatio: 0.95,
                children: [
                  StatTile(
                    icon: Icons.people_alt_rounded,
                    value: '${value.count('users_total')}',
                    label: l10n.adminStatAccounts,
                  ),
                  StatTile(
                    icon: Icons.verified_rounded,
                    value: '${value.count('users_active')}',
                    label: l10n.adminStatActive,
                    color: t.ok,
                  ),
                  StatTile(
                    icon: Icons.block_rounded,
                    value: '${value.count('users_suspended')}',
                    label: l10n.adminStatSuspended,
                    color: t.attention,
                  ),
                  StatTile(
                    icon: Icons.alarm_on_rounded,
                    value: '${value.count('schedules_active')}',
                    label: l10n.adminStatSchedules,
                  ),
                  StatTile(
                    icon: Icons.notifications_active_rounded,
                    value: '${value.count('incidents_open')}',
                    label: l10n.adminStatOpen,
                    color: t.escalation,
                    onTap: () => context.push(AppRoutes.adminIncidents),
                  ),
                  StatTile(
                    icon: Icons.check_circle_rounded,
                    value: '${value.count('checkins_24h')}',
                    label: l10n.adminStatCheckins,
                    color: t.ok,
                  ),
                ],
              ),
              Gap.md,
              _HoldCard(active: value.holdActive),
            ],
          ),
          AsyncError(:final error) => FailureNotice.of(
            context,
            toAppFailure(error),
          ),
          _ => const LoadingView(),
        },
        Gap.md,
        AppButton.secondary(
          label: l10n.adminIncidents,
          icon: Icons.warning_amber_rounded,
          onPressed: () => context.push(AppRoutes.adminIncidents),
          expand: true,
        ),
        Gap.lg,
        Semantics(
          header: true,
          child: Text(l10n.adminUsers, style: text.titleMedium),
        ),
        Gap.sm,
        AppTextField(
          label: l10n.adminSearch,
          controller: _search,
          textInputAction: TextInputAction.search,
          onChanged: (value) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 400), () {
              if (mounted) {
                setState(() => _query = value.trim());
              }
            });
          },
        ),
        Gap.sm,
        switch (users) {
          AsyncData(:final value) when value.$1.isEmpty => Text(
            l10n.adminNone,
            style: text.bodyMedium,
          ),
          AsyncData(:final value) => GlassCard(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Column(
              children: [
                for (final user in value.$1)
                  SetupRow(
                    icon: user.role == 'admin'
                        ? Icons.admin_panel_settings_rounded
                        : Icons.person_rounded,
                    color: user.status == 'active' ? t.primary : t.attention,
                    title: user.displayName ?? user.email,
                    subtitle: '${user.email} · ${user.status} · ${user.tier}',
                    onTap: () => context.push(AppRoutes.adminUser(user.id)),
                  ),
              ],
            ),
          ),
          AsyncError(:final error) => FailureNotice.of(
            context,
            toAppFailure(error),
          ),
          _ => const LoadingView(),
        },
      ],
    );
  }
}

class _HoldCard extends ConsumerWidget {
  const _HoldCard({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final t = context.tokens;
    return GlassCard(
      color: active ? t.attentionContainer : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.adminHoldTitle, style: text.titleMedium),
          Gap.xs,
          Text(
            active ? l10n.adminHoldOnBody : l10n.adminHoldOffBody,
            style: text.bodyMedium,
          ),
          Gap.md,
          AppButton.secondary(
            label: active ? l10n.adminHoldExit : l10n.adminHoldEnter,
            icon: active ? Icons.play_arrow_rounded : Icons.pause_rounded,
            onPressed: () async {
              final repo = ref.read(adminRepositoryProvider);
              if (active) {
                await _change(context, ref, repo.holdExit);
              } else {
                final reason = await _askReason(context);
                if (reason == null || !context.mounted) {
                  return;
                }
                await _change(context, ref, () => repo.holdEnter(reason));
              }
              ref.invalidate(_overviewProvider);
            },
            expand: true,
          ),
        ],
      ),
    );
  }
}

/// One account: status, schedule, check-in times, contacts (masked addresses), alerts,
/// and the admin actions. Never instruction content.
class AdminUserScreen extends ConsumerWidget {
  const AdminUserScreen({required this.userId, super.key});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final t = context.tokens;
    final detail = ref.watch(_userProvider(userId));
    final repo = ref.read(adminRepositoryProvider);
    Future<void> act(Future<void> Function(String reason) action) async {
      final reason = await _askReason(context);
      if (reason == null || !context.mounted) {
        return;
      }
      if (await _change(context, ref, () => action(reason))) {
        ref
          ..invalidate(_userProvider(userId))
          ..invalidate(_usersProvider)
          ..invalidate(_overviewProvider);
      }
    }

    return BrandPage(
      title: l10n.adminTitle,
      onRefresh: () async => ref.invalidate(_userProvider(userId)),
      children: [
        switch (detail) {
          AsyncData(:final value) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      value.user.displayName ?? value.user.email,
                      style: text.titleLarge,
                    ),
                    Text(value.user.email, style: text.bodyMedium),
                    Gap.sm,
                    Text(l10n.adminUserStatus(value.user.status)),
                    Text(l10n.adminUserTier(value.user.tier)),
                    Text(l10n.adminUserRole(value.user.role)),
                    if (value.timezone != null)
                      Text(l10n.adminUserTimezone(value.timezone!)),
                    Text(
                      l10n.adminUserSchedule(value.user.scheduleStatus ?? '-'),
                    ),
                    Text(
                      l10n.adminUserTwoStep(
                        value.mfaEnabled
                            ? l10n.twoStepStatusOn
                            : l10n.twoStepStatusOff,
                      ),
                    ),
                    Text(l10n.adminUserInstructions(value.instructionsActive)),
                  ],
                ),
              ),
              Gap.md,
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  if (value.user.status == 'suspended')
                    OutlinedButton(
                      onPressed: () => act((r) => repo.unsuspend(userId, r)),
                      child: Text(l10n.adminUnsuspend),
                    )
                  else
                    OutlinedButton(
                      onPressed: () => act((r) => repo.suspend(userId, r)),
                      child: Text(l10n.adminSuspend),
                    ),
                  OutlinedButton(
                    onPressed: () => act(
                      (r) => repo.setTier(
                        userId,
                        value.user.tier == 'free' ? 'premium' : 'free',
                        r,
                      ),
                    ),
                    child: Text(l10n.adminChangeTier),
                  ),
                  OutlinedButton(
                    onPressed: () => act(
                      (r) => repo.setRole(
                        userId,
                        value.user.role == 'admin' ? 'user' : 'admin',
                        r,
                      ),
                    ),
                    child: Text(
                      value.user.role == 'admin'
                          ? l10n.adminRemoveAdmin
                          : l10n.adminMakeAdmin,
                    ),
                  ),
                ],
              ),
              Gap.lg,
              Text(l10n.adminUserEvents, style: text.titleMedium),
              Gap.xs,
              if (value.events.isEmpty)
                Text(l10n.adminNone)
              else
                for (final e in value.events)
                  Text('${e['label']} · ${e['due_local_time']}'),
              Gap.lg,
              Text(l10n.adminUserContacts, style: text.titleMedium),
              Gap.xs,
              if (value.contacts.isEmpty)
                Text(l10n.adminNone)
              else
                for (final c in value.contacts)
                  Text(
                    '${c['display_name']} (${c['relationship']}) · '
                    '${c['email_masked'] ?? '-'} · ${c['verification_status']}',
                  ),
              Gap.lg,
              Text(l10n.adminUserIncidents, style: text.titleMedium),
              Gap.xs,
              if (value.incidents.isEmpty)
                Text(l10n.adminNone)
              else
                for (final i in value.incidents)
                  _IncidentRow(incident: i, color: t.escalation),
            ],
          ),
          AsyncError(:final error) => FailureNotice.of(
            context,
            toAppFailure(error),
          ),
          _ => const LoadingView(),
        },
      ],
    );
  }
}

class _IncidentRow extends ConsumerWidget {
  const _IncidentRow({required this.incident, required this.color});

  final AdminIncident incident;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final now = ref.read(clockProvider)();
    return SetupRow(
      icon: incident.open
          ? Icons.notifications_active_rounded
          : Icons.task_alt_rounded,
      color: incident.open ? color : context.tokens.ok,
      title: incident.email ?? incident.status,
      subtitle:
          '${incident.status} · ${l10n.adminOpenSince(formatDayTime(context, l10n, incident.missedDueAt, now: now))}',
      onTap: () async {
        if (!incident.open) {
          return;
        }
        final sure = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.adminVoid),
            content: Text(l10n.adminVoidBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l10n.adminCancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(l10n.adminConfirm),
              ),
            ],
          ),
        );
        if (sure == true && context.mounted) {
          await _change(
            context,
            ref,
            () => ref.read(adminRepositoryProvider).voidIncident(incident.id),
          );
          ref
            ..invalidate(_incidentsProvider)
            ..invalidate(_overviewProvider)
            ..invalidate(_userProvider);
        }
      },
    );
  }
}

/// Every open alert across accounts; tapping one offers to end it.
class AdminIncidentsScreen extends ConsumerWidget {
  const AdminIncidentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final incidents = ref.watch(_incidentsProvider);
    final t = context.tokens;
    return BrandPage(
      title: l10n.adminIncidents,
      onRefresh: () async => ref.invalidate(_incidentsProvider),
      children: [
        switch (incidents) {
          AsyncData(:final value) when value.isEmpty => Text(l10n.adminNone),
          AsyncData(:final value) => GlassCard(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Column(
              children: [
                for (final i in value)
                  _IncidentRow(incident: i, color: t.escalation),
              ],
            ),
          ),
          AsyncError(:final error) => FailureNotice.of(
            context,
            toAppFailure(error),
          ),
          _ => const LoadingView(),
        },
      ],
    );
  }
}
