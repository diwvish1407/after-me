import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/safe_controller.dart';
import '../data/models/incident_models.dart';
import 'safe_sheet.dart';

/// The main action once contacts have been notified: I'M SAFE (USER_FLOWS.md §4, §7).
///
/// Disabled while the request is on the wire, so a double tap sends one request. It opens
/// the password sheet and then the confirmation; it never sends anything by itself.
class SafeActionButton extends ConsumerWidget {
  const SafeActionButton({required this.incidentId, this.incident, super.key});

  final String incidentId;

  /// What Home knows about the incident; null when it could not be read.
  final Incident? incident;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final sending = ref.watch(
      safeControllerProvider.select((s) => s.isSending),
    );
    final base = Theme.of(context);
    final style = base.filledButtonTheme.style;
    void start() => unawaited(
      startSafeFlow(context, incidentId: incidentId, incident: incident),
    );
    // One node for a screen reader: the label, what it does, and the tap.
    return Semantics(
      container: true,
      button: true,
      enabled: !sending,
      label: l10n.incidentSafeButton,
      hint: l10n.incidentSafeHint,
      onTap: sending ? null : start,
      excludeSemantics: true,
      child: Theme(
        data: base.copyWith(
          filledButtonTheme: FilledButtonThemeData(
            style: (style ?? const ButtonStyle()).copyWith(
              minimumSize: const WidgetStatePropertyAll(Size.fromHeight(64)),
            ),
          ),
        ),
        child: AppButton.primary(
          label: l10n.incidentSafeButton,
          icon: Icons.verified_user_outlined,
          isLoading: sending,
          expand: true,
          onPressed: sending ? null : start,
        ),
      ),
    );
  }
}
