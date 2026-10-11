import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/auth/session_ended_notice.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/time/zoned_time.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/account_closed_notice.dart';

/// "Your account has been closed": the last thing the app says once the server confirmed
/// the deletion. The session is already gone and the phone has been cleaned up; this only
/// tells the person what happened and when the rest is removed, then leads to sign-in.
///
/// It shows the date the server gave (`purge_after`) in the person's own timezone, or a
/// plain "within 30 days" when the answer was not seen.
///
/// When the answer was **not** confirmed (the request lost its answer, and the next one
/// was refused as 401) the same route says so instead: "We couldn't confirm...", that
/// nothing on the phone was removed, and that signing in again carries the check-ins on.
/// A 401 alone is never worded as "closed": the session may have been ended for an
/// unrelated reason while the account and its schedule are live.
class AccountClosedScreen extends ConsumerWidget {
  const AccountClosedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final closed = ref.watch(accountClosedNoticeProvider);
    final confirmed = closed?.confirmed ?? true;
    final purge = closed?.purgeAfter;
    final purgeText = purge == null
        ? l10n.accountClosedPurgeUnknown
        : l10n.accountClosedPurge(
            MaterialLocalizations.of(context)
                .formatFullDate(inTimezone(purge, closed?.timezone)),
          );
    final textTheme = Theme.of(context).textTheme;
    return PopScope(
      // There is nothing to go back to: the account is gone.
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: CenteredScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                EmptyState(
                  icon: confirmed
                      ? Icons.check_circle_outline_rounded
                      : Icons.help_outline_rounded,
                  title: confirmed
                      ? l10n.accountClosedTitle
                      : l10n.accountUnconfirmedTitle,
                  message: confirmed
                      ? l10n.accountClosedBody
                      : l10n.accountUnconfirmedBody,
                ),
                const SizedBox(height: AppSpacing.lg),
                Semantics(
                  liveRegion: true,
                  container: true,
                  child: Text(
                    confirmed ? purgeText : l10n.accountUnconfirmedKept,
                    textAlign: TextAlign.center,
                    style: textTheme.titleSmall,
                  ),
                ),
                if (confirmed) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    l10n.accountClosedEmail,
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(
                      color: context.tokens.textMuted,
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.xl),
                AppButton.primary(
                  label: confirmed
                      ? l10n.accountClosedContinue
                      : l10n.accountUnconfirmedSignIn,
                  onPressed: () {
                    // "Please sign in again" would be the wrong thing to say here.
                    ref.read(sessionEndedNoticeProvider.notifier).clear();
                    ref.read(accountClosedNoticeProvider.notifier).dismiss();
                    context.go(AppRoutes.signIn);
                  },
                  expand: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
