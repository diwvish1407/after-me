import 'models/checkin_models.dart';

export 'models/checkin_models.dart';

/// The check-in schedule and its on/off switch (API_SPEC.md §6.1).
///
/// Every method throws an `AppFailure` on error (see `toAppFailure`). The server is
/// authoritative: it computes every deadline, and the app never sends or trusts times.
abstract interface class ScheduleRepository {
  /// `GET /v1/checkin/schedule`. Always answers: a schedule that was never changed
  /// carries the defaults and `status: inactive`.
  Future<ScheduleSnapshot> get();

  /// `PUT /v1/checkin/schedule` with `If-Match: [ifMatch]` (the snapshot's `ETag`).
  /// 412 `precondition_failed` means someone changed it meanwhile; 409
  /// `incident_open` means an incident is open. While check-ins are on, the server
  /// restarts the clock from now.
  Future<ScheduleSnapshot> save(
    CheckInSchedule schedule, {
    required String ifMatch,
  });

  /// `POST /v1/checkin/activate`. 409 `activation_requirements_unmet` lists what is
  /// missing (`ActivationRequirementsFailure`).
  Future<ScheduleSnapshot> activate();

  /// `POST /v1/checkin/deactivate`. Needs a recent re-authentication (403
  /// `reauth_required`).
  Future<ScheduleSnapshot> deactivate();
}
