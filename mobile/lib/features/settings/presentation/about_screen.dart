import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/api/client_info.dart';
import '../../../core/config/app_config.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/platform/clipboard_gateway.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/legal_links.dart';
import 'settings_widgets.dart';

/// The lines a tester quotes in a bug report: the app's version and build number, the
/// environment it was made for and the host it talks to. Nothing that identifies a person
/// or a session (no token, no account id, no email) is ever part of it.
///
/// The same lines are shown on the screen and copied by "Copy diagnostic text", so what
/// is copied is exactly what the person can read.
List<String> diagnosticLines(
  AppLocalizations l10n, {
  required ClientInfo info,
  required AppConfig config,
}) {
  final uri = config.apiBaseUrl;
  // The host, and the port when the address names one (a development server).
  final host = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  return [
    l10n.aboutBuildVersion(info.version),
    l10n.aboutBuildNumber(info.buildNumber),
    l10n.aboutBuildEnvironment(config.env.name),
    l10n.aboutBuildApiHost(host),
  ];
}

/// Version, build facts for a bug report, licences and the legal pages.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  Future<void> _copy(
    BuildContext context,
    WidgetRef ref,
    List<String> lines,
  ) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final copied = await ref
        .read(clipboardGatewayProvider)
        .copy(lines.join('\n'));
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          copied
              ? l10n.aboutDiagnosticsCopied
              : l10n.aboutDiagnosticsCopyFailed,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final info = ref.watch(clientInfoProvider);
    final config = ref.watch(appConfigProvider);
    final lines = diagnosticLines(l10n, info: info, config: config);
    return FormPage(
      title: l10n.settingsAbout,
      children: [
        PageHeading(l10n.appName),
        Gap.xs,
        Text(l10n.settingsVersion('${info.version} (${info.buildNumber})')),
        Gap.md,
        BodyText(l10n.notEmergencyService),
        Gap.lg,
        Semantics(
          header: true,
          child: Text(
            l10n.aboutBuildHeading,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Gap.xs,
        // One block, read out in one go; the text can be selected on the screen too.
        Semantics(
          container: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in lines)
                Text(
                  line,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: context.tokens.text),
                ),
            ],
          ),
        ),
        Gap.sm,
        AppButton.secondary(
          label: l10n.aboutCopyDiagnostics,
          icon: Icons.copy_rounded,
          onPressed: () => _copy(context, ref, lines),
          expand: true,
        ),
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
