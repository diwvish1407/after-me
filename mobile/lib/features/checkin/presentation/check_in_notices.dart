import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/design_system/design_system.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/checkin_controller.dart';

/// What an I'M OK that is not recorded says, in the same words on every screen that
/// offers I'M OK (Home and the incident timeline): the tap is not confirmed, was refused,
/// or was too old to count. Nothing here ever says that a check-in was recorded.

/// The sentence under "Not received yet": when the person tapped, how long a rate limit
/// lasts, or that signing in is needed. [deviceNow] is the phone's clock (a rate limit
/// is measured on it).
String checkInPendingBody(
  BuildContext context,
  CheckInState checkIn, {
  required DateTime deviceNow,
  String? timezone,
}) {
  final l10n = AppLocalizations.of(context);
  switch (checkIn.phase) {
    case CheckInPhase.rateLimited:
      final retryAt = checkIn.retryAt;
      final wait = retryAt == null
          ? Duration.zero
          : retryAt.difference(deviceNow);
      return l10n.homeRateLimitedBody(formatUntil(l10n, wait));
    case CheckInPhase.signInRequired:
      return l10n.homeSignInRequiredBody;
    case _:
      final tapped = checkIn.tappedAt;
      return tapped == null
          ? l10n.homePendingBody('')
          : l10n.homePendingBody(
              formatClockTime(context, tapped, timezone: timezone),
            );
  }
}

/// "Your earlier check-in wasn't received": the tap was too old to be sent and was
/// dropped. Read out when it appears; "Got it" dismisses it, and so does a new tap.
Widget expiredCheckInNotice(
  BuildContext context,
  WidgetRef ref,
  CheckInState checkIn, {
  required DateTime now,
  String? timezone,
}) {
  final l10n = AppLocalizations.of(context);
  return Semantics(
    liveRegion: true,
    container: true,
    child: StatusBanner(
      kind: StatusBannerKind.attention,
      title: l10n.homeExpiredTitle,
      message: l10n.homeExpiredBody(
        formatSpokenDayTime(
          context,
          l10n,
          checkIn.tappedAt!,
          now: now,
          timezone: timezone,
        ),
      ),
      action: AppButton.text(
        label: l10n.homeExpiredDismiss,
        onPressed: ref
            .read(checkInControllerProvider.notifier)
            .dismissExpiredNotice,
      ),
    ),
  );
}

/// What an unconfirmed or refused I'M OK says while an incident is open, above the
/// headline. Null when the tap is idle, in its first attempt, recorded (the incident is
/// then over) or answered with `safe_required` (the incident headline and I'M SAFE say
/// that).
Widget? incidentCheckInNotice(
  BuildContext context,
  WidgetRef ref,
  CheckInState checkIn, {
  required DateTime now,
  required DateTime deviceNow,
  String? timezone,
}) {
  final l10n = AppLocalizations.of(context);
  if (checkIn.phase == CheckInPhase.expired) {
    return expiredCheckInNotice(
      context,
      ref,
      checkIn,
      now: now,
      timezone: timezone,
    );
  }
  String pending() => checkInPendingBody(
    context,
    checkIn,
    deviceNow: deviceNow,
    timezone: timezone,
  );
  final (String title, String? body)? banner = switch (checkIn.phase) {
    CheckInPhase.pending ||
    CheckInPhase.rateLimited ||
    CheckInPhase.signInRequired => (l10n.homePendingTitle, pending()),
    CheckInPhase.sending when checkIn.retrying => (
      l10n.homePendingTitle,
      pending(),
    ),
    CheckInPhase.failed => (
      l10n.homeFailedTitle,
      failureMessage(l10n, checkIn.failure!),
    ),
    _ => null,
  };
  if (banner == null) {
    return null;
  }
  return Semantics(
    liveRegion: true,
    container: true,
    child: StatusBanner(
      kind: StatusBannerKind.attention,
      title: banner.$1,
      message: banner.$2 ?? '',
    ),
  );
}
