import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/permissions/notification_permission.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../settings/presentation/notifications_settings_screen.dart';

/// The notification pre-prompt (USER_FLOWS.md §3 step 8): explains why, then asks.
///
/// States: not asked / denied (ask), granted (done), blocked (open the system
/// settings). Asking never happens before the person taps the button.
class NotificationPrompt extends ConsumerStatefulWidget {
  const NotificationPrompt({super.key});

  @override
  ConsumerState<NotificationPrompt> createState() => _NotificationPromptState();
}

class _NotificationPromptState extends ConsumerState<NotificationPrompt>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(
      () =>
          ref.read(notificationPermissionControllerProvider.notifier).refresh(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system settings: show what the person chose there.
    if (state == AppLifecycleState.resumed) {
      ref.read(notificationPermissionControllerProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final state = ref.watch(notificationPermissionControllerProvider);
    final controller = ref.read(
      notificationPermissionControllerProvider.notifier,
    );
    final granted = state.status == NotificationPermission.granted;
    final blocked = state.status == NotificationPermission.permanentlyDenied;
    return SectionCard(
      title: l10n.notificationsPromptTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.notificationsPromptBody),
          Gap.sm,
          Row(
            children: [
              Icon(
                granted
                    ? Icons.check_circle_outline
                    : Icons.notifications_off_outlined,
                color: granted ? t.ok : t.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(notificationStatusText(l10n, state.status)),
                ),
              ),
            ],
          ),
          if (!granted) ...[
            Gap.sm,
            if (blocked) ...[
              BodyText(l10n.notificationsBlockedBody),
              Gap.xs,
              AppButton.secondary(
                label: l10n.notificationsOpenSettings,
                icon: Icons.settings_outlined,
                onPressed: controller.openSystemSettings,
                expand: true,
              ),
            ] else
              AppButton.secondary(
                label: l10n.notificationsAllow,
                icon: Icons.notifications_active_outlined,
                isLoading: state.busy,
                onPressed: controller.request,
                expand: true,
              ),
          ],
        ],
      ),
    );
  }
}
