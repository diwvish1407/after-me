import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/models/api_problem.dart';
import '../../../core/design_system/error_view.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../contacts/presentation/contact_labels.dart';
import '../application/plan_editor_draft.dart';
import '../data/plan_repository.dart';

final RegExp _stageOffsetField = RegExp(r'^stages\[\d+\]\.offset_minutes$');

/// What a 422 on the plan says about the fields, in the app's own words (the server's
/// `message` is never shown), or null when no field is one this version names.
///
/// `grace_minutes` (`out_of_range`, `not_a_preset`) and a stage's `offset_minutes`
/// (`must_equal_grace`, `too_close`, `too_large`, `not_a_preset`, `release_too_early`)
/// are the fields the plan step's choices can get wrong.
String? planFieldErrorText(AppLocalizations l10n, List<ApiFieldError> errors) {
  for (final error in errors) {
    if (error.field == 'grace_minutes') {
      return l10n.planErrorGrace;
    }
    if (_stageOffsetField.hasMatch(error.field)) {
      return l10n.planErrorStageTime;
    }
  }
  return null;
}

/// The sentence for a failed save of the plan: the plan-specific wording for the answers
/// that are about the plan (changed elsewhere, a contact that is gone, a field the
/// choices got wrong), otherwise the generic [failureMessage].
String planFailureMessage(AppLocalizations l10n, AppFailure failure) =>
    switch (failure) {
      ConflictFailure(code: 'precondition_failed' || 'precondition_required') =>
        l10n.planStale,
      NotFoundFailure() => l10n.planContactGone,
      ValidationFailure(:final fieldErrors) =>
        planFieldErrorText(l10n, fieldErrors) ?? failureMessage(l10n, failure),
      // No answer: nothing was confirmed, and the choices are still on screen.
      _ => actionFailureMessage(l10n, failure, UnconfirmedAction.save),
    };

/// The sentence for something the plan editor found wrong, in the app's own words: the
/// app's own check and the server's field errors say the same thing. [rules] gives the
/// numbers the sentence names.
String planIssueText(
  AppLocalizations l10n,
  PlanIssueKind kind,
  PlanRules rules,
) => switch (kind) {
  PlanIssueKind.graceOutOfRange => l10n.planIssueGraceRange(
    formatDurationMinutes(l10n, rules.graceMin),
    formatDurationMinutes(l10n, rules.graceMax),
  ),
  PlanIssueKind.graceNotAllowed => l10n.planErrorGrace,
  PlanIssueKind.stageTooClose => l10n.planIssueStageTooClose(
    formatDurationMinutes(l10n, rules.stageGapMin),
  ),
  PlanIssueKind.stageTooLarge => l10n.planIssueStageTooLarge(
    formatDurationMinutes(l10n, rules.offsetMax),
  ),
  PlanIssueKind.stageNotAllowed => l10n.planIssueStageNotAllowed,
  PlanIssueKind.stageReleaseTooEarly => l10n.planIssueStageRelease(
    formatDurationMinutes(l10n, rules.releaseOffsetMin),
  ),
  PlanIssueKind.noStage => l10n.planIssueNoStage,
  PlanIssueKind.other => l10n.planIssueOther,
};

/// The warning for a line of advice (advice only: the server decides what is saved).
String planAdviceText(AppLocalizations l10n, PlanAdvice advice) {
  final name = advice.contact?.displayName ?? '';
  return switch (advice.kind) {
    PlanAdviceKind.noStage => l10n.planWarnNoStage,
    PlanAdviceKind.nobodyTold => l10n.planWarnNobodyTold,
    PlanAdviceKind.nobodyReachable => l10n.planWarnNobodyReachable,
    PlanAdviceKind.stageEmpty => l10n.planWarnStageEmpty,
    PlanAdviceKind.contactWaiting => l10n.planWarnWaiting(name),
    PlanAdviceKind.contactUnreachable => l10n.planWarnUnreachable(
      name,
      statusExplanation(l10n, advice.contact!.verificationStatus),
    ),
    PlanAdviceKind.contactOff => l10n.planWarnOff(name),
  };
}
