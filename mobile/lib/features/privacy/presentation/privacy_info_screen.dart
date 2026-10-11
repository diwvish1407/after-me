import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/legal_links.dart';
import '../../settings/presentation/settings_widgets.dart';

/// Settings > Privacy and data > What AfterMe keeps: in plain words what is stored, who
/// it may be shared with, and what deleting the account does (SECURITY.md §14), with the
/// links to the privacy policy and the terms.
class PrivacyInfoScreen extends ConsumerWidget {
  const PrivacyInfoScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final items = [
      (l10n.privacyKeepsAccountTitle, l10n.privacyKeepsAccount),
      (l10n.privacyKeepsContactsTitle, l10n.privacyKeepsContacts),
      (l10n.privacyKeepsInstructionsTitle, l10n.privacyKeepsInstructions),
      (l10n.privacyKeepsHistoryTitle, l10n.privacyKeepsHistory),
      (l10n.privacyKeepsNeverTitle, l10n.privacyKeepsNever),
      (l10n.privacyKeepsDeletionTitle, l10n.privacyKeepsDeletion),
    ];
    final textTheme = Theme.of(context).textTheme;
    return FormPage(
      title: l10n.settingsPrivacyKeeps,
      children: [
        PageHeading(l10n.settingsPrivacyKeeps),
        Gap.xs,
        BodyText(l10n.privacyKeepsIntro),
        Gap.md,
        for (final (title, body) in items) ...[
          Semantics(
            header: true,
            child: Text(title, style: textTheme.titleSmall),
          ),
          const SizedBox(height: 4),
          Text(body),
          Gap.md,
        ],
        SettingsTile(
          icon: Icons.privacy_tip_outlined,
          title: l10n.legalPrivacy,
          trailing: const Icon(Icons.open_in_new_rounded),
          onTap: () => openLegalPage(context, ref, LegalPage.privacy),
        ),
        SettingsTile(
          icon: Icons.description_outlined,
          title: l10n.legalTerms,
          trailing: const Icon(Icons.open_in_new_rounded),
          onTap: () => openLegalPage(context, ref, LegalPage.terms),
        ),
      ],
    );
  }
}
