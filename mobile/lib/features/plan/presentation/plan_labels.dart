import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/models/api_problem.dart';
import '../../../core/design_system/error_view.dart';
import '../../../l10n/gen/app_localizations.dart';

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
      _ => failureMessage(l10n, failure),
    };
