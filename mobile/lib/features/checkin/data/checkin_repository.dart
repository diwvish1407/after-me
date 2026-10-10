import 'models/checkin_models.dart';

export 'models/checkin_models.dart';

/// Check-ins: the I'M OK tap and the history (API_SPEC.md §6.2).
///
/// Every method throws an `AppFailure` on error.
abstract interface class CheckInRepository {
  /// `POST /v1/checkins`. The [idempotencyKey] belongs to one tap of the button and is
  /// reused for every retry of it, also after an app restart, so the server records
  /// the tap once. [clientReportedAt] is informational only: the server stamps the
  /// check-in with its own clock and never trusts this value.
  ///
  /// Success is only a 200: the caller must not show "checked in" before this returns.
  Future<CheckInResult> checkIn({
    required String idempotencyKey,
    DateTime? clientReportedAt,
  });

  /// `GET /v1/checkins?limit=&cursor=`: newest first.
  Future<CheckInHistoryPage> history({int limit = 20, String? cursor});
}
