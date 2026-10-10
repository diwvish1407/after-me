import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../contacts/application/contacts_controller.dart';
import '../../contacts/data/contacts_repository.dart';
import '../../plan/application/plan_controller.dart';
import '../../plan/data/plan_repository.dart';
import '../data/instructions_repository.dart';
import 'release_options.dart';

/// Newest change first, like the server orders them (`updated_at` descending); one with
/// no time comes last, and ties keep their order.
List<InstructionSummary> sortInstructions(Iterable<InstructionSummary> items) {
  final indexed = items.toList().asMap().entries.toList()
    ..sort((a, b) {
      final aTime = a.value.updatedAt;
      final bTime = b.value.updatedAt;
      if (aTime == null && bTime != null) {
        return 1;
      }
      if (aTime != null && bTime == null) {
        return -1;
      }
      if (aTime != null && bTime != null) {
        final byTime = bTime.compareTo(aTime);
        if (byTime != 0) {
          return byTime;
        }
      }
      return a.key.compareTo(b.key);
    });
  return [for (final entry in indexed) entry.value];
}

/// The plan got the stage(s) a chosen time needed, but the instruction itself could not
/// be saved afterwards ([failure] says why). The stage stays, which is harmless: the next
/// try finds it and uses it, as it does any stage the plan has.
class StageAddedButNotSaved implements Exception {
  const StageAddedButNotSaved(this.failure);

  final AppFailure failure;

  @override
  String toString() => 'StageAddedButNotSaved(${failure.runtimeType})';
}

/// The signed-in person's instructions (`GET /instructions`) and every change to them.
///
/// The list holds **summaries only**: a body is never part of it and never kept here.
/// The list is replaced only with what the server confirmed: an instruction appears
/// after a successful create, changes after a successful update and disappears after a
/// successful delete. Every method throws an `AppFailure` on error.
///
/// The recipients carry the contacts' names and the plan's stage positions, so the list
/// is read again when a contact is removed or renamed and when the plan changes (the
/// same way [PlanController] follows the contacts). After a change the entitlements
/// (the usage counted against the tier) and the plan (its stages count what they
/// release) are read again, and Home listens to this controller for its counts.
class InstructionsController extends AsyncNotifier<List<InstructionSummary>> {
  /// Counts the changes applied to the list. A read that started before one may carry
  /// older data, so it is read again instead of replacing what the change put there.
  int _epoch = 0;

  @override
  Future<List<InstructionSummary>> build() async {
    if (ref.watch(authControllerProvider) != AuthStatus.signedIn) {
      return const [];
    }
    ref
      ..listen(contactsControllerProvider, (previous, next) {
        final before = previous?.value;
        final after = next.value;
        if (before != null && after != null && _changedNames(before, after)) {
          unawaited(reload());
        }
      })
      ..listen(planControllerProvider, (previous, next) {
        final before = previous?.value;
        final after = next.value;
        // Stage positions (and which stages exist) may have moved.
        if (before != null &&
            after != null &&
            before.version != after.version) {
          unawaited(reload());
        }
      });
    final repository = ref.watch(instructionsRepositoryProvider);
    try {
      return sortInstructions(await repository.list());
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  /// A contact was removed or renamed.
  static bool _changedNames(
    List<TrustedContact> before,
    List<TrustedContact> after,
  ) {
    final now = {for (final c in after) c.id: c.displayName};
    return before.any((c) => now[c.id] != c.displayName);
  }

  InstructionsRepository get _repository =>
      ref.read(instructionsRepositoryProvider);

  List<InstructionSummary> get _current => state.value ?? const [];

  Future<T> _run<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  /// Reads the list again and returns the failure, or null. The list already on screen
  /// stays when the refresh fails; with no list yet, the failure becomes the state.
  Future<AppFailure?> reload() async {
    if (!state.hasValue) {
      state = const AsyncLoading<List<InstructionSummary>>();
    }
    final epoch = _epoch;
    try {
      final items = sortInstructions(await _run(_repository.list));
      if (epoch != _epoch) {
        return await reload();
      }
      state = AsyncData(items);
      return null;
    } on AppFailure catch (failure) {
      if (!state.hasValue) {
        state = AsyncError<List<InstructionSummary>>(
          failure,
          StackTrace.current,
        );
      }
      return failure;
    }
  }

  /// What changed on the server that screens elsewhere count: the usage against the
  /// tier's limit and the number of instructions each plan stage releases.
  void _changed() {
    ref.invalidate(entitlementsProvider);
    unawaited(ref.read(planControllerProvider.notifier).reload());
  }

  /// A 404 on a change: a contact, a stage or the instruction itself is not the
  /// person's (any more). Everything the screens show about them is read again.
  Future<void> _notFound() async {
    await ref.read(contactsControllerProvider.notifier).reload();
    await ref.read(planControllerProvider.notifier).reload();
    await reload();
  }

  /// Creates an instruction. 403 `plan_limit_reached` at the tier's limit and 422 with
  /// field errors are rethrown as they are; a 404 reads the contacts, the plan and the
  /// list again first.
  Future<Instruction> addInstruction(InstructionDraft draft) async {
    try {
      final created = await _run(() => _repository.create(draft));
      _epoch++;
      state = AsyncData(
        sortInstructions([
          created.summary,
          for (final item in _current)
            if (item.id != created.id) item,
        ]),
      );
      _changed();
      return created;
    } on NotFoundFailure {
      await _notFound();
      rethrow;
    }
  }

  /// Changes an instruction; [patch] must not be empty. Setting `recipients` replaces
  /// the whole list.
  Future<Instruction> updateInstruction(
    String id,
    InstructionPatch patch,
  ) async {
    try {
      final updated = await _run(() => _repository.update(id, patch));
      _epoch++;
      state = AsyncData(
        sortInstructions([
          for (final item in _current)
            if (item.id == updated.id) updated.summary else item,
        ]),
      );
      _changed();
      return updated;
    } on NotFoundFailure {
      await _notFound();
      rethrow;
    }
  }

  /// The plan as it is now: the one on hand, or a fresh read.
  Future<Plan> _plan() async {
    final current = ref.read(planControllerProvider).value;
    if (current != null) {
      return current;
    }
    try {
      final loaded = await ref.read(planControllerProvider.future);
      if (loaded != null) {
        return loaded;
      }
    } on Object catch (error) {
      throw toAppFailure(error);
    }
    throw const UnknownFailure();
  }

  /// The plan with a stage added for every time in [missing] (minutes to the contacts
  /// told then, who are the people that receive it), in time order. Every stage the plan
  /// has keeps its id, its time and its contacts exactly as they are.
  PlanDraft _withStages(Plan plan, Map<int, Set<String>> missing) {
    final stages = [
      ...plan.toDraft().stages,
      for (final entry in missing.entries)
        PlanStageDraft(
          offsetMinutes: entry.key,
          contactIds: entry.value.toList()..sort(),
        ),
    ]..sort((a, b) => a.offsetMinutes.compareTo(b.offsetMinutes));
    return PlanDraft(graceMinutes: plan.graceMinutes, stages: stages);
  }

  /// The times in [choices] that are not stages of [plan], with who is told at each.
  static Map<int, Set<String>> _missingTimes(
    Plan plan,
    List<RecipientChoice> choices,
  ) {
    final missing = <int, Set<String>>{};
    for (final choice in choices) {
      final offset = choice.newOffsetMinutes;
      if (offset != null &&
          !plan.stages.any((s) => s.offsetMinutes == offset)) {
        missing.putIfAbsent(offset, () => <String>{}).add(choice.contactId);
      }
    }
    return missing;
  }

  /// Turns [choices] into stage ids, first adding to the plan every time it does not have
  /// a stage for, in **one** save (`PUT /plan` with `If-Match`, so it changes everything
  /// or nothing). Each new stage tells the people chosen for it. Every other stage is
  /// sent exactly as it is. Returns the recipients and whether a stage was added.
  ///
  /// A 412/428 (the plan changed meanwhile) was already re-read by the plan controller:
  /// it is tried once more against that plan, silently, and if it fails again the failure
  /// is thrown (the plan's "changed somewhere else" notice). Every other failure is
  /// thrown as it came, with nothing sent for the instruction. A 403 `reauth_required`
  /// is thrown untouched so a wrapper can ask for the password and run the whole save
  /// again: it looks at the plan again, so a stage that was added meanwhile is reused.
  Future<({List<RecipientDraft> recipients, bool addedStage})> _resolveTimes(
    List<RecipientChoice> choices,
  ) async {
    var plan = await _plan();
    var missing = _missingTimes(plan, choices);
    var added = false;
    if (missing.isNotEmpty) {
      final planController = ref.read(planControllerProvider.notifier);
      try {
        plan = await planController.save(_withStages(plan, missing));
      } on ConflictFailure catch (failure) {
        if (failure.code != 'precondition_failed' &&
            failure.code != 'precondition_required') {
          rethrow;
        }
        // The controller read the latest plan; what is still missing there is added.
        plan = await _plan();
        missing = _missingTimes(plan, choices);
        if (missing.isNotEmpty) {
          plan = await planController.save(_withStages(plan, missing));
        }
      }
      added = true;
    }
    return (
      recipients: [
        for (final choice in choices)
          RecipientDraft(
            contactId: choice.contactId,
            releaseStageId:
                choice.stageId ??
                plan.stages
                    .firstWhere(
                      (s) => s.offsetMinutes == choice.newOffsetMinutes,
                    )
                    .id,
          ),
      ],
      addedStage: added,
    );
  }

  /// Runs [save] with the recipients of [choices], after the plan has the stages they
  /// need. A failure of [save] once a stage was added is wrapped in
  /// [StageAddedButNotSaved], except 403 `reauth_required`, which is thrown as it is.
  Future<Instruction> _saveWith(
    List<RecipientChoice> choices,
    Future<Instruction> Function(List<RecipientDraft> recipients) save,
  ) async {
    final resolved = await _resolveTimes(choices);
    try {
      return await save(resolved.recipients);
    } on ForbiddenFailure catch (failure) {
      if (failure.code == 'reauth_required' || !resolved.addedStage) {
        rethrow;
      }
      throw StageAddedButNotSaved(failure);
    } on AppFailure catch (failure) {
      if (!resolved.addedStage) {
        rethrow;
      }
      throw StageAddedButNotSaved(failure);
    }
  }

  /// Creates an instruction whose recipients are [recipients], adding to the plan the
  /// times it has no stage for yet (see [_resolveTimes]). Nothing is sent for the
  /// instruction unless the plan was saved.
  Future<Instruction> addInstructionWithTimes({
    required InstructionCategory category,
    required String title,
    required String body,
    required List<RecipientChoice> recipients,
  }) => _saveWith(
    recipients,
    (drafts) => addInstruction(
      InstructionDraft(
        category: category,
        title: title,
        body: body,
        recipients: drafts,
      ),
    ),
  );

  /// Changes an instruction and sets its recipients to [recipients] (the same
  /// resolution as [addInstructionWithTimes]). [fields] is the rest of the change and
  /// has no recipients of its own.
  Future<Instruction> updateInstructionWithTimes(
    String id,
    InstructionPatch fields, {
    required List<RecipientChoice> recipients,
  }) => _saveWith(
    recipients,
    (drafts) => updateInstruction(
      id,
      InstructionPatch(
        category: fields.category,
        title: fields.title,
        body: fields.body,
        status: fields.status,
        recipients: drafts,
      ),
    ),
  );

  /// Deletes an instruction: its content is wiped and nothing it released stays open.
  Future<void> removeInstruction(String id) async {
    try {
      await _run(() => _repository.delete(id));
    } on NotFoundFailure {
      // Already gone (deleted on another device): the list agrees with the server now.
      await reload();
      rethrow;
    }
    _epoch++;
    state = AsyncData([
      for (final item in _current)
        if (item.id != id) item,
    ]);
    _changed();
  }
}

final instructionsControllerProvider =
    AsyncNotifierProvider<InstructionsController, List<InstructionSummary>>(
      InstructionsController.new,
    );

/// The categories to offer, in the server's order (`GET /instruction-categories`).
/// Ids this app version has no words for are left out. When the list cannot be read the
/// app's own order is used, so the form still works; the server validates the choice.
final instructionCategoriesProvider =
    FutureProvider.autoDispose<List<InstructionCategory>>((ref) async {
      if (ref.watch(authControllerProvider) != AuthStatus.signedIn) {
        return InstructionCategory.values;
      }
      try {
        final infos = await ref
            .watch(instructionsRepositoryProvider)
            .categories();
        final known = [
          for (final info in infos)
            if (info.category != null) info,
        ]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
        final categories = [for (final info in known) info.category!];
        return categories.isEmpty ? InstructionCategory.values : categories;
      } on Object {
        return InstructionCategory.values;
      }
    });
