import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/security/secure_screen.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../application/delete_account_controller.dart';

/// Settings > Privacy and data > Delete account (USER_FLOWS.md §11, SECURITY.md §19).
///
/// The most destructive thing the app can do, so it is slow on purpose: what happens is
/// listed exactly, the word DELETE has to be typed exactly (the button stays off until it
/// matches), and the password is asked for **immediately before** the request (the server
/// accepts it for 60 seconds).
///
/// While the request is in flight the screen cannot be left and the button is off. What
/// follows a `202` is not done here (the screen is gone by then: every session is already
/// revoked): `DeleteAccountController` clears what the phone keeps, ends the local session
/// and the router shows "Your account has been closed". A failure leaves the screen as it
/// was, says that nothing was confirmed, and the same request can be made again.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() =>
      _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _confirm = TextEditingController();
  bool _busy = false;
  AppFailure? _failure;

  bool get _matches => _confirm.text == deleteConfirmationWord;

  @override
  void initState() {
    super.initState();
    // A new visit starts without the memory of an earlier request.
    Future<void>.microtask(() {
      if (mounted) {
        ref.read(deleteAccountControllerProvider.notifier).reset();
      }
    });
  }

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (_busy || !_matches) {
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    final controller = ref.read(deleteAccountControllerProvider.notifier);
    try {
      // The same request both times: the controller sends `{"confirm": "DELETE"}`.
      await withReauth<AccountDeletionOutcome>(
        context,
        controller.request,
        reason: ReauthReason.deleteAccount,
      );
      // closed or unconfirmed: the session is over and the router has moved on. null: the
      // password sheet was dismissed and nothing was sent.
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(() => _failure = failure);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final failure = _failure;
    final wrongWord =
        failure is ValidationFailure &&
        failure.fieldErrors.any((error) => error.field == 'confirm');
    return PopScope(
      // Nothing can be left while the request is on its way.
      canPop: !_busy,
      child: SecureScreen(
        child: FormPage(
          title: l10n.settingsDelete,
          automaticallyImplyLeading: !_busy,
          children: [
            PageHeading(l10n.deleteTitle),
            Gap.xs,
            BodyText(l10n.deleteIntro),
            Gap.sm,
            for (final line in [
              l10n.deleteEffectCheckins,
              l10n.deleteEffectInstructions,
              l10n.deleteEffectContacts,
              l10n.deleteEffectAlert,
              l10n.deleteEffectSignedOut,
              l10n.deleteEffectPurge,
            ])
              _Effect(text: line),
            Gap.sm,
            Text(
              l10n.deleteEffectUndone,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Gap.md,
            BodyText(l10n.deleteExportFirst),
            AppButton.text(
              label: l10n.settingsExport,
              icon: Icons.download_outlined,
              onPressed: _busy
                  ? null
                  : () => context.push(AppRoutes.settingsExport),
              expand: true,
            ),
            Gap.lg,
            if (failure != null && !wrongWord) ...[
              FailureNotice(
                message: actionFailureMessage(
                  l10n,
                  failure,
                  UnconfirmedAction.delete,
                ),
              ),
              Gap.md,
            ],
            AppTextField(
              label: l10n.deleteConfirmLabel,
              helperText: l10n.deleteConfirmHelper,
              errorText: wrongWord ? l10n.deleteConfirmWrong : null,
              controller: _confirm,
              enabled: !_busy,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {
                if (wrongWord) {
                  _failure = null;
                }
              }),
              onSubmitted: (_) => unawaited(_delete()),
            ),
            Gap.md,
            if (_busy) ...[
              StatusBanner(
                kind: StatusBannerKind.info,
                message: l10n.deleteWorking,
                liveRegion: true,
              ),
              Gap.md,
            ],
            AppButton.primary(
              label: l10n.deleteButton,
              icon: Icons.delete_outline_rounded,
              isLoading: _busy,
              onPressed: _matches && !_busy ? () => unawaited(_delete()) : null,
              expand: true,
            ),
            Gap.xs,
            AppButton.secondary(
              label: l10n.deleteKeep,
              onPressed: _busy ? null : () => context.pop(),
              expand: true,
            ),
          ],
        ),
      ),
    );
  }
}

/// One thing that happens, as a bullet.
class _Effect extends StatelessWidget {
  const _Effect({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2, right: 8),
            child: Icon(Icons.circle, size: 6),
          ),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
