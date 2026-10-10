import 'instructions_repository.dart';

/// TEMPORARY (Phase 2): keeps only the summary of each instruction in memory (the body
/// is discarded immediately, as the real implementation must). **Replaced in Phase 6**.
class InMemoryInstructionsRepository implements InstructionsRepository {
  final List<InstructionSummary> _items = [];
  int _next = 1;

  @override
  Future<List<InstructionSummary>> list() async => List.unmodifiable(_items);

  @override
  Future<InstructionSummary> create(InstructionDraft draft) async {
    final item = InstructionSummary(
      id: 'local-instruction-${_next++}',
      title: draft.title.trim(),
      releaseAfterHours: draft.releaseAfterHours,
      recipientContactIds: List.unmodifiable(draft.recipientContactIds),
    );
    _items.add(item);
    return item;
  }
}
