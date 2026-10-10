import '../../contacts/data/contacts_repository.dart';
import 'models/plan_models.dart';

export 'models/plan_models.dart';

/// The preset the plan step offers (USER_FLOWS.md §3 step 6).
abstract final class PlanPresets {
  static const int standardGraceMinutes = 180;

  /// The grace choices the plan step can show, shortest first. What a person is
  /// really offered is what the server's rules allow of these ([graceChoices]).
  static const List<int> graceChoicesMinutes = [60, 120, 180, 360, 720, 1440];

  /// The grace choices to offer under [rules]: the ones above that the tier may choose
  /// (a free account may not use 1 or 2 hours: the server refuses values that are not
  /// presets). Without rules (not loaded) only the presets every tier has. The value
  /// already saved ([current]) is always offered, so what is on screen is never absent
  /// from the choices.
  static List<int> graceChoices(PlanRules? rules, {int? current}) {
    final choices = <int>{
      for (final minutes in graceChoicesMinutes)
        if (rules == null
            ? minutes >= standardGraceMinutes
            : rules.allowsGrace(minutes))
          minutes,
      ?current,
    };
    return choices.toList()..sort();
  }

  /// The Standard plan for [contacts] with [graceMinutes]: one stage, at the end of the
  /// grace period, that notifies every contact that is switched on.
  ///
  /// When the [current] plan already has stages, only its first stage is replaced (it
  /// keeps its id, so whatever is assigned to it stays) and the later ones are kept as
  /// they are: choosing the preset again never deletes something the person set up
  /// elsewhere.
  static PlanDraft standard(
    List<TrustedContact> contacts, {
    Plan? current,
    int? graceMinutes,
  }) {
    final grace = graceMinutes ?? current?.graceMinutes ?? standardGraceMinutes;
    final first = PlanStageDraft(
      id: current != null && current.stages.isNotEmpty
          ? current.stages.first.id
          : null,
      offsetMinutes: grace,
      contactIds: [
        for (final contact in contacts)
          if (contact.isActive) contact.id,
      ],
    );
    final later = current == null
        ? const <PlanStageDraft>[]
        : current.toDraft().stages.skip(1);
    return PlanDraft(graceMinutes: grace, stages: [first, ...later]);
  }
}

/// The escalation plan (API_SPEC.md §8).
///
/// Every method throws an `AppFailure` on error (see `toAppFailure`). The server is
/// authoritative: it validates the plan (stage 1 at the end of the grace period,
/// ordering and gaps, the tier's presets and stage limit) and the app never trusts its
/// own copy of those rules over the answer.
abstract interface class PlanRepository {
  /// `GET /v1/plan`. Always answers: an account that never made a plan has no stages.
  Future<Plan> get();

  /// `PUT /v1/plan` with `If-Match: [ifMatch]` (the plan's `"plan-<version>"`),
  /// replacing the plan. 412 `precondition_failed` means it was changed meanwhile; 409
  /// `incident_open` means an incident is open; 422 `validation_failed` lists the
  /// fields; 403 `plan_limit_reached` means too many stages for the tier; 404 means a
  /// contact (or stage) is not the person's.
  Future<Plan> save(PlanDraft draft, {required String ifMatch});
}
