import 'package:material_ui/material_ui.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/error_view.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../contacts/data/contacts_repository.dart';
import '../../plan/data/plan_repository.dart';
import '../../plan/presentation/plan_labels.dart';
import '../../plan/presentation/plan_preview.dart';
import '../application/release_stages.dart';
import '../data/instructions_repository.dart';

/// The localised name of a category (FR-INS-01).
String categoryName(AppLocalizations l10n, InstructionCategory category) =>
    switch (category) {
      InstructionCategory.personal => l10n.instructionCategoryPersonal,
      InstructionCategory.family => l10n.instructionCategoryFamily,
      InstructionCategory.home => l10n.instructionCategoryHome,
      InstructionCategory.work => l10n.instructionCategoryWork,
      InstructionCategory.business => l10n.instructionCategoryBusiness,
      InstructionCategory.documents => l10n.instructionCategoryDocuments,
      InstructionCategory.insurance => l10n.instructionCategoryInsurance,
      InstructionCategory.pets => l10n.instructionCategoryPets,
      InstructionCategory.travel => l10n.instructionCategoryTravel,
      InstructionCategory.digitalAccounts =>
        l10n.instructionCategoryDigitalAccounts,
      InstructionCategory.other => l10n.instructionCategoryOther,
    };

/// The chip text for a status (the same words everywhere it is shown).
String statusName(AppLocalizations l10n, InstructionStatus status) =>
    switch (status) {
      InstructionStatus.active => l10n.instructionStatusActive,
      InstructionStatus.inactive => l10n.instructionStatusInactive,
    };

/// A distinct shape per status, so the status never depends on colour alone.
IconData statusIcon(InstructionStatus status) => switch (status) {
  InstructionStatus.active => Icons.check_circle_outline_rounded,
  InstructionStatus.inactive => Icons.pause_circle_outline_rounded,
};

/// One or two letters for a person's avatar: the first letters of the first two words.
String initialsOf(String name) {
  final words = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) {
    return '?';
  }
  final letters = [
    words.first.characters.first,
    if (words.length > 1) words[1].characters.first,
  ];
  return letters.join().toUpperCase();
}

/// "After 1 day" for the stage a person is released at, from the plan's own offset; the
/// stage number when the plan is not known (or no longer has the stage).
String stageAfterLabel(
  AppLocalizations l10n,
  Plan? plan,
  InstructionRecipient recipient,
) {
  final stage = stageById(plan, recipient.releaseStageId);
  return stage == null
      ? l10n.instructionStageNumber(recipient.stagePosition)
      : l10n.instructionStageAfter(
          formatDurationMinutes(l10n, stage.offsetMinutes),
        );
}

/// "Stage 2: after 1 day" (the Plan tab's wording) for the detail screen.
String stageDetailLabel(
  AppLocalizations l10n,
  Plan? plan,
  InstructionRecipient recipient,
) {
  final stage = stageById(plan, recipient.releaseStageId);
  return stage == null
      ? l10n.instructionStageNumber(recipient.stagePosition)
      : l10n.planStageTitle(
          stage.position,
          formatDurationMinutes(l10n, stage.offsetMinutes),
        );
}

/// The recipients that are released at the same stage.
class RecipientGroup {
  const RecipientGroup({required this.recipients, required this.stageId});

  final String stageId;
  final List<InstructionRecipient> recipients;

  List<String> get names => [for (final r in recipients) r.displayName];
}

/// [recipients] grouped by stage, in the order the server lists them (stage, then name).
List<RecipientGroup> groupByStage(List<InstructionRecipient> recipients) {
  final groups = <String, List<InstructionRecipient>>{};
  for (final recipient in recipients) {
    groups.putIfAbsent(recipient.releaseStageId, () => []).add(recipient);
  }
  return [
    for (final entry in groups.entries)
      RecipientGroup(stageId: entry.key, recipients: entry.value),
  ];
}

/// Who receives it and when, one line per stage ("Dad and Mom: After 1 day"), or "Not
/// shared with anyone yet".
List<String> sharingLines(
  AppLocalizations l10n,
  Plan? plan,
  List<InstructionRecipient> recipients,
) {
  if (recipients.isEmpty) {
    return [l10n.instructionNotShared];
  }
  return [
    for (final group in groupByStage(recipients))
      l10n.instructionRecipientWhen(
        joinNames(l10n, group.names),
        stageAfterLabel(l10n, plan, group.recipients.first),
      ),
  ];
}

/// The gentle notes about recipients who cannot receive it yet: who has not accepted,
/// and who cannot be reached. Names only: never anything about the content.
class RecipientNotes {
  const RecipientNotes({this.pending = const [], this.unreachable = const []});

  final List<String> pending;
  final List<String> unreachable;

  bool get isEmpty => pending.isEmpty && unreachable.isEmpty;

  /// The notes as sentences.
  List<String> lines(AppLocalizations l10n) => [
    if (pending.isNotEmpty)
      l10n.instructionRecipientPending(
        pending.length,
        joinNames(l10n, pending),
      ),
    if (unreachable.isNotEmpty)
      l10n.instructionRecipientUnreachable(joinNames(l10n, unreachable)),
  ];
}

/// The notes for [recipients], judged by the contacts' current status. A recipient whose
/// contact is not in [contacts] (not loaded yet) says nothing.
RecipientNotes recipientNotes(
  List<InstructionRecipient> recipients,
  List<TrustedContact> contacts,
) {
  final pending = <String>[];
  final unreachable = <String>[];
  for (final recipient in recipients) {
    for (final contact in contacts) {
      if (contact.id != recipient.contactId || contact.isAccepted) {
        continue;
      }
      (contact.isUnreachable ? unreachable : pending).add(
        recipient.displayName,
      );
    }
  }
  return RecipientNotes(pending: pending, unreachable: unreachable);
}

/// The sentence for a failed save, delete or switch: the instruction-specific wording
/// for the answers that are about the instruction, otherwise the generic
/// [failureMessage]. The server's own text is never shown.
///
/// A save may have changed the plan first (a time the plan had no stage for), so the
/// plan's answers are worded here too: the stage limit (nothing was changed; [freePlan]
/// names the free plan), a plan that
/// was changed somewhere else, and a time that does not fit (nothing was changed).
String instructionFailureMessage(
  AppLocalizations l10n,
  AppFailure failure, {
  bool freePlan = false,
}) => switch (failure) {
  NotFoundFailure() => l10n.instructionNotFound,
  PlanLimitFailure(resource: 'stages', :final limit) =>
    freePlan
        ? l10n.instructionStageLimitFree(limit ?? 2)
        : l10n.instructionStageLimit(limit ?? 2),
  ConflictFailure(code: 'precondition_failed' || 'precondition_required') =>
    l10n.planStale,
  ValidationFailure(:final fieldErrors)
      when planFieldErrorText(l10n, fieldErrors) != null =>
    l10n.instructionTimeRefused,
  _ => failureMessage(l10n, failure),
};
