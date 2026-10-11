import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/api/models/api_problem.dart';
import '../../checkin/application/schedule_controller.dart';
import '../../checkin/data/models/checkin_models.dart';
import '../../contacts/application/contacts_controller.dart';
import '../../home/application/home_controller.dart';
import '../../instructions/application/instructions_controller.dart';
import '../../instructions/data/instructions_repository.dart';
import '../data/plan_repository.dart';
import 'plan_controller.dart';
import 'plan_editor_draft.dart';

/// What the editor says about the last attempt to save, besides the fields themselves.
enum PlanEditorNoticeKind {
  /// The plan was changed somewhere else; the latest is loaded and the edits are kept.
  stale,

  /// A stage or a contact in the draft is not the person's any more (404).
  notFound,

  /// A stage that was taken out still shares instructions (409); it was put back.
  inUse,

  /// The tier's stage limit (403).
  limit,

  /// Any other failure: shown with the app's own words for it.
  failure,
}

/// One calm message above the editor.
@immutable
class PlanEditorNotice {
  const PlanEditorNotice(
    this.kind, {
    this.failure,
    this.instructionIds = const [],
  });

  final PlanEditorNoticeKind kind;

  /// The failure behind a [PlanEditorNoticeKind.failure] (or `limit`).
  final AppFailure? failure;

  /// The instructions the server named for [PlanEditorNoticeKind.inUse].
  final List<String> instructionIds;
}

/// What a save came to.
enum PlanEditorSaveResult {
  /// The server saved it and answered with the plan.
  saved,

  /// The plan the server has now is exactly what the person asked for (the answer to the
  /// save was lost, or the same change was made somewhere else).
  matchesServer,

  /// The person closed the password sheet: nothing was sent again and nothing changed.
  cancelled,

  /// Nothing was sent: the editor is not ready, busy or read-only.
  notSent,

  /// It was refused or did not arrive; the edits are all still here and [PlanEditorState]
  /// says why.
  failed,
}

/// The editor's whole state: the plan the draft was started from, the draft, and what the
/// last save attempt left behind.
@immutable
class PlanEditorState {
  const PlanEditorState({
    this.base,
    this.draft = const PlanEditorDraft(graceMinutes: 180, stages: []),
    this.saving = false,
    this.notice,
    this.lockedByServer = false,
    this.serverIssues = const [],
  });

  /// The plan the draft was started from; its version is the `If-Match` of a save. Null
  /// until the plan is loaded.
  final Plan? base;
  final PlanEditorDraft draft;
  final bool saving;
  final PlanEditorNotice? notice;

  /// The server answered 409 `incident_open`: an incident is open whatever this app had
  /// read before.
  final bool lockedByServer;

  /// What the server refused in the last save (field by field), until the next edit.
  final List<PlanIssue> serverIssues;

  bool get isReady => base != null;

  /// The draft differs from the plan it started from.
  bool get dirty {
    final plan = base;
    return plan != null && !draft.sameAs(plan);
  }

  PlanEditorState copyWith({
    Plan? base,
    PlanEditorDraft? draft,
    bool? saving,
    PlanEditorNotice? Function()? notice,
    bool? lockedByServer,
    List<PlanIssue>? serverIssues,
  }) => PlanEditorState(
    base: base ?? this.base,
    draft: draft ?? this.draft,
    saving: saving ?? this.saving,
    notice: notice == null ? this.notice : notice(),
    lockedByServer: lockedByServer ?? this.lockedByServer,
    serverIssues: serverIssues ?? this.serverIssues,
  );
}

/// Sends the save; used to put the password step around the call (`withReauth`). It
/// returns null when the person closed the sheet.
typedef PlanSaveGuard = Future<Plan?> Function(Future<Plan> Function() send);

final RegExp _stageField = RegExp(r'^stages\[(\d+)\]\.(\w+)$');

/// The plan editor (USER_FLOWS.md §10): the person's changes to the plan, kept apart from
/// the saved plan until the server confirms them.
///
/// * Nothing the screen shows as saved is saved until `PUT /plan` answered 200.
/// * The save carries the `If-Match` of the plan the draft was started from, so a plan
///   that was changed meanwhile is a 412 the person is told about; the same save made
///   again after the password sends the same header.
/// * Whatever fails, the edits stay (a stage the server refuses to remove goes back, a
///   contact that is gone is dropped from the stages, nothing else is touched).
/// * While an incident is open nothing can be edited or sent.
class PlanEditorController extends Notifier<PlanEditorState> {
  @override
  PlanEditorState build() {
    ref
      ..listen(planControllerProvider, (previous, next) {
        final plan = next.value;
        if (plan != null) {
          _onPlan(plan);
        }
      })
      ..listen(contactsControllerProvider, (previous, next) {
        final contacts = next.value;
        if (contacts == null || !state.isReady) {
          return;
        }
        // A contact that was removed is out of every stage on the server: the draft
        // must not name it again (that would be a 404).
        final live = {for (final contact in contacts) contact.id};
        final named = {
          ...state.draft.contactIds,
          for (final stage in state.draft.removed) ...stage.contactIds,
        };
        if (!named.every(live.contains)) {
          state = state.copyWith(draft: state.draft.keepingContacts(live));
        }
      })
      ..listen(scheduleControllerProvider, (previous, next) {
        // The incident that locked the plan is over.
        if (state.lockedByServer &&
            next.value != null &&
            next.value!.status != CheckInStatus.incidentOpen) {
          state = state.copyWith(lockedByServer: false);
        }
      });
    final plan = ref.read(planControllerProvider).value;
    return plan == null ? const PlanEditorState() : _fresh(plan);
  }

  PlanEditorState _fresh(Plan plan) =>
      PlanEditorState(base: plan, draft: PlanEditorDraft.fromPlan(plan));

  /// An incident is open: as the schedule or Home says, or as the server answered a
  /// save.
  bool get isLocked =>
      state.lockedByServer ||
      ref.read(scheduleControllerProvider).value?.status ==
          CheckInStatus.incidentOpen ||
      (ref.read(homeControllerProvider).value?.snapshot.hasIncident ?? false);

  void _onPlan(Plan plan) {
    final current = state;
    if (current.saving) {
      return;
    }
    final base = current.base;
    if (base == null) {
      state = _fresh(plan).copyWith(lockedByServer: current.lockedByServer);
      return;
    }
    if (plan.version == base.version) {
      // The same plan read again: the counts of shared instructions and the rules may
      // have moved (an instruction was changed, the tier changed).
      if (plan != base) {
        state = current.copyWith(
          base: plan,
          draft: current.draft.rebasedOn(plan),
        );
      }
      return;
    }
    // The plan was changed (another device, a contact removed, a stage added for an
    // instruction). Nothing of the person's is lost: an untouched draft follows it, one
    // with edits stays as it is and the save meets a 412 that says so.
    if (!current.dirty) {
      state = _fresh(plan).copyWith(lockedByServer: current.lockedByServer);
    }
  }

  void _edit(PlanEditorDraft Function(PlanEditorDraft draft) change) {
    final current = state;
    if (!current.isReady || current.saving || isLocked) {
      return;
    }
    state = current.copyWith(
      draft: change(current.draft),
      serverIssues: const [],
    );
  }

  /// Chooses the grace period (the first stage runs when it ends).
  void setGrace(int minutes) => _edit((d) => d.withGrace(minutes));

  /// Chooses another time for the stage with [key].
  void setStageTime(String key, int minutes) =>
      _edit((d) => d.withStageOffset(key, minutes));

  /// Chooses who is told at the stage with [key].
  void setStageContacts(String key, List<String> contactIds) =>
      _edit((d) => d.withContacts(key, contactIds));

  /// Adds a stage at [minutes] that tells nobody yet.
  void addStage(int minutes) => _edit((d) => d.addStage(minutes));

  /// Takes the stage with [key] out of the draft.
  void removeStage(String key) => _edit((d) => d.removeStage(key));

  /// Starts again from the plan the server has: every edit is dropped.
  void discard() {
    final plan = state.base;
    if (plan == null || state.saving) {
      return;
    }
    state = state.copyWith(
      draft: PlanEditorDraft.fromPlan(plan),
      notice: () => null,
      serverIssues: const [],
    );
  }

  /// Hides the message above the editor.
  void dismissNotice() {
    if (state.notice != null) {
      state = state.copyWith(notice: () => null);
    }
  }

  /// Saves the draft: `PUT /plan` with the `If-Match` of the plan it was started from.
  ///
  /// [guard] wraps the call so the screen can ask for the password when the server
  /// answers 403 `reauth_required` and send the same request again.
  Future<PlanEditorSaveResult> save({PlanSaveGuard? guard}) async {
    final before = state;
    final base = before.base;
    if (base == null || before.saving || isLocked) {
      return PlanEditorSaveResult.notSent;
    }
    // Built once: a second send (after the password) is this same body.
    final body = before.draft.toPlanDraft();
    final keys = [for (final stage in before.draft.stages) stage.key];
    state = before.copyWith(
      saving: true,
      notice: () => null,
      serverIssues: const [],
    );
    final controller = ref.read(planControllerProvider.notifier);
    Future<Plan> send() => controller.save(body, basedOn: base);
    try {
      final saved = guard == null ? await send() : await guard(send);
      // The person may have left meanwhile (the editor is gone): the plan controller
      // already holds what the server answered.
      if (!ref.mounted) {
        return saved == null
            ? PlanEditorSaveResult.cancelled
            : PlanEditorSaveResult.saved;
      }
      if (saved == null) {
        state = state.copyWith(saving: false);
        return PlanEditorSaveResult.cancelled;
      }
      state = _fresh(saved);
      return PlanEditorSaveResult.saved;
    } on Object catch (error) {
      if (!ref.mounted) {
        return PlanEditorSaveResult.failed;
      }
      return _failed(toAppFailure(error), before: before, keys: keys);
    }
  }

  PlanEditorSaveResult _failed(
    AppFailure failure, {
    required PlanEditorState before,
    required List<String> keys,
  }) {
    final base = before.base!;
    final stopped = before.copyWith(saving: false, notice: () => null);
    switch (failure) {
      case ConflictFailure(
        code: 'precondition_failed' || 'precondition_required',
      ):
        // The plan controller read the latest plan before it rethrew.
        final latest = ref.read(planControllerProvider).value;
        if (latest == null || latest.version == base.version) {
          // Not read (offline): the same save would meet the same answer.
          state = stopped.copyWith(
            notice: () => PlanEditorNotice(
              PlanEditorNoticeKind.failure,
              failure: failure,
            ),
          );
          return PlanEditorSaveResult.failed;
        }
        final rebased = before.draft.rebasedOn(latest);
        if (rebased.sameAs(latest)) {
          state = _fresh(latest);
          return PlanEditorSaveResult.matchesServer;
        }
        state = stopped.copyWith(
          base: latest,
          draft: rebased,
          notice: () => const PlanEditorNotice(PlanEditorNoticeKind.stale),
        );
      case ConflictFailure(code: 'incident_open'):
        state = stopped.copyWith(lockedByServer: true);
        // Home and the schedule screen learn the same thing.
        unawaited(ref.read(scheduleControllerProvider.notifier).reload());
      case StageInUseFailure(:final instructionIds):
        state = stopped.copyWith(
          draft: _putBack(before.draft, instructionIds),
          notice: () => PlanEditorNotice(
            PlanEditorNoticeKind.inUse,
            instructionIds: instructionIds,
          ),
        );
        // The counts on the stages (and the list of instructions) may be out of date.
        unawaited(ref.read(planControllerProvider.notifier).reload());
        unawaited(ref.read(instructionsControllerProvider.notifier).reload());
      case PlanLimitFailure():
        state = stopped.copyWith(
          notice: () =>
              PlanEditorNotice(PlanEditorNoticeKind.limit, failure: failure),
        );
        // The tier's rules may have changed: read them again.
        unawaited(ref.read(planControllerProvider.notifier).reload());
      case NotFoundFailure():
        // The controller read the contacts and the plan again before it rethrew.
        final latest = ref.read(planControllerProvider).value;
        final contacts = ref.read(contactsControllerProvider).value;
        var draft = before.draft;
        if (latest != null) {
          draft = draft.rebasedOn(latest);
        }
        if (contacts != null) {
          draft = draft.keepingContacts({for (final c in contacts) c.id});
        }
        state = stopped.copyWith(
          base: latest ?? base,
          draft: draft,
          notice: () => const PlanEditorNotice(PlanEditorNoticeKind.notFound),
        );
      case ValidationFailure(:final fieldErrors):
        final issues = _issuesOf(fieldErrors, keys);
        state = issues.isEmpty
            ? stopped.copyWith(
                notice: () => PlanEditorNotice(
                  PlanEditorNoticeKind.failure,
                  failure: failure,
                ),
              )
            : stopped.copyWith(serverIssues: issues);
      default:
        state = stopped.copyWith(
          notice: () =>
              PlanEditorNotice(PlanEditorNoticeKind.failure, failure: failure),
        );
    }
    return PlanEditorSaveResult.failed;
  }

  /// Puts back the removed stages that hold the instructions the server named. When the
  /// list of instructions cannot say which stage that is, every removed stage goes back:
  /// putting one back never weakens the plan.
  PlanEditorDraft _putBack(PlanEditorDraft draft, List<String> instructionIds) {
    final summaries =
        ref.read(instructionsControllerProvider).value ??
        const <InstructionSummary>[];
    final stageIds = <String>{
      for (final summary in summaries)
        if (instructionIds.contains(summary.id))
          for (final recipient in summary.recipients) recipient.releaseStageId,
    };
    var next = draft;
    for (final stage in draft.removed) {
      if (stageIds.isEmpty || stageIds.contains(stage.id)) {
        next = next.restoreStage(stage.key);
      }
    }
    return next;
  }

  /// The server's field errors as issues on the stages that were sent ([keys] in the
  /// order of the request).
  List<PlanIssue> _issuesOf(List<ApiFieldError> errors, List<String> keys) {
    final issues = <PlanIssue>[];
    for (final error in errors) {
      if (error.field == 'grace_minutes') {
        issues.add(
          PlanIssue(switch (error.code) {
            'out_of_range' => PlanIssueKind.graceOutOfRange,
            'not_a_preset' => PlanIssueKind.graceNotAllowed,
            _ => PlanIssueKind.other,
          }),
        );
      } else if (error.field == 'stages') {
        issues.add(
          PlanIssue(
            error.code == 'too_short'
                ? PlanIssueKind.noStage
                : PlanIssueKind.other,
          ),
        );
      } else if (_stageField.firstMatch(error.field) case final match?) {
        final index = int.parse(match.group(1)!);
        if (index >= keys.length) {
          continue;
        }
        final kind = match.group(2) == 'offset_minutes'
            ? switch (error.code) {
                'too_close' => PlanIssueKind.stageTooClose,
                'too_large' => PlanIssueKind.stageTooLarge,
                'not_a_preset' => PlanIssueKind.stageNotAllowed,
                'release_too_early' => PlanIssueKind.stageReleaseTooEarly,
                _ => PlanIssueKind.other,
              }
            : PlanIssueKind.other;
        issues.add(PlanIssue(kind, stageKey: keys[index]));
      }
    }
    return issues;
  }
}

final planEditorControllerProvider =
    NotifierProvider.autoDispose<PlanEditorController, PlanEditorState>(
      PlanEditorController.new,
    );

/// The app's mirror of the rules for the plan being edited: the tier's rules of the plan
/// the draft started from, the times that plan already uses, and the stages the
/// instruction list says hold something. Null until the plan is there.
final planEditorRulesProvider = Provider.autoDispose<PlanEditorRules?>((ref) {
  final base = ref.watch(planEditorControllerProvider.select((s) => s.base));
  if (base == null) {
    return null;
  }
  final instructions =
      ref.watch(instructionsControllerProvider).value ??
      const <InstructionSummary>[];
  return PlanEditorRules(
    rules: base.rules,
    keptOffsets: {for (final stage in base.stages) stage.offsetMinutes},
    holdsInstructions: {
      for (final summary in instructions)
        for (final recipient in summary.recipients) recipient.releaseStageId,
    },
  );
});

/// Whether the editor is read-only because an incident is open. Any one of the schedule,
/// Home's aggregate and the server's own answer to a save is enough: the plan cannot
/// change while a check-in is overdue (API_SPEC.md §8), and none of them is trusted to
/// say "all clear" alone.
final planEditorLockedProvider = Provider.autoDispose<bool>((ref) {
  final server = ref.watch(
    planEditorControllerProvider.select((s) => s.lockedByServer),
  );
  final status = ref.watch(
    scheduleControllerProvider.select((s) => s.value?.status),
  );
  final home = ref.watch(
    homeControllerProvider.select(
      (s) => s.value?.snapshot.hasIncident ?? false,
    ),
  );
  return server || status == CheckInStatus.incidentOpen || home;
});
