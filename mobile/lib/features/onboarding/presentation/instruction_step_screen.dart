import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/forms/validators.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../instructions/data/instructions_repository.dart';
import '../application/onboarding_controller.dart';
import '../application/setup_controller.dart';
import 'instruction_templates.dart';
import 'onboarding_scaffold.dart';

/// Release delays offered for the first instruction, in hours (at least 24).
const List<int> instructionReleaseChoicesHours = [24, 48, 72];

/// Step 7 (optional): pick a starter template and write the first instruction.
class InstructionStepScreen extends ConsumerStatefulWidget {
  const InstructionStepScreen({super.key});

  @override
  ConsumerState<InstructionStepScreen> createState() =>
      _InstructionStepScreenState();
}

class _InstructionStepScreenState extends ConsumerState<InstructionStepScreen> {
  InstructionTemplate? _template;
  final _title = TextEditingController();
  final _body = TextEditingController();
  int _hours = 48;
  Set<String>? _recipients;
  bool _busy = false;
  AppFailure? _failure;
  FieldIssue? _titleIssue;
  bool _bodyEmpty = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _choose(InstructionTemplate template, AppLocalizations l10n) {
    final text = templateText(l10n, template);
    setState(() {
      _template = template;
      _title.text = text.title;
      _body.text = text.starter;
      _titleIssue = null;
      _bodyEmpty = false;
      _failure = null;
    });
  }

  Future<void> _save(SetupState setup) async {
    final recipients = _recipients ?? {for (final c in setup.contacts) c.id};
    final title = _title.text.trim();
    setState(() {
      _titleIssue = title.isEmpty ? FieldIssue.required : null;
      _bodyEmpty = _body.text.trim().isEmpty;
      _failure = null;
    });
    if (title.isEmpty || _body.text.trim().isEmpty || recipients.isEmpty) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      await ref
          .read(setupControllerProvider.notifier)
          .createInstruction(
            InstructionDraft(
              title: title,
              body: _body.text,
              releaseAfterHours: _hours,
              recipientContactIds: recipients.toList(),
              template: _template,
            ),
          );
      if (mounted) {
        await advanceFrom(context, ref, OnboardingStep.instruction);
      }
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failure = failure;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final setup =
        ref.watch(setupControllerProvider).value ?? const SetupState();
    if (setup.instructions.isNotEmpty) {
      return OnboardingScaffold(
        step: OnboardingStep.instruction,
        title: l10n.instructionStepTitle,
        subtitle: l10n.instructionStepSaved(setup.instructions.first.title),
        primaryLabel: l10n.actionContinue,
        onPrimary: () => advanceFrom(context, ref, OnboardingStep.instruction),
        children: const [],
      );
    }
    final template = _template;
    if (template == null) {
      return OnboardingScaffold(
        step: OnboardingStep.instruction,
        title: l10n.instructionStepTitle,
        subtitle: l10n.instructionStepBody,
        secondaryLabel: l10n.actionSkipForNow,
        onSecondary: () =>
            advanceFrom(context, ref, OnboardingStep.instruction),
        children: [
          for (final value in InstructionTemplate.values)
            _TemplateCard(
              text: templateText(l10n, value),
              onTap: () => _choose(value, l10n),
            ),
          BodyText(l10n.instructionPasswordNote),
        ],
      );
    }
    final selected = _recipients ?? {for (final c in setup.contacts) c.id};
    return OnboardingScaffold(
      step: OnboardingStep.instruction,
      title: templateText(l10n, template).title,
      subtitle: l10n.instructionWriteBody,
      primaryLabel: l10n.instructionSave,
      primaryBusy: _busy,
      onPrimary: setup.hasContact ? () => _save(setup) : null,
      secondaryLabel: l10n.actionSkipForNow,
      onSecondary: () => advanceFrom(context, ref, OnboardingStep.instruction),
      children: [
        if (_failure != null) ...[FailureNotice.of(context, _failure!), Gap.md],
        AppTextField(
          label: l10n.fieldInstructionTitle,
          controller: _title,
          errorText: _titleIssue == null
              ? null
              : issueMessage(l10n, _titleIssue!),
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.sentences,
          enabled: !_busy,
          onChanged: (_) => setState(() => _titleIssue = null),
        ),
        Gap.md,
        TextField(
          controller: _body,
          enabled: !_busy,
          minLines: 5,
          maxLines: 12,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: l10n.fieldInstructionBody,
            alignLabelWithHint: true,
            errorText: _bodyEmpty ? l10n.fieldRequired : null,
          ),
          onChanged: (_) => setState(() => _bodyEmpty = false),
        ),
        Gap.sm,
        BodyText(l10n.instructionPasswordNote),
        Gap.lg,
        Semantics(
          header: true,
          child: Text(
            l10n.instructionWho,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        if (!setup.hasContact)
          BodyText(l10n.instructionNoContact)
        else
          for (final contact in setup.contacts)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: selected.contains(contact.id),
              title: Text(contact.displayName),
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      final next = {...selected};
                      value ?? false
                          ? next.add(contact.id)
                          : next.remove(contact.id);
                      _recipients = next;
                    }),
            ),
        if (setup.hasContact && selected.isEmpty)
          Text(
            l10n.instructionPickRecipient,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: context.tokens.escalation),
          ),
        Gap.md,
        Semantics(
          header: true,
          child: Text(
            l10n.instructionWhen,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        RadioGroup<int>(
          groupValue: _hours,
          onChanged: (value) {
            if (value != null && !_busy) {
              setState(() => _hours = value);
            }
          },
          child: Column(
            children: [
              for (final hours in instructionReleaseChoicesHours)
                RadioListTile<int>(
                  contentPadding: EdgeInsets.zero,
                  value: hours,
                  title: Text(l10n.instructionReleaseAfterDays(hours ~/ 24)),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        AppButton.text(
          label: l10n.instructionChooseAnother,
          onPressed: _busy ? null : () => setState(() => _template = null),
          expand: true,
        ),
      ],
    );
  }
}

class _TemplateCard extends StatelessWidget {
  const _TemplateCard({required this.text, required this.onTap});

  final TemplateText text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          minTileHeight: 64,
          title: Text(text.title),
          subtitle: Text(text.description),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        ),
      ),
    );
  }
}
