import 'package:flutter/foundation.dart';

/// Starter templates for the first instruction (USER_FLOWS.md §3 step 7, §9).
/// The wording lives in the ARB; this is only the identity.
enum InstructionTemplate {
  whoToCallFirst,
  homeAndKeys,
  pets,
  workHandover,
  documents,
  insurance,
}

/// What the user wrote for a new instruction.
@immutable
class InstructionDraft {
  const InstructionDraft({
    required this.title,
    required this.body,
    required this.releaseAfterHours,
    required this.recipientContactIds,
    this.template,
  });

  final String title;
  final String body;

  /// Hours after a missed check-in at which the recipients can view it. At least 24.
  final int releaseAfterHours;
  final List<String> recipientContactIds;
  final InstructionTemplate? template;
}

/// A saved instruction. The body is deliberately not part of this summary: instruction
/// content is never kept on the device (SECURITY.md §11).
@immutable
class InstructionSummary {
  const InstructionSummary({
    required this.id,
    required this.title,
    required this.releaseAfterHours,
    required this.recipientContactIds,
  });

  final String id;
  final String title;
  final int releaseAfterHours;
  final List<String> recipientContactIds;
}

/// Instructions.
///
/// **Phase 6 replaces the in-memory implementation** with the encrypted instructions
/// API. The real implementation never caches bodies on the device.
abstract interface class InstructionsRepository {
  Future<List<InstructionSummary>> list();

  Future<InstructionSummary> create(InstructionDraft draft);
}
