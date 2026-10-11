import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../application/instructions_controller.dart';
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
/// The server answers 403 `reauth_required` unless the password was entered in the last 5
/// minutes. The read goes through `withReauth`: the password sheet is shown once and the
/// same read repeated once. When the sheet is closed the page says, calmly, that the
/// instruction stays hidden, and one button asks again; nothing was changed.
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

  /// The password sheet was closed (or the server still wanted it): nothing is shown yet.
  bool _hidden = false;

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
        _hidden = false;
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
        _hidden = false;
      });
    }
  }

  @override
  Future<void> reload() async {
    final repository = ref.read(instructionsRepositoryProvider);
    try {
      final instruction = await withReauth<Instruction>(
        context,
        () => repository.get(widget.id),
        reason: ReauthReason.instructionRead,
      );
      if (instruction == null) {
        // The sheet was closed: nothing was asked of the server again.
        if (mounted) {
          setState(() => _hidden = true);
        }
        return;
      }
      replace(instruction);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      final failure = toAppFailure(error);
      setState(() {
        // Still asked for after the password was accepted: say it as hidden, not broken.
        if (isPasswordRequired(failure)) {
          _hidden = true;
        } else {
          _failure = failure;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final instruction = _instruction;
    if (instruction != null) {
      return widget.builder(context, instruction, this);
    }
    final failure = _failure;
    final l10n = AppLocalizations.of(context);
    return FormPage(
      title: widget.title,
      children: [
        if (_hidden)
          EmptyState(
            icon: Icons.lock_outline_rounded,
            title: l10n.instructionsLockedTitle,
            message: l10n.instructionDetailLockedBody,
            action: AppButton.primary(
              label: l10n.instructionShowOne,
              icon: Icons.visibility_outlined,
              onPressed: () {
                setState(() => _hidden = false);
                unawaited(reload());
              },
            ),
          )
        else if (failure != null)
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
