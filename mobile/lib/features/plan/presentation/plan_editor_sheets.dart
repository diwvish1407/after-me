import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/security/secure_screen.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../contacts/data/contacts_repository.dart';
import '../../contacts/presentation/contact_labels.dart';
import '../application/plan_editor_draft.dart';
import '../data/plan_repository.dart';
import 'plan_labels.dart';

/// One time on offer in the time sheet.
class PlanTimeChoice {
  const PlanTimeChoice(this.minutes, {this.enabled = true});

  final int minutes;

  /// False when the plan cannot use this time right now (another stage is too close, or
  /// the stage shares instructions); it is shown, but cannot be chosen.
  final bool enabled;
}

/// Asks how long after a missed check-in: the suggested times as choices and, when the
/// account has custom times, days, hours and minutes of its own. Returns the minutes, or
/// null when the person closed the sheet. [problemFor] is the app's mirror of the
/// server's rules for the time being entered.
Future<int?> showPlanTimeSheet(
  BuildContext context, {
  required String title,
  required List<PlanTimeChoice> choices,
  required PlanRules rules,
  required PlanIssueKind? Function(int minutes) problemFor,
  required bool allowCustom,
  int? initial,
}) => showModalBottomSheet<int>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => _TimeSheet(
    title: title,
    choices: choices,
    rules: rules,
    problemFor: problemFor,
    allowCustom: allowCustom,
    initial: initial,
  ),
);

class _TimeSheet extends StatefulWidget {
  const _TimeSheet({
    required this.title,
    required this.choices,
    required this.rules,
    required this.problemFor,
    required this.allowCustom,
    required this.initial,
  });

  final String title;
  final List<PlanTimeChoice> choices;
  final PlanRules rules;
  final PlanIssueKind? Function(int minutes) problemFor;
  final bool allowCustom;
  final int? initial;

  @override
  State<_TimeSheet> createState() => _TimeSheetState();
}

class _TimeSheetState extends State<_TimeSheet> {
  final _days = TextEditingController();
  final _hours = TextEditingController();
  final _minutes = TextEditingController();
  int? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initial;
  }

  @override
  void dispose() {
    _days.dispose();
    _hours.dispose();
    _minutes.dispose();
    super.dispose();
  }

  bool get _typing =>
      _days.text.isNotEmpty ||
      _hours.text.isNotEmpty ||
      _minutes.text.isNotEmpty;

  void _choose(int minutes) {
    setState(() {
      _selected = minutes;
      _days.clear();
      _hours.clear();
      _minutes.clear();
    });
  }

  void _typed() {
    final total =
        (int.tryParse(_days.text) ?? 0) * 1440 +
        (int.tryParse(_hours.text) ?? 0) * 60 +
        (int.tryParse(_minutes.text) ?? 0);
    setState(() => _selected = total > 0 ? total : null);
  }

  Widget _field(String label, TextEditingController controller) => AppTextField(
    label: label,
    controller: controller,
    keyboardType: TextInputType.number,
    inputFormatters: [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(5),
    ],
    textInputAction: TextInputAction.done,
    onChanged: (_) => _typed(),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final selected = _selected;
    final problem = selected == null ? null : widget.problemFor(selected);
    final someOff = widget.choices.any((c) => !c.enabled);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.page,
        0,
        AppSpacing.page,
        MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeading(widget.title),
          Gap.xs,
          BodyText(l10n.planTimeHelp),
          Gap.md,
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xxs,
            children: [
              for (final choice in widget.choices)
                ChoiceChip(
                  label: Text(formatDurationMinutes(l10n, choice.minutes)),
                  selected: !_typing && selected == choice.minutes,
                  onSelected: choice.enabled
                      ? (_) => _choose(choice.minutes)
                      : null,
                ),
            ],
          ),
          if (someOff) ...[Gap.sm, BodyText(l10n.planTimeUnavailable)],
          if (widget.allowCustom) ...[
            Gap.lg,
            Semantics(
              header: true,
              child: Text(
                l10n.planTimeCustom,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Gap.xs,
            // Side by side while the words fit; stacked at large text sizes, so a label
            // is never cut.
            if (MediaQuery.textScalerOf(context).scale(16) > 16 * 1.3) ...[
              _field(l10n.planTimeDays, _days),
              Gap.xs,
              _field(l10n.planTimeHours, _hours),
              Gap.xs,
              _field(l10n.planTimeMinutes, _minutes),
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _field(l10n.planTimeDays, _days)),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(child: _field(l10n.planTimeHours, _hours)),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(child: _field(l10n.planTimeMinutes, _minutes)),
                ],
              ),
          ],
          if (_typing && selected != null) ...[
            Gap.sm,
            Semantics(
              liveRegion: true,
              child: BodyText(
                l10n.planTimeTotal(formatDurationMinutes(l10n, selected)),
              ),
            ),
          ],
          if (problem != null) ...[
            Gap.sm,
            Semantics(
              liveRegion: true,
              child: Text(
                planIssueText(l10n, problem, widget.rules),
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
          Gap.lg,
          AppButton.primary(
            label: l10n.planTimeUse,
            onPressed: selected == null || problem != null
                ? null
                : () => Navigator.of(context).pop(selected),
            expand: true,
          ),
          Gap.xs,
          AppButton.text(
            label: l10n.cancel,
            onPressed: () => Navigator.of(context).pop(),
            expand: true,
          ),
        ],
      ),
    );
  }
}

/// Asks who is told at stage [position]: every trusted contact with a tick, and a plain
/// line for those who have not accepted. Returns the chosen ids, or null when the person
/// closed the sheet.
Future<List<String>?> showPlanContactsSheet(
  BuildContext context, {
  required int position,
  required List<TrustedContact> contacts,
  required List<String> selected,
}) => showModalBottomSheet<List<String>>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => _ContactsSheet(
    position: position,
    contacts: contacts,
    selected: selected,
  ),
);

class _ContactsSheet extends StatefulWidget {
  const _ContactsSheet({
    required this.position,
    required this.contacts,
    required this.selected,
  });

  final int position;
  final List<TrustedContact> contacts;
  final List<String> selected;

  @override
  State<_ContactsSheet> createState() => _ContactsSheetState();
}

class _ContactsSheetState extends State<_ContactsSheet> {
  late final Set<String> _chosen = widget.selected.toSet();

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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeading(l10n.planWhoTitle(widget.position)),
          Gap.sm,
          if (widget.contacts.isEmpty) ...[
            BodyText(l10n.planWhoNone),
            Gap.md,
            AppButton.primary(
              label: l10n.planAddContact,
              onPressed: () {
                final router = GoRouter.of(context);
                Navigator.of(context).pop();
                router.push(AppRoutes.peopleAdd);
              },
              expand: true,
            ),
          ] else ...[
            for (final contact in widget.contacts)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _chosen.contains(contact.id),
                title: Text(contact.displayName),
                subtitle: Text(
                  statusExplanation(l10n, contact.verificationStatus),
                ),
                onChanged: (on) => setState(() {
                  if (on ?? false) {
                    _chosen.add(contact.id);
                  } else {
                    _chosen.remove(contact.id);
                  }
                }),
              ),
            Gap.md,
            AppButton.primary(
              label: l10n.planWhoUse,
              onPressed: () => Navigator.of(context).pop([
                for (final contact in widget.contacts)
                  if (_chosen.contains(contact.id)) contact.id,
              ]),
              expand: true,
            ),
          ],
          Gap.xs,
          AppButton.text(
            label: l10n.cancel,
            onPressed: () => Navigator.of(context).pop(),
            expand: true,
          ),
        ],
      ),
    );
  }
}

/// Explains why stage [position] cannot be removed: instructions are set to be shared at
/// it. [titles] are the instructions the person's own list names (content, so the window
/// is secure while they are shown); [count] is how many the server says.
Future<void> showStageInUseSheet(
  BuildContext context, {
  required int position,
  required int count,
  required List<String> titles,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) =>
      _StageInUseSheet(position: position, count: count, titles: titles),
);

class _StageInUseSheet extends StatelessWidget {
  const _StageInUseSheet({
    required this.position,
    required this.count,
    required this.titles,
  });

  final int position;
  final int count;
  final List<String> titles;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SecureScreen(
      enabled: titles.isNotEmpty,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          0,
          AppSpacing.page,
          AppSpacing.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeading(l10n.planInUseTitle(position)),
            Gap.sm,
            Text(
              l10n.planInUseBody(count),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (titles.isNotEmpty) ...[
              Gap.xs,
              for (final title in titles)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
            ],
            Gap.sm,
            BodyText(l10n.planInUseHow),
            Gap.lg,
            AppButton.primary(
              label: l10n.actionClose,
              onPressed: () => Navigator.of(context).pop(),
              expand: true,
            ),
          ],
        ),
      ),
    );
  }
}
