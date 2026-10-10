import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/security/secure_screen.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/application/me_controller.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../../contacts/application/contacts_controller.dart';
import '../../plan/application/plan_controller.dart';
import '../application/instructions_controller.dart';
import '../data/instructions_repository.dart';
import 'instruction_by_id_view.dart';
import 'instruction_labels.dart';
import 'instruction_status_chip.dart';

/// One instruction in full: its text, who receives it and when, whether it is active,
/// Edit and Delete (USER_FLOWS §9). The text is read from the server for this screen and
/// dropped when it closes. The window is `FLAG_SECURE` while it is open.
class InstructionDetailScreen extends StatelessWidget {
  const InstructionDetailScreen({required this.instructionId, super.key});

  final String instructionId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SecureScreen(
      child: InstructionByIdView(
        id: instructionId,
        title: l10n.instructionDetailTitle,
        builder: (context, instruction, holder) =>
            _Detail(instruction: instruction, holder: holder),
      ),
    );
  }
}

class _Detail extends ConsumerStatefulWidget {
  const _Detail({required this.instruction, required this.holder});

  final Instruction instruction;
  final InstructionHolder holder;

  @override
  ConsumerState<_Detail> createState() => _DetailState();
}

class _DetailState extends ConsumerState<_Detail> {
  bool _switching = false;
  bool _deleting = false;
  AppFailure? _failure;

  Instruction get _instruction => widget.instruction;

  /// Switches it on or off. Switching **off** an instruction that has recipients, while
  /// check-ins are on, asks for the password (403 `reauth_required`): the sheet is shown
  /// once and the same change repeated; closing it changes nothing and says nothing.
  /// Switching on never asks.
  Future<void> _setActive({required bool active}) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(instructionsControllerProvider.notifier);
    final patch = InstructionPatch(
      status: active ? InstructionStatus.active : InstructionStatus.inactive,
    );
    setState(() {
      _switching = true;
      _failure = null;
    });
    try {
      final updated = await withReauth(
        context,
        () => controller.updateInstruction(_instruction.id, patch),
        reason: !active && _instruction.recipients.isNotEmpty
            ? ReauthReason.instructionOff
            : null,
      );
      if (updated != null) {
        widget.holder.replace(updated);
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              active ? l10n.instructionActivated : l10n.instructionDeactivated,
            ),
          ),
        );
      }
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(() => _failure = failure);
      }
    } finally {
      if (mounted) {
        setState(() => _switching = false);
      }
    }
  }

  Future<void> _edit() async {
    final saved = await context.push<bool>(
      AppRoutes.instructionEdit(_instruction.id),
    );
    if (saved ?? false) {
      await widget.holder.reload();
    }
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => const _DeleteSheet(),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _deleting = true;
      _failure = null;
    });
    final controller = ref.read(instructionsControllerProvider.notifier);
    try {
      // Deleting one that has recipients while check-ins are on asks for the password
      // (403 `reauth_required`): the sheet is shown once and the same delete repeated.
      final deleted = await withReauth(
        context,
        () async {
          await controller.removeInstruction(_instruction.id);
          return true;
        },
        reason: _instruction.recipients.isEmpty
            ? null
            : ReauthReason.instructionOff,
      );
      if (deleted == null) {
        // The sheet was closed: nothing was deleted and nothing is said.
        if (mounted) {
          setState(() => _deleting = false);
        }
        return;
      }
      messenger.showSnackBar(SnackBar(content: Text(l10n.instructionDeleted)));
      router.pop();
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(() {
          _deleting = false;
          _failure = failure;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final instruction = _instruction;
    final plan = ref.watch(planControllerProvider).value;
    final contacts = ref.watch(contactsControllerProvider).value ?? const [];
    final timezone = ref.watch(meControllerProvider).value?.profile.timezone;
    final active = instruction.status == InstructionStatus.active;
    final busy = _switching || _deleting;
    final notes = recipientNotes(instruction.recipients, contacts).lines(l10n);
    final changed = instruction.updatedAt;
    return FormPage(
      title: l10n.instructionDetailTitle,
      children: [
        if (_failure != null) ...[
          FailureNotice(message: instructionFailureMessage(l10n, _failure!)),
          Gap.md,
        ],
        PageHeading(instruction.title),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          categoryName(l10n, instruction.category),
          style: textTheme.bodyMedium?.copyWith(color: t.textMuted),
        ),
        Gap.sm,
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: InstructionStatusChip(status: instruction.status),
        ),
        Gap.xs,
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.instructionActiveLabel),
          subtitle: Text(
            active ? l10n.instructionActiveOn : l10n.instructionActiveOff,
          ),
          value: active,
          onChanged: busy ? null : (value) => _setActive(active: value),
        ),
        Gap.md,
        SectionCard(
          title: l10n.instructionDetailBody,
          child: SizedBox(
            width: double.infinity,
            child: Text(instruction.body),
          ),
        ),
        Gap.md,
        SectionCard(
          title: l10n.instructionDetailSharedWith,
          child: instruction.recipients.isEmpty
              ? Text(l10n.instructionDetailNobody)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final recipient in instruction.recipients)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: MergeSemantics(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              RecipientAvatar(name: recipient.displayName),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      recipient.displayName,
                                      style: textTheme.titleSmall,
                                    ),
                                    Text(
                                      stageDetailLabel(l10n, plan, recipient),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    for (final note in notes)
                      Text(
                        note,
                        style: textTheme.bodySmall?.copyWith(
                          color: t.textMuted,
                        ),
                      ),
                  ],
                ),
        ),
        if (changed != null) ...[
          Gap.sm,
          Text(
            l10n.instructionDetailChanged(
              formatDateTime(context, changed, timezone: timezone),
            ),
            style: textTheme.bodySmall?.copyWith(color: t.textMuted),
          ),
        ],
        Gap.lg,
        AppButton.secondary(
          label: l10n.instructionEditAction,
          icon: Icons.edit_outlined,
          onPressed: busy ? null : () => unawaited(_edit()),
          expand: true,
        ),
        Gap.sm,
        AppButton.text(
          label: l10n.instructionDeleteAction,
          icon: Icons.delete_outline_rounded,
          onPressed: busy ? null : _delete,
          isLoading: _deleting,
          expand: true,
        ),
      ],
    );
  }
}

/// "Delete this instruction?" (USER_FLOWS §9: delete with confirmation).
class _DeleteSheet extends StatelessWidget {
  const _DeleteSheet();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        0,
        AppSpacing.page,
        AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeading(l10n.instructionDeleteTitle),
          Gap.sm,
          BodyText(l10n.instructionDeleteBody),
          Gap.lg,
          AppButton.primary(
            label: l10n.instructionDeleteConfirm,
            onPressed: () => Navigator.of(context).pop(true),
            expand: true,
          ),
          Gap.xs,
          AppButton.secondary(
            label: l10n.cancel,
            onPressed: () => Navigator.of(context).pop(false),
            expand: true,
          ),
        ],
      ),
    );
  }
}
