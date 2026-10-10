import 'package:material_ui/material_ui.dart';

import '../../l10n/gen/app_localizations.dart';
import 'country_names.dart';
import 'searchable_picker.dart';
import 'timezone_catalog.dart';

/// Lets the person choose a timezone. Returns the IANA identifier, or null.
Future<String?> pickTimezone(
  BuildContext context, {
  required List<String> available,
  String? selected,
}) {
  final l10n = AppLocalizations.of(context);
  final ids = TimezoneCatalog.choices(available, include: selected);
  return showSearchablePicker<String>(
    context,
    title: l10n.pickTimezoneTitle,
    selected: selected,
    items: [
      for (final id in ids)
        PickerItem(value: id, label: TimezoneCatalog.label(id)),
    ],
  );
}

/// Marker for "no country" in [pickCountry].
const String noCountry = '';

/// Lets the person choose a country. Returns the ISO alpha-2 code, [noCountry] when
/// they clear it, or null when they go back.
Future<String?> pickCountry(BuildContext context, {String? selected}) {
  final l10n = AppLocalizations.of(context);
  return showSearchablePicker<String>(
    context,
    title: l10n.pickCountryTitle,
    selected: selected,
    clearLabel: l10n.pickCountryNone,
    clearValue: noCountry,
    items: [
      for (final (code, name) in countryNames)
        PickerItem(value: code, label: name),
    ],
  );
}
