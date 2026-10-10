import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/design_system/design_system.dart';
import '../data/instructions_repository.dart';

/// What [InstructionByIdView] lets its content do with the loaded instruction.
abstract interface class InstructionHolder {
  /// Replaces what is shown with what the server just answered (after a change).
  void replace(Instruction instruction);

  /// Reads the instruction again.
  Future<void> reload();
}

/// Reads one instruction with `GET /instructions/{id}` and builds [builder] with it, with
/// calm loading, error (retry) and "not found" pages around it.
///
/// The body is held by this widget's state only, for as long as the screen is open, and
/// is dropped with it: it is never kept in a provider, a cache or on disk
/// (SECURITY.md §11).
class InstructionByIdView extends ConsumerStatefulWidget {
  const InstructionByIdView({
    required this.id,
    required this.title,
    required this.builder,
    super.key,
  });

  final String id;

  /// App bar title of the loading, error and not-found pages.
  final String title;
  final Widget Function(
    BuildContext context,
    Instruction instruction,
    InstructionHolder holder,
  )
  builder;

  @override
  ConsumerState<InstructionByIdView> createState() =>
      _InstructionByIdViewState();
}

class _InstructionByIdViewState extends ConsumerState<InstructionByIdView>
    implements InstructionHolder {
  Instruction? _instruction;
  AppFailure? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  @override
  void didUpdateWidget(covariant InstructionByIdView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      // Another instruction in the same place: never show the old one's text.
      setState(() {
        _instruction = null;
        _failure = null;
      });
      unawaited(reload());
    }
  }

  @override
  void replace(Instruction instruction) {
    if (mounted) {
      setState(() {
        _instruction = instruction;
        _failure = null;
      });
    }
  }

  @override
  Future<void> reload() async {
    final repository = ref.read(instructionsRepositoryProvider);
    try {
      final instruction = await repository.get(widget.id);
      replace(instruction);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _failure = toAppFailure(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final instruction = _instruction;
    if (instruction != null) {
      return widget.builder(context, instruction, this);
    }
    final failure = _failure;
    return FormPage(
      title: widget.title,
      children: [
        if (failure != null)
          ErrorView(
            failure: failure,
            onRetry: () {
              setState(() => _failure = null);
              unawaited(reload());
            },
          )
        else
          const LoadingView(),
      ],
    );
  }
}
