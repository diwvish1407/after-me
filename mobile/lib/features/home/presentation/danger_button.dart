import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../data/danger_alert_repository.dart';

/// The red Danger button on Home: after a confirmation it emails every trusted contact
/// who has accepted, right away (`POST /v1/contacts/alert`), and says how many were told.
class DangerButton extends ConsumerStatefulWidget {
  const DangerButton({super.key});

  @override
  ConsumerState<DangerButton> createState() => _DangerButtonState();
}

class _DangerButtonState extends ConsumerState<DangerButton> {
  bool _busy = false;

  static const Color _red = Color(0xFFD32F2F);
  static const Color _redDark = Color(0xFFB71C1C);

  Future<void> _press() async {
    final l10n = AppLocalizations.of(context);
    unawaited(HapticFeedback.heavyImpact());
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        semanticLabel: l10n.homeDangerConfirmTitle,
        icon: const Icon(Icons.warning_amber_rounded, color: _red, size: 40),
        title: Text(l10n.homeDangerConfirmTitle, textAlign: TextAlign.center),
        content: Text(
          l10n.homeDangerConfirmBody,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _red),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.campaign_rounded),
            label: Text(l10n.homeDangerConfirm),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !mounted) {
      return;
    }
    setState(() => _busy = true);
    String message;
    try {
      final count = await ref
          .read(dangerAlertRepositoryProvider)
          .alertContacts();
      message = l10n.homeDangerSent(count);
    } on ConflictFailure catch (failure) {
      message = failure.code == 'no_contact_to_alert'
          ? l10n.homeDangerNoContact
          : failureMessage(l10n, failure);
    } on AppFailure catch (failure) {
      message = failureMessage(l10n, failure);
    }
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: l10n.homeDangerLabel,
      hint: l10n.homeDangerHint,
      excludeSemantics: true,
      onTap: _busy ? null : _press,
      child: Material(
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        elevation: 4,
        shadowColor: _red,
        child: Ink(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [_red, _redDark]),
          ),
          child: InkWell(
            onTap: _busy ? null : _press,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56, minWidth: 180),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_busy)
                      const SizedBox.square(
                        dimension: 24,
                        child: ProgressSpinner(
                          strokeWidth: 3,
                          color: Colors.white,
                        ),
                      )
                    else
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    const SizedBox(width: AppSpacing.xs),
                    // Shrinks rather than overflow at very large text sizes.
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          l10n.homeDangerLabel,
                          style: text.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
