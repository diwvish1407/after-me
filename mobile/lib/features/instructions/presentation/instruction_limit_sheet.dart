import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';

/// The default free-plan limit, used only to word the sheet when the server did not say.
const int freeInstructionLimit = 3;

/// Explains the plan limit for instructions (the same pattern as the contacts limit):
/// the free plan includes [limit] (3) instructions and more are not available yet. There
/// is no billing in 1.0 (PRD D5), so the sheet offers no purchase, no price and no link to
/// pay: only the explanation and Close. The server's `plan_limit_reached` (403) still
/// opens it, with the server's own limit when it gave one.
Future<void> showInstructionLimitSheet(
  BuildContext context, {
  int? limit,
  bool free = true,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => _InstructionLimitSheet(limit: limit, free: free),
  );
}

class _InstructionLimitSheet extends StatelessWidget {
  const _InstructionLimitSheet({required this.limit, required this.free});

  final int? limit;
  final bool free;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final amount = limit ?? (free ? freeInstructionLimit : 200);
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
          PageHeading(
            free ? l10n.instructionLimitTitle : l10n.errorPlanLimitInstructions,
          ),
          Gap.sm,
          BodyText(
            free
                ? l10n.instructionLimitBodyFree(amount)
                : l10n.instructionLimitBodyMax(amount),
          ),
          Gap.lg,
          AppButton.primary(
            label: l10n.actionClose,
            onPressed: () => Navigator.of(context).pop(),
            expand: true,
          ),
        ],
      ),
    );
  }
}
