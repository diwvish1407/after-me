import 'models/home_models.dart';

export 'models/home_models.dart';

/// The Home aggregate (API_SPEC.md §5).
///
/// Throws an `AppFailure` on error.
abstract interface class HomeRepository {
  /// `GET /v1/home`.
  Future<HomeSnapshot> load();
}
