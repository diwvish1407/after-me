import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/models/api_problem.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/forms/validators.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../../contacts/application/contacts_controller.dart';
import '../../contacts/data/contacts_repository.dart';
import '../../plan/application/plan_controller.dart';
import '../../plan/data/plan_repository.dart';
import '../application/instruction_autosave.dart';
import '../application/instructions_controller.dart';
import '../application/release_options.dart';
import '../data/instructions_repository.dart';
import 'instruction_labels.dart';
import 'instruction_limit_sheet.dart';
import 'instruction_starter_cards.dart';
import 'instruction_starters.dart';

/// What the person entered in [InstructionForm]: validated on the device (the server
/// validates again). The title and the body are content: this never prints them.
///
/// [recipients] says for each person the stage they receive it at, or a time the plan has
/// no stage for yet: the save adds that stage to the plan first
/// (`InstructionsController.addInstructionWithTimes`).
@immutable
class InstructionFormValues {
  const InstructionFormValues({
    required this.category,
    required this.title,
    required this.body,
    required this.recipients,
  });

  final InstructionCategory category;
  final String title;
  final String body;
  final List<RecipientChoice> recipients;

  /// Some person's time is one the plan has no stage for yet.
  bool get hasNewTimes => recipients.any((r) => r.isNew);

  @override
  String toString() => 'InstructionFormValues(<redacted>)';
}

/// The fields of [instruction] that [values] changes: only those, because an empty update
/// is refused by the server. The patch is empty when nothing but (maybe) the recipients
/// changed; see [instructionRecipientsChanged].
InstructionPatch instructionFieldChanges(
  Instruction instruction,
  InstructionFormValues values,
) => InstructionPatch(
  category: values.category == instruction.category ? null : values.category,
  title: values.title.trim() == instruction.title ? null : values.title,
  body: values.body.trim() == instruction.body.trim() ? null : values.body,
);

/// Whether [values] changes who receives [instruction] or when. A time the plan has no
/// stage for yet is always a change.
bool instructionRecipientsChanged(
  Instruction instruction,
  InstructionFormValues values,
) {
  if (values.hasNewTimes) {
    return true;
  }
  final before = {
    for (final r in instruction.recipients)
      RecipientChoice.stage(contactId: r.contactId, stageId: r.releaseStageId),
  };
  return !setEquals(before, values.recipients.toSet());
}

/// Why the password may be asked for when [values] is saved: nothing when nobody is
/// chosen (the server never asks then), a time the plan has no stage for yet when one is
/// chosen (the plan changes too), otherwise who receives it.
ReauthReason? instructionSaveReason(InstructionFormValues values) {
  if (values.recipients.isEmpty) {
    return null;
  }
  return values.hasNewTimes
      ? ReauthReason.instructionNewTime
      : ReauthReason.instructionRecipients;
}

/// The fields for writing or editing an instruction (USER_FLOWS §9), shared by the
/// Instructions tab's Add and Edit screens and onboarding step 7: category, title, text,
/// who receives it and when, and the primary action.
///
/// * **Digital Accounts** shows the guidance to say where a password can be found, never
///   to paste it (FR-INS-07).
/// * **Who receives this?** lists the trusted contacts; one who has not accepted yet is
///   allowed, with a gentle note. **When?** offers the plan's stages that run at least
///   24 hours after a missed check-in and, besides them, the tier's times of 1, 2 and 3
///   days that the plan has no stage for yet: choosing one adds that stage to the plan
///   when the instruction is saved. When nothing qualifies (the plan has no stage to
///   follow, or no room for another) it says so and offers to review the plan, and the
///   instruction can still be saved without recipients.
/// * What is typed is kept in memory only ([InstructionAutosave]) so that leaving the
///   form and coming back loses nothing; it is never stored.
///
/// [onSubmit] performs the save and throws an `AppFailure` when it fails. It answers
/// `true` once the instruction is saved and `false` when the person closed the password
/// sheet (check-ins are on and the change decides who sees it, SECURITY.md §7): nothing
/// was saved, nothing is said, and what was typed stays. The form maps what the server
/// said back onto the fields, opens the limit sheet for `plan_limit_reached`, and shows
/// any other failure in a calm notice. It does not navigate: the caller does, after
/// [onSubmit] returns.
class InstructionForm extends ConsumerStatefulWidget {
  const InstructionForm({
    required this.submitLabel,
    required this.onSubmit,
    required this.onAddContact,
    required this.onReviewPlan,
    this.initial,
    this.starter,
    this.suggestedRecipientIds = const <String>{},
    super.key,
  });

  final String submitLabel;
  final Future<bool> Function(InstructionFormValues values) onSubmit;

  /// Opens the way to add a trusted contact (the form is left as it is).
  final VoidCallback onAddContact;

  /// Opens the plan, where a stage that is late enough can be set up.
  final VoidCallback onReviewPlan;

  /// The instruction being edited, or null when writing a new one.
  final Instruction? initial;

  /// An example to start from. Takes the place of a draft that was kept.
  final InstructionStarter? starter;

  /// Contacts ticked for a new instruction (onboarding ticks the one just added).
  final Set<String> suggestedRecipientIds;

  @override
  ConsumerState<InstructionForm> createState() => _InstructionFormState();
}

class _InstructionFormState extends ConsumerState<InstructionForm> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  late final InstructionAutosaveController _autosave;

  InstructionCategory? _category;

  /// The ticked contacts and the time chosen for each (null until chosen): the id of a
  /// stage, or `new:<minutes>` for a time the plan has no stage for yet.
  final Map<String, String?> _stageByContact = {};

  /// The time chosen for everybody, and handed to people as they are ticked.
  String? _sameStage;
  bool _perPerson = false;

  bool _initialised = false;
  bool _restored = false;
  bool _busy = false;
  AppFailure? _failure;
  bool _categoryMissing = false;
  FieldIssue? _titleIssue;
  FieldIssue? _bodyIssue;
  bool _stageMissing = false;

  /// The plan got a new stage and the instruction was then refused: said plainly.
  bool _stageKept = false;

  /// The stage limit that was hit is the free plan's.
  bool _freePlan = false;
  String? _categoryServerText;
  String? _recipientsServerText;

  @override
  void initState() {
    super.initState();
    _autosave = ref.read(instructionAutosaveProvider.notifier);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialised) {
      _initialised = true;
      _initialise(AppLocalizations.of(context));
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  // --- the starting point --------------------------------------------------------------

  void _initialise(AppLocalizations l10n) {
    final initial = widget.initial;
    final starter = widget.starter;
    final saved = ref.read(instructionAutosaveProvider);
    if (starter != null) {
      _applyStarter(l10n, starter);
      _suggest();
      // Not while the tree is building: a provider may not change then.
      unawaited(
        Future<void>.microtask(() {
          if (mounted) {
            _persist();
          }
        }),
      );
    } else if (saved != null && saved.editingId == initial?.id) {
      _restored = true;
      _category = saved.category;
      _title.text = saved.title;
      _body.text = saved.body;
      _stageByContact.addAll(saved.stageByContact);
      _perPerson = saved.perPerson;
      _sameStage = saved.stageByContact.values.whereType<String>().firstOrNull;
    } else if (initial != null) {
      _category = initial.category;
      _title.text = initial.title;
      _body.text = initial.body;
      for (final r in initial.recipients) {
        _stageByContact[r.contactId] = r.releaseStageId;
      }
      final stages = {for (final r in initial.recipients) r.releaseStageId};
      _perPerson = stages.length > 1;
      _sameStage = stages.firstOrNull;
    } else {
      _suggest();
    }
  }

  void _suggest() {
    // With no time to choose nobody can be chosen yet.
    if (releaseOptions(ref.read(planControllerProvider).value).isEmpty) {
      return;
    }
    for (final id in widget.suggestedRecipientIds) {
      _stageByContact.putIfAbsent(id, () => _sameStage);
    }
  }

  void _applyStarter(AppLocalizations l10n, InstructionStarter starter) {
    final text = starterText(l10n, starter);
    _category = starter.category;
    _title.text = text.title;
    _body.text = text.body;
    _titleIssue = null;
    _bodyIssue = null;
    _categoryMissing = false;
  }

  /// Keeps what is typed in memory (never on the device).
  void _persist() {
    _autosave.save(
      InstructionAutosave(
        editingId: widget.initial?.id,
        category: _category,
        title: _title.text,
        body: _body.text,
        stageByContact: Map.of(_stageByContact),
        perPerson: _perPerson,
      ),
    );
  }

  void _startOver() {
    _autosave.clear();
    final initial = widget.initial;
    setState(() {
      _restored = false;
      _stageByContact.clear();
      _sameStage = null;
      _perPerson = false;
      _category = initial?.category;
      _title.text = initial?.title ?? '';
      _body.text = initial?.body ?? '';
      if (initial != null) {
        for (final r in initial.recipients) {
          _stageByContact[r.contactId] = r.releaseStageId;
        }
        final stages = {for (final r in initial.recipients) r.releaseStageId};
        _perPerson = stages.length > 1;
        _sameStage = stages.firstOrNull;
      } else {
        _suggest();
      }
      _titleIssue = null;
      _bodyIssue = null;
      _categoryMissing = false;
      _stageMissing = false;
      _failure = null;
    });
  }

  // --- choices -------------------------------------------------------------------------

  /// The time of [contactId] as the plan has it now: the one chosen (a time that became
  /// a stage meanwhile is that stage), or the only one the plan offers.
  String? _stageOf(String contactId, List<ReleaseOption> options, Plan? plan) {
    final chosen = _stageByContact[contactId];
    if (chosen != null) {
      return normaliseReleaseKey(plan, chosen);
    }
    return options.length == 1 ? options.single.key : null;
  }

  void _tick(String contactId, {required bool on}) {
    setState(() {
      if (on) {
        _stageByContact[contactId] = _sameStage;
      } else {
        _stageByContact.remove(contactId);
      }
      _stageMissing = false;
      _recipientsServerText = null;
    });
    _persist();
  }

  void _chooseSame(String stageId) {
    setState(() {
      _sameStage = stageId;
      for (final id in _stageByContact.keys.toList()) {
        _stageByContact[id] = stageId;
      }
      _stageMissing = false;
      _recipientsServerText = null;
    });
    _persist();
  }

  void _choosePerson(String contactId, String stageId) {
    setState(() {
      _stageByContact[contactId] = stageId;
      _sameStage = stageId;
      _stageMissing = false;
      _recipientsServerText = null;
    });
    _persist();
  }

  void _setPerPerson({required bool on}) {
    setState(() {
      _perPerson = on;
      if (!on) {
        // One time for everybody: the first person's time is kept.
        final first = _stageByContact.values.whereType<String>().firstOrNull;
        _sameStage = first ?? _sameStage;
        for (final id in _stageByContact.keys.toList()) {
          _stageByContact[id] = _sameStage;
        }
      }
    });
    _persist();
  }

  Future<void> _pickStarter() async {
    final l10n = AppLocalizations.of(context);
    final starter = await showStarterSheet(context, category: _category);
    if (starter != null && mounted) {
      setState(() => _applyStarter(l10n, starter));
      _persist();
    }
  }

  // --- saving --------------------------------------------------------------------------

  Future<void> _submit() async {
    final plan = ref.read(planControllerProvider).value;
    final options = releaseOptions(plan);
    final people = ref.read(contactsControllerProvider).value ?? const [];
    final selected = [
      for (final contact in people)
        if (_stageByContact.containsKey(contact.id)) contact,
    ];
    final titleIssue = Validators.instructionTitle(_title.text);
    final bodyIssue = Validators.instructionBody(_body.text);
    final category = _category;
    final stageMissing = selected.any(
      (c) => _stageOf(c.id, options, plan) == null,
    );
    setState(() {
      _titleIssue = titleIssue;
      _bodyIssue = bodyIssue;
      _categoryMissing = category == null;
      _stageMissing = stageMissing;
      _failure = null;
      _stageKept = false;
      _categoryServerText = null;
      _recipientsServerText = null;
    });
    if (titleIssue != null ||
        bodyIssue != null ||
        category == null ||
        stageMissing) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    // Taken before the save: the caller may leave this screen as soon as it succeeds.
    final autosave = _autosave;
    try {
      final saved = await widget.onSubmit(
        InstructionFormValues(
          category: category,
          title: _title.text.trim(),
          body: _body.text,
          recipients: [
            for (final contact in selected)
              _choice(contact.id, _stageOf(contact.id, options, plan)!),
          ],
        ),
      );
      if (saved) {
        autosave.clear();
      }
      if (mounted) {
        setState(() => _busy = false);
      }
    } on StageAddedButNotSaved catch (kept) {
      // The plan has the new time now; the instruction was refused. Say so, keep the
      // draft, and show what the server said about the instruction.
      if (mounted) {
        _showFailure(kept.failure, stageKept: true);
      }
    } on AppFailure catch (failure) {
      if (mounted) {
        _showFailure(failure);
      }
    }
  }

  /// [key] (a stage id or `new:<minutes>`) as a recipient's choice.
  RecipientChoice _choice(String contactId, String key) {
    final offset = ReleaseOption.offsetOfKey(key);
    return offset == null
        ? RecipientChoice.stage(contactId: contactId, stageId: key)
        : RecipientChoice.newTime(contactId: contactId, offsetMinutes: offset);
  }

  void _showFailure(AppFailure failure, {bool stageKept = false}) {
    final l10n = AppLocalizations.of(context);
    var general = true;
    FieldIssue? title;
    FieldIssue? body;
    String? category;
    String? recipients;
    var freePlan = false;
    switch (failure) {
      case PlanLimitFailure(resource: 'instructions'):
        general = false;
        final entitlements = ref.read(entitlementsProvider).value;
        ref.invalidate(entitlementsProvider);
        unawaited(
          showInstructionLimitSheet(
            context,
            limit: failure.limit ?? entitlements?.limits.instructions,
            free:
                entitlements?.isFree ??
                (failure.limit ?? freeInstructionLimit) <= freeInstructionLimit,
          ),
        );
      case PlanLimitFailure(resource: 'stages'):
        freePlan =
            ref.read(entitlementsProvider).value?.isFree ??
            (failure.limit ?? 2) <= 2;
      case ValidationFailure(:final fieldErrors) when fieldErrors.isNotEmpty:
        title = _fieldIssue(fieldErrors, 'title', FieldIssue.textInvalid);
        body = _fieldIssue(fieldErrors, 'body', FieldIssue.textInvalid);
        if (fieldErrors.any((e) => e.field == 'category')) {
          category = l10n.instructionCategoryUnknown;
        }
        recipients = _recipientsText(l10n, fieldErrors);
        general =
            title == null &&
            body == null &&
            category == null &&
            recipients == null;
      default:
    }
    setState(() {
      _busy = false;
      _freePlan = freePlan;
      _stageKept = stageKept;
      _failure = general ? failure : null;
      _titleIssue = title;
      _bodyIssue = body;
      _categoryServerText = category;
      _recipientsServerText = recipients;
    });
  }

  FieldIssue? _fieldIssue(
    List<ApiFieldError> errors,
    String field,
    FieldIssue fallback,
  ) =>
      issueForField(errors, field) ??
      (errors.any((e) => e.field == field) ? fallback : null);

  /// What the server said about the people or their times, in the app's words.
  String? _recipientsText(AppLocalizations l10n, List<ApiFieldError> errors) {
    final plan = ref.read(planControllerProvider).value;
    for (final error in errors) {
      if (!error.field.startsWith('recipients')) {
        continue;
      }
      return switch (error.code) {
        'release_stage_too_early' => l10n.instructionErrorStageTooEarly(
          formatDurationMinutes(l10n, plan?.rules.releaseOffsetMin ?? 1440),
        ),
        'duplicate_recipient' => l10n.instructionErrorDuplicate,
        _ => l10n.errorValidation,
      };
    }
    return null;
  }

  // --- building ------------------------------------------------------------------------

  String? _issueText(AppLocalizations l10n, FieldIssue? issue) =>
      issue == null ? null : issueMessage(l10n, issue);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final categories =
        ref.watch(instructionCategoriesProvider).value ??
        InstructionCategory.values;
    final count = _body.text.replaceAll('\r\n', '\n').runes.length;
    final creating = widget.initial == null;
    final blank = _title.text.trim().isEmpty && _body.text.trim().isEmpty;
    final digital = _category == InstructionCategory.digitalAccounts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_stageKept) ...[
          Semantics(
            liveRegion: true,
            container: true,
            child: StatusBanner(
              kind: StatusBannerKind.attention,
              message: l10n.instructionStageKept,
            ),
          ),
          Gap.md,
        ],
        if (_failure != null) ...[
          FailureNotice(
            message: instructionFailureMessage(
              l10n,
              _failure!,
              freePlan: _freePlan,
            ),
          ),
          Gap.md,
        ],
        if (_restored) ...[
          Row(
            children: [
              Expanded(child: BodyText(l10n.instructionDraftKept)),
              AppButton.text(
                label: l10n.instructionStartOver,
                onPressed: _busy ? null : _startOver,
              ),
            ],
          ),
          Gap.sm,
        ],
        if (creating && blank) ...[
          AppButton.secondary(
            label: l10n.instructionStartFromExample,
            icon: Icons.lightbulb_outline_rounded,
            onPressed: _busy ? null : _pickStarter,
            expand: true,
          ),
          Gap.md,
        ],
        Semantics(
          header: true,
          child: Text(
            l10n.instructionCategoryHeading,
            style: textTheme.titleSmall,
          ),
        ),
        Gap.xs,
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xxs,
          children: [
            for (final category in categories)
              ChoiceChip(
                label: Text(categoryName(l10n, category)),
                selected: _category == category,
                onSelected: _busy
                    ? null
                    : (_) {
                        setState(() {
                          _category = category;
                          _categoryMissing = false;
                          _categoryServerText = null;
                        });
                        _persist();
                      },
              ),
          ],
        ),
        if (_categoryMissing || _categoryServerText != null) ...[
          Gap.xs,
          Semantics(
            liveRegion: true,
            child: Text(
              _categoryServerText ?? l10n.instructionCategoryRequired,
              style: textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        ],
        if (digital) ...[
          Gap.md,
          Semantics(
            container: true,
            child: StatusBanner(
              kind: StatusBannerKind.info,
              message: l10n.instructionDigitalGuidance,
            ),
          ),
        ],
        Gap.md,
        AppTextField(
          label: l10n.fieldInstructionTitle,
          controller: _title,
          errorText: _issueText(l10n, _titleIssue),
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.sentences,
          enableIMEPersonalizedLearning: false,
          enabled: !_busy,
          onChanged: (_) {
            setState(() => _titleIssue = null);
            _persist();
          },
        ),
        Gap.md,
        TextField(
          controller: _body,
          enabled: !_busy,
          minLines: 6,
          maxLines: 14,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          textCapitalization: TextCapitalization.sentences,
          // What is written here must not feed the keyboard's personal dictionary.
          enableIMEPersonalizedLearning: false,
          decoration: InputDecoration(
            labelText: l10n.fieldInstructionBody,
            alignLabelWithHint: true,
            errorText: _issueText(l10n, _bodyIssue),
          ),
          onChanged: (_) {
            setState(() => _bodyIssue = null);
            _persist();
          },
        ),
        // Under the field, not in its decoration: next to an error the decoration's own
        // counter leaves the error no room at large text sizes.
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xxs),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Text(
              l10n.instructionBodyCounter(count, Validators.instructionBodyMax),
              style: textTheme.bodySmall?.copyWith(
                color: context.tokens.textMuted,
              ),
            ),
          ),
        ),
        // The Digital Accounts guidance above says it in full; elsewhere a short note.
        if (!digital) ...[Gap.sm, BodyText(l10n.instructionPasswordNote)],
        Gap.lg,
        ..._recipientsSection(context, l10n),
        Gap.lg,
        AppButton.primary(
          label: widget.submitLabel,
          onPressed: _submit,
          isLoading: _busy,
          expand: true,
        ),
      ],
    );
  }

  List<Widget> _recipientsSection(BuildContext context, AppLocalizations l10n) {
    final textTheme = Theme.of(context).textTheme;
    final planState = ref.watch(planControllerProvider);
    final plan = planState.value;
    final people = ref.watch(contactsControllerProvider).value ?? const [];
    final options = releaseOptions(plan);
    final hasStage = options.any((o) => !o.isNew);
    final selected = [
      for (final contact in people)
        if (_stageByContact.containsKey(contact.id)) contact,
    ];
    final heading = Semantics(
      header: true,
      child: Text(l10n.instructionWho, style: textTheme.titleSmall),
    );
    if (people.isEmpty) {
      return [
        heading,
        Gap.xs,
        BodyText(l10n.instructionNoContact),
        Gap.sm,
        AppButton.secondary(
          label: l10n.instructionAddContact,
          onPressed: _busy ? null : widget.onAddContact,
          expand: true,
        ),
      ];
    }
    if (plan == null) {
      return [
        heading,
        Gap.xs,
        if (planState.hasError)
          ErrorView(
            failure: planState.error is AppFailure
                ? planState.error! as AppFailure
                : UnknownFailure(cause: planState.error),
            onRetry: () =>
                unawaited(ref.read(planControllerProvider.notifier).reload()),
          )
        else
          const LoadingView(),
      ];
    }
    if (options.isEmpty && selected.isEmpty) {
      // Nothing can be shared yet: say why, and how to fix it. The instruction can still
      // be saved.
      return [
        heading,
        Gap.xs,
        Semantics(
          container: true,
          child: StatusBanner(
            kind: StatusBannerKind.info,
            message: l10n.instructionNoStage(
              formatDurationMinutes(l10n, plan.rules.releaseOffsetMin),
            ),
            action: AppButton.text(
              label: l10n.checklistPlan,
              onPressed: _busy ? null : widget.onReviewPlan,
            ),
          ),
        ),
      ];
    }
    final sameStage = selected.isEmpty
        ? (_sameStage == null ? null : normaliseReleaseKey(plan, _sameStage!))
        : selected.map((c) => _stageOf(c.id, options, plan)).toSet().length == 1
        ? _stageOf(selected.first.id, options, plan)
        : null;
    final choosesNewTime = selected.any(
      (c) =>
          ReleaseOption.offsetOfKey(_stageOf(c.id, options, plan) ?? '') !=
          null,
    );
    return [
      heading,
      for (final contact in people)
        _recipientTile(context, l10n, contact, selected: _isSelected(contact)),
      if (selected.isEmpty) ...[Gap.xs, BodyText(l10n.instructionNobodyChosen)],
      if (_recipientsServerText != null) ...[
        Gap.xs,
        Semantics(
          liveRegion: true,
          child: Text(
            _recipientsServerText!,
            style: textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      ],
      Gap.lg,
      Semantics(
        header: true,
        child: Text(l10n.instructionWhen, style: textTheme.titleSmall),
      ),
      Gap.xs,
      if (_perPerson && selected.isNotEmpty) ...[
        for (final contact in selected) ...[
          Text(
            l10n.instructionWhenFor(contact.displayName),
            style: textTheme.titleSmall,
          ),
          _StageChoices(
            options: options,
            value: _stageOf(contact.id, options, plan),
            enabled: !_busy,
            onChanged: (id) => _choosePerson(contact.id, id),
          ),
        ],
        AppButton.text(
          label: l10n.instructionSameTime,
          onPressed: _busy ? null : () => _setPerPerson(on: false),
          expand: true,
        ),
      ] else ...[
        if (options.isEmpty)
          BodyText(
            l10n.instructionNoStage(
              formatDurationMinutes(l10n, plan.rules.releaseOffsetMin),
            ),
          )
        else
          _StageChoices(
            options: options,
            value: sameStage,
            enabled: !_busy,
            onChanged: _chooseSame,
          ),
        if (selected.length > 1)
          AppButton.text(
            label: l10n.instructionPerPerson,
            onPressed: _busy ? null : () => _setPerPerson(on: true),
            expand: true,
          ),
      ],
      // A time the plan has no stage for yet is added to it when this is saved: say so,
      // and that the people chosen for it are told then too.
      if (choosesNewTime || (options.isNotEmpty && !hasStage)) ...[
        Gap.xs,
        Semantics(
          container: true,
          child: BodyText(
            choosesNewTime
                ? l10n.instructionNewTimeChosen
                : l10n.instructionNewTimeNone,
          ),
        ),
      ],
      if (_stageMissing) ...[
        Gap.xs,
        Semantics(
          liveRegion: true,
          child: Text(
            l10n.instructionWhenRequired,
            style: textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      ],
      if (options.isEmpty) ...[
        Gap.sm,
        AppButton.text(
          label: l10n.checklistPlan,
          onPressed: _busy ? null : widget.onReviewPlan,
          expand: true,
        ),
      ],
    ];
  }

  bool _isSelected(TrustedContact contact) =>
      _stageByContact.containsKey(contact.id);

  Widget _recipientTile(
    BuildContext context,
    AppLocalizations l10n,
    TrustedContact contact, {
    required bool selected,
  }) {
    final note = contact.isAccepted
        ? null
        : contact.isUnreachable
        ? l10n.instructionRecipientUnreachable(contact.displayName)
        : l10n.instructionRecipientPending(1, contact.displayName);
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: selected,
      title: Text(contact.displayName),
      subtitle: note == null ? null : Text(note),
      onChanged: _busy
          ? null
          : (value) => _tick(contact.id, on: value ?? false),
    );
  }
}

/// The times an instruction can be released at, as one choice each, worded as "If you
/// haven't checked in for 2 days": the plan's stages and the times it has no stage for yet
/// look the same.
class _StageChoices extends StatelessWidget {
  const _StageChoices({
    required this.options,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final List<ReleaseOption> options;
  final String? value;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return RadioGroup<String>(
      groupValue: value,
      onChanged: (key) {
        if (key != null && enabled) {
          onChanged(key);
        }
      },
      child: Column(
        children: [
          for (final option in options)
            RadioListTile<String>(
              contentPadding: EdgeInsets.zero,
              value: option.key,
              title: Text(
                l10n.instructionReleaseAfter(
                  formatDurationMinutes(l10n, option.offsetMinutes),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
