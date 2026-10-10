import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/design_system/status_banner.dart';
import '../l10n/gen/app_localizations.dart';
import 'repository_providers.dart';

/// "Preview: your instructions are not saved yet, so nothing will be shared." Shown
/// while a temporary in-memory stand-in is in use ([previewModeProvider]), which since
/// Phase 5 is the instructions only; nothing at all once the real services are wired.
class PreviewBanner extends ConsumerWidget {
  const PreviewBanner({super.key, this.spaceBelow = true});

  /// Adds the usual gap under the banner.
  final bool spaceBelow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(previewModeProvider)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: spaceBelow ? 16 : 0),
      child: StatusBanner(
        kind: StatusBannerKind.attention,
        message: l10n.previewBanner,
      ),
    );
  }
}
