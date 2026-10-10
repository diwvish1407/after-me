import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/api/client_info.dart';
import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/legal_links.dart';
import 'settings_widgets.dart';

/// Version, licences and the legal pages.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final info = ref.watch(clientInfoProvider);
    return FormPage(
      title: l10n.settingsAbout,
      children: [
        PageHeading(l10n.appName),
        Gap.xs,
        Text(l10n.settingsVersion('${info.version} (${info.buildNumber})')),
        Gap.md,
        BodyText(l10n.notEmergencyService),
        Gap.md,
        SettingsTile(
          icon: Icons.description_outlined,
          title: l10n.legalTerms,
          trailing: const Icon(Icons.open_in_new_rounded),
          onTap: () => openLegalPage(context, ref, LegalPage.terms),
        ),
        SettingsTile(
          icon: Icons.privacy_tip_outlined,
          title: l10n.legalPrivacy,
          trailing: const Icon(Icons.open_in_new_rounded),
          onTap: () => openLegalPage(context, ref, LegalPage.privacy),
        ),
        SettingsTile(
          icon: Icons.gavel_rounded,
          title: l10n.aboutLicenses,
          onTap: () => showLicensePage(
            context: context,
            applicationName: l10n.appName,
            applicationVersion: info.version,
          ),
        ),
      ],
    );
  }
}
