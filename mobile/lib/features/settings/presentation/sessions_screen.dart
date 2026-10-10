import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/application/account_session.dart';
import '../../auth/application/sessions_controller.dart';
import '../../auth/data/models/account_models.dart';
import 'settings_widgets.dart';

/// Settings > Security > Active sessions: where the account is signed in.
class SessionsScreen extends ConsumerWidget {
  const SessionsScreen({super.key});

  Future<void> _revoke(
    BuildContext context,
    WidgetRef ref,
    SessionItem item,
  ) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await confirmAction(
      context,
      title: l10n.sessionRevokeTitle,
      message: l10n.sessionRevokeBody,
      confirmLabel: l10n.sessionRevoke,
      cancelLabel: l10n.cancel,
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(sessionsControllerProvider.notifier).revoke(item.id);
      messenger.showSnackBar(SnackBar(content: Text(l10n.sessionRevoked)));
    } on AppFailure catch (failure) {
      messenger.showSnackBar(
        SnackBar(content: Text(failureMessage(l10n, failure))),
      );
    }
  }

  Future<void> _logoutAll(BuildContext context, WidgetRef ref) async {
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
    final sessions = ref.watch(sessionsControllerProvider);
    return FormPage(
      title: l10n.securitySessions,
      children: [
        BodyText(l10n.sessionsIntro),
        Gap.md,
        sessions.when(
          data: (items) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (items.isEmpty)
                BodyText(l10n.sessionsEmpty)
              else
                for (final item in items)
                  _SessionCard(
                    item: item,
                    onRevoke: item.current
                        ? null
                        : () => _revoke(context, ref, item),
                  ),
              Gap.md,
              AppButton.secondary(
                label: l10n.logoutAll,
                icon: Icons.devices_rounded,
                onPressed: () => _logoutAll(context, ref),
                expand: true,
              ),
            ],
          ),
          loading: () => const LoadingView(),
          error: (error, _) => ErrorView(
            failure: error is AppFailure ? error : UnknownFailure(cause: error),
            onRetry: () =>
                ref.read(sessionsControllerProvider.notifier).refresh(),
          ),
        ),
      ],
    );
  }
}

/// A readable platform name from the API's lowercase value.
String _platformName(AppLocalizations l10n, String platform) =>
    switch (platform.toLowerCase()) {
      'android' => 'Android',
      'ios' => 'iOS',
      'web' => 'Web',
      _ => l10n.sessionPlatformOther,
    };

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.item, required this.onRevoke});

  final SessionItem item;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final material = MaterialLocalizations.of(context);
    final device = item.device;
    final platform = device == null
        ? null
        : _platformName(l10n, device.platform);
    final title = device == null
        ? l10n.sessionWeb
        : (device.appVersion == null
              ? l10n.sessionDevice(platform!)
              : l10n.sessionDeviceVersion(platform!, device.appVersion!));
    final lastUsed = item.lastUsedAt.toLocal();
    final when =
        '${material.formatMediumDate(lastUsed)}, '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(lastUsed))}';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    device == null
                        ? Icons.language_rounded
                        : Icons.smartphone_rounded,
                    color: t.textMuted,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              if (item.current) ...[
                const SizedBox(height: AppSpacing.xxs),
                Row(
                  children: [
                    Icon(Icons.check_circle_outline, size: 18, color: t.ok),
                    const SizedBox(width: AppSpacing.xxs),
                    Expanded(
                      child: Text(
                        l10n.sessionThisDevice,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: t.ok),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpacing.xxs),
              Text(
                l10n.sessionLastActive(when),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: t.textMuted),
              ),
              if (onRevoke != null)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  // The visible label is the same on every card; the spoken one says which
                  // device it is for.
                  child: Semantics(
                    label: l10n.sessionRevokeFor(title, when),
                    button: true,
                    excludeSemantics: true,
                    onTap: onRevoke,
                    child: AppButton.text(
                      label: l10n.sessionRevoke,
                      onPressed: onRevoke,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
