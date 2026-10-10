import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/config/app_config.dart';
import '../../../core/design_system/app_button.dart';
import '../../../core/links/url_opener.dart';
import '../../../l10n/gen/app_localizations.dart';

/// The public legal pages (served by the backend at `PUBLIC_BASE_URL`).
enum LegalPage {
  terms('/legal/terms'),
  privacy('/legal/privacy');

  const LegalPage(this.path);

  final String path;
}

/// Opens [page] in the browser; says so calmly when that is not possible.
Future<void> openLegalPage(
  BuildContext context,
  WidgetRef ref,
  LegalPage page,
) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final opened = await ref
      .read(urlOpenerProvider)
      .open(ref.read(appConfigProvider).publicUri(page.path));
  if (!opened) {
    messenger?.showSnackBar(SnackBar(content: Text(l10n.legalOpenFailed)));
  }
}

/// "Terms of Service" and "Privacy Policy" as two separate 48 dp buttons.
class LegalLinks extends ConsumerWidget {
  const LegalLinks({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Wrap(
      children: [
        AppButton.text(
          label: l10n.legalTerms,
          icon: Icons.open_in_new_rounded,
          onPressed: () => openLegalPage(context, ref, LegalPage.terms),
        ),
        AppButton.text(
          label: l10n.legalPrivacy,
          icon: Icons.open_in_new_rounded,
          onPressed: () => openLegalPage(context, ref, LegalPage.privacy),
        ),
      ],
    );
  }
}
