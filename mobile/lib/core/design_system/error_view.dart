import 'package:material_ui/material_ui.dart';

import '../../app/theme/dimens.dart';
import '../../app/theme/tokens.dart';
import '../../l10n/gen/app_localizations.dart';
import '../api/failures/app_failure.dart';
import 'app_button.dart';

/// The calm, user-facing message for a failure (USER_FLOWS.md §14). Server-provided
/// `detail` text is never shown in its place.
String failureMessage(
  AppLocalizations l10n,
  AppFailure failure,
) => switch (failure) {
  NetworkFailure() => l10n.errorNetwork,
  UnauthorizedFailure(:final code) => switch (code) {
    'invalid_credentials' => l10n.errorInvalidCredentials,
    // session_revoked, unauthenticated, and a token_expired that survived its
    // single refresh retry: the safe reading is that signing in again is needed.
    _ => l10n.errorSessionExpired,
  },
  // The tier's stage limit (a 403 plan_limit_reached on the escalation plan); the
  // contacts limit has its own sheet and the default wording.
  PlanLimitFailure(resource: 'stages') => l10n.errorPlanLimitStages,
  // The instructions limit has its own sheet; this is the line where there is none.
  PlanLimitFailure(resource: 'instructions') => l10n.errorPlanLimitInstructions,
  ForbiddenFailure(:final code) => switch (code) {
    'reauth_required' => l10n.errorReauthRequired,
    'email_unverified' => l10n.errorEmailUnverified,
    'plan_limit_reached' => l10n.errorPlanLimitReached,
    _ => l10n.errorForbidden,
  },
  NotFoundFailure() => l10n.errorNotFound,
  ConflictFailure(:final code) => switch (code) {
    'safe_required' => l10n.errorSafeRequired,
    'incident_open' => l10n.errorIncidentOpen,
    'precondition_failed' || 'precondition_required' => l10n.errorStaleData,
    'contact_duplicate' => l10n.errorContactDuplicate,
    'stage_in_use' => l10n.errorStageInUse,
    'invalid_state' => l10n.errorInvalidState,
    'activation_requirements_unmet' => l10n.errorActivationRequirements,
    _ => l10n.errorConflict,
  },
  ValidationFailure(:final code) => switch (code) {
    'invalid_code' => l10n.errorInvalidCode,
    'cannot_be_own_email' => l10n.errorOwnEmail,
    _ => l10n.errorValidation,
  },
  RateLimitedFailure(:final retryAfter) =>
    retryAfter == null || retryAfter < const Duration(minutes: 1)
        ? l10n.errorRateLimited
        : retryAfter <= const Duration(hours: 1)
        ? l10n.errorRateLimitedMinutes((retryAfter.inSeconds / 60).ceil())
        : retryAfter <= const Duration(days: 1)
        ? l10n.errorRateLimitedHours((retryAfter.inMinutes / 60).ceil())
        : l10n.errorRateLimitedDays((retryAfter.inHours / 24).ceil()),
  UpgradeRequiredFailure() => l10n.errorUpgradeRequired,
  ServerFailure() => l10n.errorServer,
  UnknownFailure() => l10n.errorUnknown,
};

/// Shows a failure calmly: an icon, the message from [failureMessage], and a retry
/// button for transient failures when [onRetry] is provided.
class ErrorView extends StatelessWidget {
  const ErrorView({required this.failure, this.onRetry, super.key});

  final AppFailure failure;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final icon = switch (failure) {
      NetworkFailure() => Icons.cloud_off_outlined,
      UpgradeRequiredFailure() => Icons.system_update_outlined,
      RateLimitedFailure() => Icons.hourglass_empty_rounded,
      UnauthorizedFailure() => Icons.lock_outline_rounded,
      _ => Icons.info_outline_rounded,
    };
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: t.textMuted),
          const SizedBox(height: AppSpacing.md),
          Semantics(
            container: true,
            liveRegion: true,
            child: Text(
              failureMessage(l10n, failure),
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium,
            ),
          ),
          if (onRetry != null && failure.isTransient) ...[
            const SizedBox(height: AppSpacing.lg),
            AppButton.secondary(label: l10n.retry, onPressed: onRetry),
          ],
        ],
      ),
    );
  }
}
