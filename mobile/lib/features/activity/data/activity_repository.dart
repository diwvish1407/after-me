import 'models/activity_models.dart';

export 'models/activity_models.dart';

/// The Activity feed (API_SPEC.md §11).
///
/// Throws an `AppFailure` on error.
abstract interface class ActivityRepository {
  /// `GET /v1/activity?limit=&cursor=`: newest first. A [cursor] the server did not
  /// issue is a 422.
  Future<ActivityPage> list({int limit = 20, String? cursor});
}
