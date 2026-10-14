import 'package:material_ui/material_ui.dart';

import '../../../core/design_system/status_banner.dart';
import '../../../l10n/gen/app_localizations.dart';

/// The calm notice shown while the service is in a Hold (`service.interruption` of
/// `GET /v1/home`): nothing is sent to anyone, deadlines move by the same time, and
/// checking in still works.
///
/// It is informational (never an alarm colour), a live region so a screen reader says it
/// once when it appears, and has no action: the person has nothing to do but carry on.
/// I'M OK and I'M SAFE are not touched by it.
class ServiceInterruptionBanner extends StatelessWidget {
  const ServiceInterruptionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return StatusBanner(
      kind: StatusBannerKind.info,
      title: l10n.homeInterruptionTitle,
      message: l10n.homeInterruptionBody,
      liveRegion: true,
    );
  }
}
