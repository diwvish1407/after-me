import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';

/// Asks for a time of the person's own: suggested [choices] as chips, and days, hours
/// and minutes fields. Returns the minutes, or null when the sheet was closed. A value
/// outside [min]..[max] cannot be used.
Future<int?> showCustomMinutesSheet(
  BuildContext context, {
  required String title,
  required String help,
  required List<int> choices,
  required int min,
  required int max,
  int? initial,
}) => showModalBottomSheet<int>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => _CustomMinutesSheet(
    title: title,
    help: help,
    choices: choices,
    min: min,
    max: max,
    initial: initial,
  ),
);

class _CustomMinutesSheet extends StatefulWidget {
  const _CustomMinutesSheet({
    required this.title,
    required this.help,
    required this.choices,
    required this.min,
    required this.max,
    required this.initial,
  });

  final String title;
  final String help;
  final List<int> choices;
  final int min;
  final int max;
  final int? initial;

  @override
  State<_CustomMinutesSheet> createState() => _CustomMinutesSheetState();
}

class _CustomMinutesSheetState extends State<_CustomMinutesSheet> {
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
    final String? problem;
    if (selected == null) {
      problem = null;
    } else if (selected > widget.max) {
      problem = l10n.customTimeTooLong(formatDurationMinutes(l10n, widget.max));
    } else if (selected < widget.min) {
      problem = l10n.customTimeTooShort(
        formatDurationMinutes(l10n, widget.min),
      );
    } else {
      problem = null;
    }
    final stacked = MediaQuery.textScalerOf(context).scale(16) > 16 * 1.3;
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
          BodyText(widget.help),
          Gap.md,
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xxs,
            children: [
              for (final minutes in widget.choices)
                ChoiceChip(
                  label: Text(formatDurationMinutes(l10n, minutes)),
                  selected: !_typing && selected == minutes,
                  onSelected: (_) => _choose(minutes),
                ),
            ],
          ),
          Gap.lg,
          Semantics(
            header: true,
            child: Text(
              l10n.planTimeCustom,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Gap.xs,
          if (stacked) ...[
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
          if (_typing && selected != null && problem == null) ...[
            Gap.sm,
            Semantics(
              liveRegion: true,
              child: BodyText(
                l10n.customTimeTotal(formatDurationMinutes(l10n, selected)),
              ),
            ),
          ],
          if (problem != null) ...[
            Gap.sm,
            Semantics(
              liveRegion: true,
              child: Text(
                problem,
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
