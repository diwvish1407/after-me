import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../shell/presentation/placeholder_tab.dart';

/// Instructions placeholder (Phase 6).
class InstructionsScreen extends StatelessWidget {
  const InstructionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PlaceholderTab(
      title: l10n.navInstructions,
      icon: Icons.description_outlined,
      emptyTitle: l10n.instructionsEmptyTitle,
      emptyMessage: l10n.instructionsEmptyBody,
    );
  }
}
