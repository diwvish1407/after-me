import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../data/instructions_repository.dart';

/// What is typed in the instruction form right now (USER_FLOWS.md §9: "autosave draft
/// in memory only").
///
/// It exists so that a person who leaves the form (to add a contact, or to look at the
/// plan) finds what they wrote when they come back. It lives in this provider **only**:
/// it is never written to storage, never logged and is dropped when the instruction is
/// saved, when the person starts over, and when the session ends.
@immutable
class InstructionAutosave {
  const InstructionAutosave({
    this.editingId,
    this.category,
    this.title = '',
    this.body = '',
    this.stageByContact = const <String, String?>{},
    this.perPerson = false,
  });

  /// The instruction being edited, or null for a new one. A draft is only restored for
  /// the screen it was typed on.
  final String? editingId;
  final InstructionCategory? category;
  final String title;
  final String body;

  /// Chosen recipients: contact id to the stage id chosen for them (null until chosen).
  final Map<String, String?> stageByContact;

  /// Each person has their own time, instead of one time for everybody.
  final bool perPerson;

  @override
  String toString() => 'InstructionAutosave(<redacted>)';
}

/// The one in-memory draft. Watches the sign-in status, so signing out (or a session
/// that ended) drops it.
class InstructionAutosaveController extends Notifier<InstructionAutosave?> {
  @override
  InstructionAutosave? build() {
    ref.watch(authControllerProvider);
    return null;
  }

  void save(InstructionAutosave draft) => state = draft;

  void clear() => state = null;
}

final instructionAutosaveProvider =
    NotifierProvider<InstructionAutosaveController, InstructionAutosave?>(
      InstructionAutosaveController.new,
    );
