import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/security/secure_screen.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../../checkin/application/schedule_controller.dart';
import '../../contacts/application/contacts_controller.dart';
import '../../instructions/application/instructions_controller.dart';
import '../../instructions/data/instructions_repository.dart';
import '../../settings/presentation/settings_widgets.dart';
import '../application/plan_controller.dart';
import '../application/plan_editor_controller.dart';
import '../application/plan_editor_draft.dart';
import '../data/plan_repository.dart';
import 'plan_editor_sheets.dart';
import 'plan_labels.dart';
import 'plan_preview.dart';

/// The plan editor (USER_FLOWS.md §10), opened from the Plan tab: the grace period, the
/// stages, when each runs and who is told.
///
/// Everything is a draft until "Save changes": the server decides what is saved, the
/// screen only mirrors its rules so that most mistakes are explained before they are
/// sent. Nothing is lost when a save fails, and nothing is claimed that the server has
/// not confirmed. While an incident is open the screen is read-only.
class PlanEditorScreen extends ConsumerWidget {
  const PlanEditorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final plan = ref.watch(planControllerProvider);
    final contacts = ref.watch(contactsControllerProvider);
    if (plan.value != null && contacts.value != null) {
      return const _PlanEditor();
    }
    final Object? error = plan.value == null && plan.hasError
        ? plan.error
        : (contacts.value == null && contacts.hasError ? contacts.error : null);
    return FormPage(
      title: l10n.planEditTitle,
      children: [
        if (error != null)
          ErrorView(
            failure: error is AppFailure ? error : UnknownFailure(cause: error),
            onRetry: () {
              if (plan.value == null) {
                unawaited(ref.read(planControllerProvider.notifier).reload());
              }
              if (contacts.value == null) {
                unawaited(
                  ref.read(contactsControllerProvider.notifier).reload(),
                );
              }
            },
          )
        else
          const LoadingView(),
      ],
    );
  }
}

class _PlanEditor extends ConsumerWidget {
  const _PlanEditor();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(planEditorControllerProvider);
    final rules = ref.watch(planEditorRulesProvider);
    final base = state.base;
    if (base == null || rules == null) {
      return FormPage(
        title: l10n.planEditTitle,
        children: const [LoadingView()],
      );
    }
    final contacts = ref.watch(contactsControllerProvider).value ?? const [];
    final instructions =
        ref.watch(instructionsControllerProvider).value ??
        const <InstructionSummary>[];
    final schedule = ref.watch(scheduleControllerProvider).value;
    final locked = ref.watch(planEditorLockedProvider);
    final isFree =
        ref.watch(entitlementsProvider).value?.isFree ??
        !base.rules.customOffsets;
    final actions = _EditorActions(context, ref);

    final draft = state.draft;
    final editable = !locked && !state.saving;
    final issues = <PlanIssue>{...rules.issues(draft), ...state.serverIssues};
    final blocking = issues.isNotEmpty;
    final advice = planAdvice(draft, contacts);
    final planAdviceLine = advice.where((a) => a.isPlanLevel).firstOrNull;
    final titlesByStage = <String, List<String>>{
      for (final stage in draft.stages)
        if (stage.id != null)
          stage.id!: [
            for (final item in instructions)
              if (item.recipients.any((r) => r.releaseStageId == stage.id))
                item.title,
          ],
    };
    final notice = state.notice;
    final inUseTitles = notice?.kind == PlanEditorNoticeKind.inUse
        ? [
            for (final item in instructions)
              if (notice!.instructionIds.contains(item.id)) item.title,
          ]
        : const <String>[];
    final canAdd = draft.stages.length < rules.stageLimit(base.stages.length);
    final canSave = editable && state.dirty && !blocking && !draft.isEmpty;

    return SecureScreen(
      // Titles are content: the window is secure while one is on screen.
      enabled: inUseTitles.isNotEmpty,
      child: PopScope(
        canPop: !state.dirty && !state.saving,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop || state.saving) {
            return;
          }
          if (await actions.confirmLeave() && context.mounted) {
            context.pop();
          }
        },
        child: FormPage(
          title: l10n.planEditTitle,
          children: [
            if (locked) ...[
              StatusBanner(
                kind: StatusBannerKind.attention,
                title: l10n.planEditLockedTitle,
                message: l10n.planEditLockedBody,
              ),
              Gap.md,
            ],
            if (notice != null) ...[
              _NoticeView(
                notice: notice,
                titles: inUseTitles,
                onUseLatest: actions.discard,
                // The names need the password when the list could not be read.
                onShowTitles:
                    notice.kind == PlanEditorNoticeKind.inUse &&
                        inUseTitles.isEmpty &&
                        ref.watch(instructionsControllerProvider).needsPassword
                    ? actions.revealNotice
                    : null,
              ),
              Gap.md,
            ],
            if (planAdviceLine != null) ...[
              StatusBanner(
                kind: StatusBannerKind.attention,
                message: planAdviceText(l10n, planAdviceLine),
              ),
              Gap.md,
            ],
            if (!locked) ...[
              BodyText(l10n.planEditIntro),
              if (isFree) ...[
                Gap.xs,
                BodyText(l10n.planEditFreeNote(base.rules.maxStages)),
              ],
              Gap.md,
            ],
            _GraceCard(
              draft: draft,
              rules: rules,
              editable: editable,
              showChoices: !locked,
              issues: [
                for (final issue in issues)
                  if (issue.stageKey == null &&
                      issue.kind != PlanIssueKind.noStage)
                    issue,
              ],
              onChoose: actions.setGrace,
              onOther: () => actions.changeGrace(state),
            ),
            Gap.lg,
            Semantics(
              header: true,
              child: Text(
                l10n.planStagesTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Gap.sm,
            for (var i = 0; i < draft.stages.length; i++) ...[
              _StageCard(
                position: i + 1,
                stage: draft.stages[i],
                names: [
                  for (final id in draft.stages[i].contactIds)
                    for (final contact in contacts)
                      if (contact.id == id) contact.displayName,
                ],
                advice: [
                  for (final line in advice)
                    if (line.stageKey == draft.stages[i].key) line,
                ],
                issues: [
                  for (final issue in issues)
                    if (issue.stageKey == draft.stages[i].key) issue,
                ],
                rules: base.rules,
                editable: editable,
                canRemove: draft.stages.length > 1,
                onTime: () => actions.changeTime(state, draft.stages[i], i),
                onWho: () => actions.chooseWho(draft.stages[i], i + 1),
                onRemove: () => actions.remove(
                  draft.stages[i],
                  i + 1,
                  titlesByStage[draft.stages[i].id] ?? const [],
                ),
              ),
              Gap.sm,
            ],
            if (!locked) ...[
              AppButton.secondary(
                label: l10n.planEditAdd,
                icon: Icons.add_rounded,
                onPressed: editable && canAdd
                    ? () => actions.addStage(state)
                    : null,
                expand: true,
              ),
              if (!canAdd) ...[
                Gap.xs,
                BodyText(
                  isFree
                      ? l10n.planEditLimitFree(base.rules.maxStages)
                      : l10n.planEditLimitMax(base.rules.maxStages),
                ),
              ],
            ],
            if (schedule != null && !draft.isEmpty) ...[
              Gap.lg,
              Semantics(
                header: true,
                child: Text(
                  l10n.planPreviewTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Gap.xs,
              if (!locked && state.dirty) ...[
                BodyText(l10n.planEditPreviewNote),
                Gap.sm,
              ] else
                Gap.sm,
              PlanPreview(
                lines: buildPlanPreview(
                  context,
                  dueMinutes: schedule.dueMinutes,
                  plan: draft.toPlanDraft(),
                  contacts: contacts,
                  releaseCounts: {
                    for (final stage in draft.stages)
                      if (stage.id != null) stage.id!: stage.releaseCount,
                  },
                ),
              ),
            ],
            if (!locked) ...[
              Gap.lg,
              if (blocking && state.dirty) ...[
                Semantics(
                  liveRegion: true,
                  child: BodyText(l10n.planEditFixFirst),
                ),
                Gap.xs,
              ],
              AppButton.primary(
                label: l10n.planEditSave,
                isLoading: state.saving,
                onPressed: canSave ? actions.save : null,
                expand: true,
              ),
              if (state.dirty) ...[
                Gap.xs,
                AppButton.text(
                  label: l10n.planEditDiscard,
                  onPressed: state.saving ? null : actions.discard,
                  expand: true,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// The things the editor does in answer to a tap. They read the providers when they run
/// (not when the screen was built) and never touch the context after an `await` without
/// checking it is still there.
class _EditorActions {
  _EditorActions(this.context, this.ref);

  final BuildContext context;
  final WidgetRef ref;

  PlanEditorController get _editor =>
      ref.read(planEditorControllerProvider.notifier);

  void setGrace(int minutes) => _editor.setGrace(minutes);

  void discard() => _editor.discard();

  Future<bool> confirmLeave() {
    final l10n = AppLocalizations.of(context);
    return confirmAction(
      context,
      title: l10n.planEditLeaveTitle,
      message: l10n.planEditLeaveBody,
      confirmLabel: l10n.planEditLeaveConfirm,
      cancelLabel: l10n.planEditLeaveKeep,
    );
  }

  /// A grace period of the person's own (custom times).
  Future<void> changeGrace(PlanEditorState state) async {
    final l10n = AppLocalizations.of(context);
    final rules = ref.read(planEditorRulesProvider);
    if (rules == null) {
      return;
    }
    final draft = state.draft;
    final shares = draft.stages.isNotEmpty && rules.holds(draft.stages.first);
    final picked = await showPlanTimeSheet(
      context,
      title: l10n.planGraceTitle,
      choices: [
        for (final minutes in rules.graceChoices(current: draft.graceMinutes))
          PlanTimeChoice(
            minutes,
            enabled: rules.graceProblem(minutes, shares: shares) == null,
          ),
      ],
      rules: rules.rules,
      problemFor: (minutes) => rules.graceProblem(minutes, shares: shares),
      allowCustom: rules.rules.customOffsets,
      initial: draft.graceMinutes,
    );
    if (picked != null) {
      _editor.setGrace(picked);
    }
  }

  Future<void> changeTime(
    PlanEditorState state,
    EditableStage stage,
    int index,
  ) async {
    final l10n = AppLocalizations.of(context);
    final rules = ref.read(planEditorRulesProvider);
    if (rules == null) {
      return;
    }
    final draft = state.draft;
    final shares = rules.holds(stage);
    PlanIssueKind? problem(int minutes) =>
        rules.stageProblem(draft, stage.key, minutes, shares: shares);
    final picked = await showPlanTimeSheet(
      context,
      title: l10n.planTimeStageTitle,
      choices: [
        for (final minutes in rules.stageChoices(current: stage.offsetMinutes))
          PlanTimeChoice(
            minutes,
            enabled: minutes == stage.offsetMinutes || problem(minutes) == null,
          ),
      ],
      rules: rules.rules,
      problemFor: problem,
      allowCustom: rules.rules.customOffsets,
      initial: stage.offsetMinutes,
    );
    if (picked != null) {
      _editor.setStageTime(stage.key, picked);
    }
  }

  Future<void> addStage(PlanEditorState state) async {
    final l10n = AppLocalizations.of(context);
    final rules = ref.read(planEditorRulesProvider);
    final draft = state.draft;
    if (draft.isEmpty) {
      // The first stage runs when the grace period ends: there is nothing to choose.
      _editor.addStage(draft.graceMinutes);
      return;
    }
    if (rules == null) {
      return;
    }
    PlanIssueKind? problem(int minutes) =>
        rules.stageProblem(draft, null, minutes);
    final picked = await showPlanTimeSheet(
      context,
      title: l10n.planTimeAddTitle,
      choices: [
        for (final minutes in rules.stageChoices(includeKept: false))
          PlanTimeChoice(minutes, enabled: problem(minutes) == null),
      ],
      rules: rules.rules,
      problemFor: problem,
      allowCustom: rules.rules.customOffsets,
    );
    if (picked != null) {
      _editor.addStage(picked);
    }
  }

  Future<void> chooseWho(EditableStage stage, int position) async {
    final contacts = ref.read(contactsControllerProvider).value ?? const [];
    final picked = await showPlanContactsSheet(
      context,
      position: position,
      contacts: contacts,
      selected: stage.contactIds,
    );
    if (picked != null) {
      _editor.setStageContacts(stage.key, picked);
    }
  }

  /// Asks for the password (through `withReauth`, once) and reads the instructions, then
  /// returns the titles of the ones released at [stage]. Empty when the sheet was closed
  /// or the read failed: the caller then says how many, without the names.
  Future<List<String>> revealTitles(EditableStage stage) async {
    final controller = ref.read(instructionsControllerProvider.notifier);
    try {
      final read = await withReauth<bool>(context, () async {
        await controller.refresh();
        return true;
      }, reason: ReauthReason.instructionRead);
      if (read == null) {
        return const [];
      }
    } on AppFailure {
      return const [];
    }
    final items =
        ref.read(instructionsControllerProvider).value ??
        const <InstructionSummary>[];
    return [
      for (final item in items)
        if (item.recipients.any((r) => r.releaseStageId == stage.id))
          item.title,
    ];
  }

  /// "Show which ones" on the notice about a stage that shares instructions: the
  /// password, once, and then the names appear in the notice by themselves.
  Future<void> revealNotice() async {
    final controller = ref.read(instructionsControllerProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    try {
      final read = await withReauth<bool>(context, () async {
        await controller.refresh();
        return true;
      }, reason: ReauthReason.instructionRead);
      if (read == null) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.instructionsShowCancelled)),
        );
      }
    } on AppFailure catch (failure) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            isPasswordRequired(failure)
                ? l10n.instructionsShowCancelled
                : failureMessage(l10n, failure),
          ),
        ),
      );
    }
  }

  /// Takes a stage out of the draft, after asking. A stage that shares instructions
  /// cannot be removed: the person is told which ones and what to do first.
  Future<void> remove(
    EditableStage stage,
    int position,
    List<String> titles,
  ) async {
    final l10n = AppLocalizations.of(context);
    final rules = ref.read(planEditorRulesProvider);
    final shares =
        stage.releaseCount > 0 ||
        titles.isNotEmpty ||
        (rules?.holds(stage) ?? false);
    if (shares) {
      // The names are read from the instructions, which the server shows only to a
      // password entered in the last 5 minutes. When the list is waiting for it, it is
      // asked for here (once); closing the sheet leaves the count without the names.
      var shown = titles;
      if (shown.isEmpty &&
          ref.read(instructionsControllerProvider).needsPassword) {
        shown = await revealTitles(stage);
        if (!context.mounted) {
          return;
        }
      }
      final count = shown.length > stage.releaseCount
          ? shown.length
          : (stage.releaseCount > 0 ? stage.releaseCount : 1);
      await showStageInUseSheet(
        context,
        position: position,
        count: count,
        titles: shown,
      );
      return;
    }
    if (stage.id != null) {
      final draft = ref.read(planEditorControllerProvider).draft;
      final contacts = ref.read(contactsControllerProvider).value ?? const [];
      final names = [
        for (final id in stage.contactIds)
          for (final contact in contacts)
            if (contact.id == id) contact.displayName,
      ];
      final first =
          draft.stages.isNotEmpty && draft.stages.first.key == stage.key;
      final next = first && draft.stages.length > 1 ? draft.stages[1] : null;
      final sentence = names.isEmpty
          ? l10n.planRemoveBodyNobody
          : l10n.planRemoveBody(joinNames(l10n, names));
      final confirmed = await confirmAction(
        context,
        title: l10n.planRemoveTitle(position),
        message: next == null
            ? sentence
            : '$sentence ${l10n.planRemoveFirst(formatDurationMinutes(l10n, next.offsetMinutes))}',
        confirmLabel: l10n.planRemoveConfirm,
        cancelLabel: l10n.cancel,
      );
      if (!confirmed) {
        return;
      }
    }
    _editor.removeStage(stage.key);
  }

  /// Saves. When it would leave a plan that tells nobody while check-ins are on, asks
  /// first; the password is asked for when the server wants it, and the same save is
  /// sent again once.
  Future<void> save() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final state = ref.read(planEditorControllerProvider);
    final base = state.base;
    final on = ref.read(scheduleControllerProvider).value?.isOn ?? false;
    if (base != null &&
        on &&
        base.contactIds.isNotEmpty &&
        state.draft.contactIds.isEmpty) {
      final go = await confirmAction(
        context,
        title: l10n.planEditNobodyTitle,
        message: l10n.planEditNobodyBody,
        confirmLabel: l10n.planEditNobodyConfirm,
        cancelLabel: l10n.cancel,
      );
      if (!go || !context.mounted) {
        return;
      }
    }
    final result = await _editor.save(
      guard: (send) =>
          withReauth<Plan>(context, send, reason: ReauthReason.plan),
    );
    if (!context.mounted) {
      return;
    }
    if (result == PlanEditorSaveResult.saved ||
        result == PlanEditorSaveResult.matchesServer) {
      // Said only now: the server answered with the plan.
      messenger.showSnackBar(SnackBar(content: Text(l10n.planEditSaved)));
      context.pop();
    }
  }
}

/// The grace period: the sentence, the choices this account has, and (with custom times)
/// a way to type one.
class _GraceCard extends StatelessWidget {
  const _GraceCard({
    required this.draft,
    required this.rules,
    required this.editable,
    required this.showChoices,
    required this.issues,
    required this.onChoose,
    required this.onOther,
  });

  final PlanEditorDraft draft;
  final PlanEditorRules rules;

  /// The choices can be used right now (not while a save is on the wire).
  final bool editable;

  /// The choices are shown at all (not while the plan is read-only).
  final bool showChoices;
  final List<PlanIssue> issues;
  final ValueChanged<int> onChoose;
  final VoidCallback onOther;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final shares = draft.stages.isNotEmpty && rules.holds(draft.stages.first);
    return SectionCard(
      title: l10n.planGraceCardTitle,
      subtitle: l10n.planEditGraceHelp,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.planGraceSentence(
              formatDurationMinutes(l10n, draft.graceMinutes),
            ),
          ),
          if (showChoices) ...[
            Gap.sm,
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xxs,
              children: [
                for (final minutes in rules.graceChoices(
                  current: draft.graceMinutes,
                ))
                  ChoiceChip(
                    label: Text(formatDurationMinutes(l10n, minutes)),
                    selected: draft.graceMinutes == minutes,
                    onSelected:
                        editable &&
                            (minutes == draft.graceMinutes ||
                                rules.graceProblem(minutes, shares: shares) ==
                                    null)
                        ? (_) => onChoose(minutes)
                        : null,
                  ),
              ],
            ),
          ],
          if (rules.rules.customOffsets && showChoices && editable) ...[
            Gap.xs,
            AppButton.text(label: l10n.planEditGraceOther, onPressed: onOther),
          ],
          for (final issue in issues) ...[
            Gap.xs,
            _Note(
              icon: Icons.error_outline_rounded,
              text: planIssueText(l10n, issue.kind, rules.rules),
              isError: true,
            ),
          ],
        ],
      ),
    );
  }
}

/// One stage: its number and time, who is told, what it shares, what the editor has to
/// say about it, and the three things that can be done to it.
///
/// A screen reader hears one sentence for the facts ("Stage 2, 1 day after the deadline,
/// notifies Brother, 1 instruction will be shared at this stage") and then each warning
/// and button on its own.
class _StageCard extends StatelessWidget {
  const _StageCard({
    required this.position,
    required this.stage,
    required this.names,
    required this.advice,
    required this.issues,
    required this.rules,
    required this.editable,
    required this.canRemove,
    required this.onTime,
    required this.onWho,
    required this.onRemove,
  });

  final int position;
  final EditableStage stage;
  final List<String> names;
  final List<PlanAdvice> advice;
  final List<PlanIssue> issues;
  final PlanRules rules;
  final bool editable;
  final bool canRemove;
  final VoidCallback onTime;
  final VoidCallback onWho;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final delay = formatDurationMinutes(l10n, stage.offsetMinutes);
    final summary = names.isEmpty
        ? l10n.planStageSummaryNobody(position, delay)
        : l10n.planStageSummary(position, delay, joinNames(l10n, names));
    final sharing = stage.releaseCount > 0
        ? l10n.planEditStageReleases(stage.releaseCount)
        : null;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              container: true,
              header: true,
              excludeSemantics: true,
              label: sharing == null ? summary : '$summary, $sharing',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.planStageTitle(position, delay),
                    style: textTheme.titleMedium,
                  ),
                  Text(
                    names.isEmpty
                        ? l10n.planStageNobody
                        : l10n.planStageNotify(joinNames(l10n, names)),
                  ),
                  if (position == 1)
                    Text(
                      l10n.planEditStageFirst,
                      style: textTheme.bodySmall?.copyWith(color: t.textMuted),
                    ),
                  if (sharing != null) Text(sharing),
                ],
              ),
            ),
            for (final line in advice) ...[
              Gap.xs,
              _Note(
                icon: Icons.info_outline_rounded,
                text: planAdviceText(l10n, line),
              ),
            ],
            for (final issue in issues)
              if (issue.kind != PlanIssueKind.noStage) ...[
                Gap.xs,
                _Note(
                  icon: Icons.error_outline_rounded,
                  text: planIssueText(l10n, issue.kind, rules),
                  isError: true,
                ),
              ],
            if (editable) ...[
              Gap.xs,
              Wrap(
                spacing: AppSpacing.xs,
                children: [
                  if (position > 1)
                    _StageAction(
                      label: l10n.planEditChangeTime,
                      semanticLabel: l10n.planEditChangeTimeFor(position),
                      onPressed: onTime,
                    ),
                  _StageAction(
                    label: l10n.planEditChooseWho,
                    semanticLabel: l10n.planEditChooseWhoFor(position),
                    onPressed: onWho,
                  ),
                  if (canRemove)
                    _StageAction(
                      label: l10n.planEditRemove,
                      semanticLabel: l10n.planEditRemoveFor(position),
                      onPressed: onRemove,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A button on a stage card. Several cards have the same words, so a screen reader is
/// given the stage's number as well.
class _StageAction extends StatelessWidget {
  const _StageAction({
    required this.label,
    required this.semanticLabel,
    required this.onPressed,
  });

  final String label;
  final String semanticLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: true,
      label: semanticLabel,
      onTap: onPressed,
      excludeSemantics: true,
      child: AppButton.text(label: label, onPressed: onPressed),
    );
  }
}

/// An icon and a sentence (never colour alone): a warning, or what the server refused.
class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.isError = false});

  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = isError ? Theme.of(context).colorScheme.error : t.attention;
    return Semantics(
      container: true,
      liveRegion: isError,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Icon(icon, color: color, size: 20)),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: isError ? color : t.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// The message above the editor about the last attempt to save.
class _NoticeView extends StatelessWidget {
  const _NoticeView({
    required this.notice,
    required this.titles,
    required this.onUseLatest,
    this.onShowTitles,
  });

  final PlanEditorNotice notice;
  final List<String> titles;
  final VoidCallback onUseLatest;

  /// Asks for the password and names the instructions; null when it is not needed.
  final VoidCallback? onShowTitles;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return switch (notice.kind) {
      PlanEditorNoticeKind.stale => Semantics(
        liveRegion: true,
        container: true,
        child: StatusBanner(
          kind: StatusBannerKind.attention,
          message: l10n.planEditStale,
          action: AppButton.text(
            label: l10n.planEditUseLatest,
            onPressed: onUseLatest,
          ),
        ),
      ),
      PlanEditorNoticeKind.notFound => FailureNotice(
        message: l10n.planEditNotFound,
      ),
      PlanEditorNoticeKind.inUse => Semantics(
        liveRegion: true,
        container: true,
        child: StatusBanner(
          kind: StatusBannerKind.attention,
          message: titles.isEmpty
              ? l10n.planInUseNotice
              : '${l10n.planInUseNotice}\n${titles.join('\n')}',
          action: onShowTitles == null
              ? null
              : AppButton.text(
                  label: l10n.planInUseShowTitles,
                  onPressed: onShowTitles,
                ),
        ),
      ),
      PlanEditorNoticeKind.limit => FailureNotice(
        message: l10n.errorPlanLimitStages,
      ),
      // Offline or server trouble: nothing was confirmed, and the edits are still here.
      PlanEditorNoticeKind.failure => FailureNotice(
        message: actionFailureMessage(
          l10n,
          notice.failure ?? const UnknownFailure(),
          UnconfirmedAction.save,
        ),
      ),
    };
  }
}
