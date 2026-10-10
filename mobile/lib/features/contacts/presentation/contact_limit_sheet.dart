import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';

/// The default free-plan limit, used only to word the sheet when the server did not say.
const int freeContactLimit = 1;

/// Explains the plan limit for trusted contacts (USER_FLOWS §8): the free plan allows
/// [limit] (1) trusted contact and more are part of Premium. Billing does not exist
/// yet, so there is no purchase action: only the explanation and Close.
Future<void> showContactLimitSheet(
  BuildContext context, {
  int? limit,
  bool free = true,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => _ContactLimitSheet(limit: limit, free: free),
  );
}

class _ContactLimitSheet extends StatelessWidget {
  const _ContactLimitSheet({required this.limit, required this.free});

  final int? limit;
  final bool free;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final amount = limit ?? (free ? freeContactLimit : 25);
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
            free ? l10n.contactLimitTitle : l10n.errorPlanLimitReached,
          ),
          Gap.sm,
          BodyText(
            free
                ? l10n.contactLimitBodyFree(amount)
                : l10n.contactLimitBodyMax(amount),
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
