import 'dart:async';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';

/// The plan "server" for tests: `GET` and `PUT /v1/plan` behaving like the contract in
/// `docs/contracts/phase5` and the backend's rules (ETag / If-Match, stage 1 at the end
/// of the grace period, ordering and gaps, the free tier's presets (and the times a
/// downgraded account already has) and stage limit, 404
/// for a contact that is not yours, 409 during an incident, and the step-up: a plan that
/// really changes while check-ins are on needs a fresh password, 403 `reauth_required`,
/// asked only after everything else was checked). It implements [PlanRepository], so
/// the app's real controllers and screens run against it. The app itself talks to the
/// real API; this lives in `test/`.
class FakePlanServer implements PlanRepository {
  FakePlanServer({
    required this.contacts,
    required this.tier,
    this.incidentOpen,
    this.scheduleActive,
    this.reauthenticated,
    this.releaseCount,
    this.instructionIdsAt,
    this.onCall,
  });

  /// The person's contacts (every id a stage names must be one of them).
  final List<TrustedContact> Function() contacts;

  /// `free` or `premium`: the free tier has presets only and two stages.
  final String Function() tier;

  /// Whether an incident is open (a change is then 409 `incident_open`).
  final bool Function()? incidentOpen;

  /// Whether the check-in schedule is on. While it is, a save that changes the plan
  /// needs [reauthenticated] (SECURITY.md §7); while it is off (onboarding) nothing does.
  final bool Function()? scheduleActive;

  /// Whether the session entered its password recently (the same switch the check-in
  /// server uses for deactivating). Null counts as yes.
  final bool Function()? reauthenticated;

  /// How many active instructions are released at a stage (`stages[].release_count`).
  final int Function(String stageId)? releaseCount;

  /// The instructions assigned to a stage, active or not: a stage that holds any cannot
  /// be removed (409 `stage_in_use`) nor moved earlier than 24 hours.
  final List<String> Function(String stageId)? instructionIdsAt;

  /// Told the name of every call (`plan.get`, `plan.save`), so a test can see the order of
  /// calls across several "servers".
  final void Function(String call)? onCall;

  // --- the plan row -------------------------------------------------------------------
  String id = '00000000-0000-4000-8000-0000000000a1';
  int version = 1;
  int graceMinutes = 180;
  final List<PlanStage> _stages = [];

  /// The stages as saved.
  List<PlanStage> get stages => List.unmodifiable(_stages);

  /// Some stage notifies at least one of [active].
  bool notifiesAnyOf(Set<String> active) =>
      _stages.any((s) => s.contactIds.any(active.contains));

  // --- scripting and inspection -------------------------------------------------------
  /// Names of the calls received, in order (`get`, `save`).
  final List<String> calls = [];

  /// Every `If-Match` that reached [save].
  final List<String> ifMatches = [];

  /// Every body that reached [save], as sent.
  final List<Map<String, Object?>> saved = [];

  /// Failures thrown by the next calls to the named method, consumed in order.
  final Map<String, List<AppFailure>> failures = {};

  /// Waits before answering (to show the loading state).
  Future<void>? gate;

  int _ids = 0;

  void _enter(String method) {
    calls.add(method);
    onCall?.call('plan.$method');
    final queue = failures[method];
    if (queue != null && queue.isNotEmpty) {
      throw queue.removeAt(0);
    }
  }

  bool get _free => tier() == 'free';

  PlanRules get rules => PlanRules(
    graceMin: 60,
    graceMax: 4320,
    stageGapMin: 30,
    offsetMax: 43200,
    releaseOffsetMin: 1440,
    maxStages: _free ? 2 : 10,
    customOffsets: !_free,
    presets: const [180, 360, 720, 1440, 2880, 4320],
  );

  Plan _plan() => Plan(
    id: id,
    version: version,
    graceMinutes: graceMinutes,
    stages: [
      for (final s in _stages)
        s.copyWith(releaseCount: releaseCount?.call(s.id) ?? s.releaseCount),
    ],
    rules: rules,
    etag: '"plan-$version"',
  );

  /// Makes the plan look like it does after the person saved [draft] on another
  /// device (the version goes up).
  void seed(PlanDraft draft) {
    _apply(draft);
    version++;
  }

  /// A plan with one stage at [offsetMinutes] notifying [contactIds].
  void seedStandard(List<String> contactIds, {int offsetMinutes = 180}) => seed(
    PlanDraft(
      graceMinutes: offsetMinutes,
      stages: [
        PlanStageDraft(offsetMinutes: offsetMinutes, contactIds: contactIds),
      ],
    ),
  );

  /// The server removes a deleted contact from every stage (the plan's version does
  /// not change).
  void forgetContact(String contactId) {
    for (var i = 0; i < _stages.length; i++) {
      _stages[i] = _stages[i].copyWith(
        contactIds: [
          for (final id in _stages[i].contactIds)
            if (id != contactId) id,
        ],
      );
    }
  }

  @override
  Future<Plan> get() async {
    _enter('get');
    await gate;
    return _plan();
  }

  ValidationFailure _invalid(List<ApiFieldError> errors) => ValidationFailure(
    code: 'validation_failed',
    fieldErrors: errors,
    problem: ApiProblem(status: 422, code: 'validation_failed', errors: errors),
  );

  @override
  Future<Plan> save(PlanDraft draft, {required String ifMatch}) async {
    _enter('save');
    await gate;
    ifMatches.add(ifMatch);
    saved.add(draft.toJson());
    if (ifMatch.isEmpty) {
      throw const ConflictFailure(code: 'precondition_required');
    }
    if (ifMatch != '"plan-$version"') {
      throw const ConflictFailure(code: 'precondition_failed');
    }
    if (incidentOpen?.call() ?? false) {
      throw const ConflictFailure(code: 'incident_open');
    }
    // Ownership first: a stage or contact that is not yours is a 404.
    final live = {for (final c in contacts()) c.id};
    final known = {for (final s in _stages) s.id};
    for (final stage in draft.stages) {
      if (stage.id != null && !known.contains(stage.id)) {
        throw const NotFoundFailure();
      }
      if (stage.contactIds.any((id) => !live.contains(id))) {
        throw const NotFoundFailure();
      }
    }
    final errors = _validate(draft);
    if (errors.isNotEmpty) {
      throw _invalid(errors);
    }
    final allowed = rules.maxStages > _stages.length
        ? rules.maxStages
        : _stages.length;
    if (draft.stages.length > allowed) {
      throw PlanLimitFailure(
        limit: rules.maxStages,
        current: draft.stages.length,
        resource: 'stages',
      );
    }
    // A stage that still holds an instruction cannot be removed (after the tier's
    // limit, before the password, like the server).
    final kept = {
      for (final s in draft.stages)
        if (s.id != null) s.id,
    };
    final inUse = [
      for (final stage in _stages)
        if (!kept.contains(stage.id)) ...?instructionIdsAt?.call(stage.id),
    ];
    if (inUse.isNotEmpty) {
      throw StageInUseFailure(
        instructionIds: inUse,
        problem: ApiProblem(
          status: 409,
          code: 'stage_in_use',
          instructionIds: inUse,
        ),
      );
    }
    final unchanged =
        graceMinutes == draft.graceMinutes &&
        _stages.length == draft.stages.length &&
        [
          for (var i = 0; i < _stages.length; i++)
            _stages[i].id == draft.stages[i].id &&
                _stages[i].offsetMinutes == draft.stages[i].offsetMinutes &&
                (_stages[i].contactIds.toList()..sort()).join(',') ==
                    (draft.stages[i].contactIds.toList()..sort()).join(','),
        ].every((same) => same);
    if (!unchanged) {
      // Last, like the server: a stranger's id (404), a field that is wrong (422) or a
      // stale version (412) is answered before the password is asked for.
      if ((scheduleActive?.call() ?? false) &&
          !(reauthenticated?.call() ?? true)) {
        throw const ForbiddenFailure(code: 'reauth_required');
      }
      _apply(draft);
      version++;
    }
    return _plan();
  }

  void _apply(PlanDraft draft) {
    final existing = {for (final s in _stages) s.id: s};
    graceMinutes = draft.graceMinutes;
    _stages
      ..clear()
      ..addAll([
        for (var i = 0; i < draft.stages.length; i++)
          PlanStage(
            id: draft.stages[i].id ?? 'stage-${++_ids}',
            position: i + 1,
            offsetMinutes: draft.stages[i].offsetMinutes,
            contactIds: (draft.stages[i].contactIds.toSet().toList()..sort()),
            releaseCount: existing[draft.stages[i].id]?.releaseCount ?? 0,
          ),
      ]);
  }

  List<ApiFieldError> _validate(PlanDraft draft) {
    final r = rules;
    final errors = <ApiFieldError>[];
    // A downgraded account keeps the times its plan already has (PRD §10): they stay
    // allowed, only new custom values are refused.
    bool allowed(int value) =>
        r.customOffsets ||
        r.presets.contains(value) ||
        _stages.any((s) => s.offsetMinutes == value);
    ApiFieldError error(String field, String code, String message) =>
        ApiFieldError(field: field, code: code, message: message);

    if (draft.graceMinutes < r.graceMin || draft.graceMinutes > r.graceMax) {
      errors.add(
        error('grace_minutes', 'out_of_range', 'The grace period is out.'),
      );
    } else if (!allowed(draft.graceMinutes)) {
      errors.add(
        error('grace_minutes', 'not_a_preset', 'Choose a suggested period.'),
      );
    }
    if (draft.stages.isEmpty) {
      errors.add(error('stages', 'too_short', 'Add at least one stage.'));
      return errors;
    }
    int? previous;
    for (var i = 0; i < draft.stages.length; i++) {
      final stage = draft.stages[i];
      final field = 'stages[$i].offset_minutes';
      final offset = stage.offsetMinutes;
      if (i == 0 && offset != draft.graceMinutes) {
        errors.add(
          error(field, 'must_equal_grace', 'The first stage ends the grace.'),
        );
      }
      if (offset > r.offsetMax) {
        errors.add(error(field, 'too_large', 'That is too late.'));
      } else if (i > 0 &&
          previous != null &&
          offset < previous + r.stageGapMin) {
        errors.add(error(field, 'too_close', 'Stages must be further apart.'));
      } else if (i > 0 && !allowed(offset)) {
        errors.add(error(field, 'not_a_preset', 'Choose a suggested time.'));
      }
      if (stage.id != null &&
          offset < r.releaseOffsetMin &&
          (instructionIdsAt?.call(stage.id!).isNotEmpty ?? false)) {
        errors.add(
          error(field, 'release_too_early', 'It shares instructions.'),
        );
      }
      if (stage.contactIds.toSet().length != stage.contactIds.length) {
        errors.add(
          error(
            'stages[$i].notify_contact_ids',
            'duplicate',
            'A contact is listed twice.',
          ),
        );
      }
      previous = offset;
    }
    return errors;
  }
}
