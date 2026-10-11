import 'models/incident_models.dart';

export 'models/incident_models.dart';

/// Incidents: the history, one incident and I'M SAFE (API_SPEC.md §9).
///
/// The open incident itself arrives inside the Home aggregate (`GET /v1/home`), which
/// uses the same object; this repository reads the rest. Every method throws an
/// `AppFailure` on error.
abstract interface class IncidentsRepository {
  /// `GET /v1/incidents?limit=&cursor=`: newest first.
  Future<IncidentPage> list({int limit = 20, String? cursor});

  /// `GET /v1/incidents/{id}`. A stranger's id is a 404, exactly like a missing one.
  Future<Incident> get(String id);

  /// `POST /v1/incidents/{id}/safe` (needs a password re-auth within 5 minutes).
  ///
  /// The [idempotencyKey] belongs to one confirmation and is reused for every retry of
  /// it, so the server stops the incident and tells the contacts once. Success is only
  /// a 200: the caller must not show "marked safe" before this returns.
  Future<SafeResult> markSafe(
    String incidentId, {
    required String idempotencyKey,
  });
}
