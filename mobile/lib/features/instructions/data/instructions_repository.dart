import 'package:flutter/foundation.dart';

import 'models/instruction_models.dart';

export 'models/instruction_models.dart';

/// One person an instruction is released to, and the stage that releases it.
@immutable
class RecipientDraft {
  const RecipientDraft({required this.contactId, required this.releaseStageId});

  final String contactId;
  final String releaseStageId;

  Map<String, Object?> toJson() => <String, Object?>{
    'contact_id': contactId,
    'release_stage_id': releaseStageId,
  };

  @override
  bool operator ==(Object other) =>
      other is RecipientDraft &&
      other.contactId == contactId &&
      other.releaseStageId == releaseStageId;

  @override
  int get hashCode => Object.hash(contactId, releaseStageId);
}

/// What the person wrote for a new instruction (`POST /v1/instructions`). The title and
/// the body are content: this never prints them.
@immutable
class InstructionDraft {
  const InstructionDraft({
    required this.category,
    required this.title,
    required this.body,
    this.status = InstructionStatus.active,
    this.recipients = const <RecipientDraft>[],
  });

  final InstructionCategory category;
  final String title;
  final String body;
  final InstructionStatus status;
  final List<RecipientDraft> recipients;

  Map<String, Object?> toJson() => <String, Object?>{
    'category': category.id,
    'title': title,
    'body': body,
    'status': status.name,
    'recipients': [for (final r in recipients) r.toJson()],
  };

  @override
  String toString() => 'InstructionDraft(<redacted>)';
}

/// A partial update (`PATCH /v1/instructions/{id}`). Only the fields that are set are
/// sent; [recipients], when set, **replaces** the whole list. An empty patch is refused
/// by the server (`422`), so callers check [isEmpty] and send nothing.
@immutable
class InstructionPatch {
  const InstructionPatch({
    this.category,
    this.title,
    this.body,
    this.status,
    this.recipients,
  });

  final InstructionCategory? category;
  final String? title;
  final String? body;
  final InstructionStatus? status;
  final List<RecipientDraft>? recipients;

  bool get isEmpty => toJson().isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'category': ?category?.id,
    'title': ?title,
    'body': ?body,
    'status': ?status?.name,
    if (recipients != null)
      'recipients': [for (final r in recipients!) r.toJson()],
  };

  @override
  String toString() => 'InstructionPatch(<redacted>)';
}

/// Instructions and their categories (API_SPEC.md §10).
///
/// Every method throws an `AppFailure` on error (see `toAppFailure`). The server is
/// authoritative for validation, ownership and the tier limit. Implementations never
/// log titles or bodies, and never keep a body after returning it.
abstract interface class InstructionsRepository {
  /// `GET /v1/instruction-categories`, in the server's order.
  Future<List<InstructionCategoryInfo>> categories();

  /// `GET /v1/instructions[?category=]`: summaries without a body, newest change first.
  Future<List<InstructionSummary>> list({InstructionCategory? category});

  /// `GET /v1/instructions/{id}`: the whole instruction, body included.
  Future<Instruction> get(String id);

  /// `POST /v1/instructions`. 403 `plan_limit_reached` (resource `instructions`) at the
  /// tier's limit; 422 `validation_failed` lists the fields; 404 means a contact or a
  /// stage is not the person's.
  Future<Instruction> create(InstructionDraft draft);

  /// `PATCH /v1/instructions/{id}`.
  Future<Instruction> update(String id, InstructionPatch patch);

  /// `DELETE /v1/instructions/{id}`: the content is wiped and what it released is taken
  /// back.
  Future<void> delete(String id);
}
