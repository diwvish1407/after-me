import 'package:material_ui/material_ui.dart';

import '../../app/theme/dimens.dart';
import '../../app/theme/tokens.dart';
import '../../l10n/gen/app_localizations.dart';
import '../design_system/app_text_field.dart';

/// One choice in a [showSearchablePicker].
class PickerItem<T> {
  const PickerItem({required this.value, required this.label});

  final T value;
  final String label;
}

/// A full-screen, searchable single choice. Returns the chosen value, or null when the
/// person goes back. [allowClear] adds a "Not set" row that returns [clearValue].
Future<T?> showSearchablePicker<T>(
  BuildContext context, {
  required String title,
  required List<PickerItem<T>> items,
  T? selected,
  String? clearLabel,
  T? clearValue,
}) {
  return Navigator.of(context).push<T>(
    MaterialPageRoute<T>(
      fullscreenDialog: true,
      builder: (context) => _PickerScreen<T>(
        title: title,
        items: items,
        selected: selected,
        clearLabel: clearLabel,
        clearValue: clearValue,
      ),
    ),
  );
}

class _PickerScreen<T> extends StatefulWidget {
  const _PickerScreen({
    required this.title,
    required this.items,
    required this.selected,
    required this.clearLabel,
    required this.clearValue,
  });

  final String title;
  final List<PickerItem<T>> items;
  final T? selected;
  final String? clearLabel;
  final T? clearValue;

  @override
  State<_PickerScreen<T>> createState() => _PickerScreenState<T>();
}

class _PickerScreenState<T> extends State<_PickerScreen<T>> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final query = _query.trim().toLowerCase();
    final shown = [
      for (final item in widget.items)
        if (query.isEmpty || item.label.toLowerCase().contains(query)) item,
    ];
    final showClear = widget.clearLabel != null && query.isEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                AppSpacing.md,
                AppSpacing.page,
                AppSpacing.xs,
              ),
              child: AppTextField(
                label: l10n.pickerSearch,
                onChanged: (value) => setState(() => _query = value),
                textInputAction: TextInputAction.search,
              ),
            ),
            Expanded(
              child: shown.isEmpty && !showClear
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Text(
                          l10n.pickerNoResults,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: t.textMuted),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: shown.length + (showClear ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (showClear && index == 0) {
                          return ListTile(
                            minTileHeight: AppSizes.minTouchTarget,
                            title: Text(widget.clearLabel!),
                            onTap: () =>
                                Navigator.of(context).pop(widget.clearValue),
                          );
                        }
                        final item = shown[index - (showClear ? 1 : 0)];
                        final isSelected = item.value == widget.selected;
                        return ListTile(
                          minTileHeight: AppSizes.minTouchTarget,
                          title: Text(item.label),
                          selected: isSelected,
                          trailing: isSelected
                              ? Icon(
                                  Icons.check_rounded,
                                  semanticLabel: l10n.pickerSelected,
                                )
                              : null,
                          onTap: () => Navigator.of(context).pop(item.value),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
