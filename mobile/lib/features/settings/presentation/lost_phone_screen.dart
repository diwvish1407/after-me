import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../core/config/app_config.dart';
import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/legal_links.dart';

/// The path of the lost-phone page on the public site (API_SPEC.md §13.2).
const lostPhonePath = '/a/login';

/// Settings > Help > If you lose your phone: the plan keeps working, and the person can
/// check in or confirm I'M SAFE from any browser, at the public site's sign-in page
/// (`/a/login`, on the configured public base URL, shown as text so it can be typed in
/// another browser, and opened with the same mechanism as the legal pages).
class LostPhoneScreen extends ConsumerWidget {
  const LostPhoneScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final address = ref
        .watch(appConfigProvider)
        .publicUri(lostPhonePath)
        .toString();
    return FormPage(
      title: l10n.settingsLostPhone,
      children: [
        PageHeading(l10n.settingsLostPhone),
        Gap.xs,
        BodyText(l10n.lostPhoneBody),
        Gap.md,
        Text(
          l10n.lostPhoneAddressLabel,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: AppSpacing.xxs),
        // Plain text: it is read (or typed into another browser), not edited.
        Text(address, style: Theme.of(context).textTheme.bodyLarge),
        Gap.md,
        for (final step in [
          l10n.lostPhoneStepSignIn,
          l10n.lostPhoneStepCheckIn,
          l10n.lostPhoneStepSafe,
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Text(step),
          ),
        Gap.sm,
        BodyText(l10n.lostPhoneNoted),
        Gap.lg,
        AppButton.primary(
          label: l10n.lostPhoneOpen,
          icon: Icons.open_in_new_rounded,
          onPressed: () =>
              unawaited(openPublicPage(context, ref, lostPhonePath)),
          expand: true,
        ),
      ],
    );
  }
}
