import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../l10n/gen/app_localizations.dart';

/// "03:30" for 210 minutes (hh:mm).
String formatHoursMinutes(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// A dialog to choose a length of time as hours and minutes (two dropdowns, hh : mm),
/// between [minMinutes] and [maxMinutes]. Returns the minutes, or null when cancelled.
Future<int?> showHoursMinutesPicker(
  BuildContext context, {
  required int initialMinutes,
  required int minMinutes,
  required int maxMinutes,
}) => showDialog<int>(
  context: context,
  builder: (context) => _HoursMinutesDialog(
    initial: initialMinutes.clamp(minMinutes, maxMinutes),
    min: minMinutes,
    max: maxMinutes,
  ),
);

class _HoursMinutesDialog extends StatefulWidget {
  const _HoursMinutesDialog({
    required this.initial,
    required this.min,
    required this.max,
  });

  final int initial;
  final int min;
  final int max;

  @override
  State<_HoursMinutesDialog> createState() => _HoursMinutesDialogState();
}

class _HoursMinutesDialogState extends State<_HoursMinutesDialog> {
  late int _hours = widget.initial ~/ 60;
  late int _minutes = widget.initial % 60;

  int get _total => _hours * 60 + _minutes;
  bool get _valid => _total >= widget.min && _total <= widget.max;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final maxHours = widget.max ~/ 60;
    return AlertDialog(
      semanticLabel: l10n.planGraceCustomTitle,
      title: Text(l10n.planGraceCustomTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _hours,
                  isExpanded: true,
                  menuMaxHeight: 320,
                  decoration: InputDecoration(labelText: l10n.planTimeHours),
                  items: [
                    for (var h = 0; h <= maxHours; h++)
                      DropdownMenuItem(
                        value: h,
                        child: Text(h.toString().padLeft(2, '0')),
                      ),
                  ],
                  onChanged: (v) => setState(() => _hours = v ?? 0),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                child: Text(':', style: text.headlineSmall),
              ),
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _minutes,
                  isExpanded: true,
                  menuMaxHeight: 320,
                  decoration: InputDecoration(labelText: l10n.planTimeMinutes),
                  items: [
                    for (var m = 0; m < 60; m += 1)
                      DropdownMenuItem(
                        value: m,
                        child: Text(m.toString().padLeft(2, '0')),
                      ),
                  ],
                  onChanged: (v) => setState(() => _minutes = v ?? 0),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            _valid ? l10n.planGraceCustomHelp : l10n.planGraceCustomInvalid,
            style: text.bodySmall?.copyWith(
              color: _valid ? t.textMuted : t.escalation,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _valid ? () => Navigator.of(context).pop(_total) : null,
          child: Text(l10n.planTimeUse),
        ),
      ],
    );
  }
}
