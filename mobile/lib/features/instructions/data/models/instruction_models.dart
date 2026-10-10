import 'package:freezed_annotation/freezed_annotation.dart';

part 'instruction_models.freezed.dart';
part 'instruction_models.g.dart';

/// The category of an instruction (FR-INS-01). The wire value is the snake_case id
/// (`digital_accounts`, API_SPEC.md §10); the words are localised in the app by id. An
/// id from a newer server is shown as [other], so a screen never has to guess a label.
@JsonEnum(fieldRename: FieldRename.snake)
enum InstructionCategory {
  personal,
  family,
  home,
  work,
  business,
  documents,
  insurance,
  pets,
  travel,
  digitalAccounts,
  other;

  /// The id on the wire (`GET /instruction-categories`, `?category=`).
  String get id => switch (this) {
    InstructionCategory.digitalAccounts => 'digital_accounts',
    _ => name,
  };

  /// The category with this wire [id], or null when this app version does not know it.
  static InstructionCategory? tryParse(String? id) {
    for (final category in values) {
      if (category.id == id) {
        return category;
      }
    }
    return null;
  }
}

/// Whether an instruction may be shared. An inactive instruction is never released
/// (FR-INS-04). A value from a newer server counts as [inactive]: the app never claims
/// something will be shared unless the server said so.
@JsonEnum()
enum InstructionStatus { active, inactive }

/// One entry of `GET /v1/instruction-categories`: the id and where it sorts. The id is
/// kept as sent: [category] is null for one this app version cannot word, and such a
/// category is simply not offered.
@freezed
abstract class InstructionCategoryInfo with _$InstructionCategoryInfo {
  const InstructionCategoryInfo._();

  const factory InstructionCategoryInfo({
    required String id,
    required int sortOrder,
  }) = _InstructionCategoryInfo;

  factory InstructionCategoryInfo.fromJson(Map<String, dynamic> json) =>
      _$InstructionCategoryInfoFromJson(json);

  InstructionCategory? get category => InstructionCategory.tryParse(id);
}

/// `GET /v1/instruction-categories`.
@freezed
abstract class InstructionCategoryList with _$InstructionCategoryList {
  const factory InstructionCategoryList({
    @Default(<InstructionCategoryInfo>[]) List<InstructionCategoryInfo> items,
  }) = _InstructionCategoryList;

  factory InstructionCategoryList.fromJson(Map<String, dynamic> json) =>
      _$InstructionCategoryListFromJson(json);
}

/// Who receives an instruction and at which stage (`recipients[]` in API_SPEC.md §10).
@freezed
abstract class InstructionRecipient with _$InstructionRecipient {
  const InstructionRecipient._();

  /// Redacted: names must never reach a log.
  @override
  String toString() => 'InstructionRecipient(<redacted>)';

  const factory InstructionRecipient({
    required String contactId,
    required String displayName,

    /// The plan stage that releases it to this person. Its offset comes from the plan.
    required String releaseStageId,

    /// 1-based position of that stage in the plan.
    required int stagePosition,
  }) = _InstructionRecipient;

  factory InstructionRecipient.fromJson(Map<String, dynamic> json) =>
      _$InstructionRecipientFromJson(json);
}

/// An instruction as the list returns it: **no body** (API_SPEC.md §10). Also what the
/// app keeps of an instruction after it was saved: the body is never kept on the device
/// (SECURITY.md §11).
@freezed
abstract class InstructionSummary with _$InstructionSummary {
  const InstructionSummary._();

  /// Redacted: the title is content and must never reach a log.
  @override
  String toString() => 'InstructionSummary(<redacted>)';

  const factory InstructionSummary({
    required String id,
    required String title,
    @JsonKey(unknownEnumValue: InstructionCategory.other)
    required InstructionCategory category,
    @JsonKey(unknownEnumValue: InstructionStatus.inactive)
    required InstructionStatus status,
    @Default(<InstructionRecipient>[]) List<InstructionRecipient> recipients,
    DateTime? updatedAt,
  }) = _InstructionSummary;

  factory InstructionSummary.fromJson(Map<String, dynamic> json) =>
      _$InstructionSummaryFromJson(json);

  bool get isActive => status == InstructionStatus.active;
}

/// `GET /v1/instructions`.
@freezed
abstract class InstructionList with _$InstructionList {
  const factory InstructionList({
    @Default(<InstructionSummary>[]) List<InstructionSummary> items,
  }) = _InstructionList;

  factory InstructionList.fromJson(Map<String, dynamic> json) =>
      _$InstructionListFromJson(json);
}

/// A whole instruction: `GET /v1/instructions/{id}` and the body of a create or an
/// update. Held in memory only while a screen shows or edits it.
@freezed
abstract class Instruction with _$Instruction {
  const Instruction._();

  /// Redacted: title and body are content and must never reach a log.
  @override
  String toString() => 'Instruction(<redacted>)';

  const factory Instruction({
    required String id,
    required String title,
    required String body,
    @JsonKey(unknownEnumValue: InstructionCategory.other)
    required InstructionCategory category,
    @JsonKey(unknownEnumValue: InstructionStatus.inactive)
    required InstructionStatus status,
    @Default(<InstructionRecipient>[]) List<InstructionRecipient> recipients,
    DateTime? updatedAt,
    DateTime? createdAt,
  }) = _Instruction;

  factory Instruction.fromJson(Map<String, dynamic> json) =>
      _$InstructionFromJson(json);

  bool get isActive => status == InstructionStatus.active;

  /// What the list keeps of it: everything but the body.
  InstructionSummary get summary => InstructionSummary(
    id: id,
    title: title,
    category: category,
    status: status,
    recipients: recipients,
    updatedAt: updatedAt,
  );
}
