import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/forms/validators.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/me_controller.dart';
import '../data/auth_repository.dart';

/// Asks for the password again before a sensitive action (USER_FLOWS.md §7). Returns
/// true when `POST /auth/reauth` accepted it (the server remembers this for 5 minutes),
/// false when the person dismissed the sheet.
///
/// Any feature can use it directly, or through [withReauth].
Future<bool> showReauthSheet(BuildContext context) async {
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => const ReauthSheet(),
  );
  return confirmed ?? false;
}

/// Runs [action]; when the server asks for a recent re-authentication
/// (`403 reauth_required`) shows the [ReauthSheet] and, once confirmed, runs [action]
/// once more. Returns null when the person dismissed the sheet. Other failures are
/// rethrown for the caller to show.
Future<T?> withReauth<T>(
  BuildContext context,
  Future<T> Function() action,
) async {
  try {
    return await action();
  } on ForbiddenFailure catch (failure) {
    if (failure.code != 'reauth_required') {
      rethrow;
    }
  }
  if (!context.mounted) {
    return null;
  }
  if (!await showReauthSheet(context)) {
    return null;
  }
  return action();
}

/// The bottom sheet itself. The password is held by the text field only for as long as
/// the sheet is open and is never stored or logged.
class ReauthSheet extends ConsumerStatefulWidget {
  const ReauthSheet({super.key});

  @override
  ConsumerState<ReauthSheet> createState() => _ReauthSheetState();
}

class _ReauthSheetState extends ConsumerState<ReauthSheet> {
  final _password = TextEditingController();
  bool _busy = false;
  AppFailure? _failure;
  FieldIssue? _issue;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final issue = Validators.existingPassword(_password.text);
    setState(() => _issue = issue);
    if (issue != null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await ref.read(authRepositoryProvider).reauth(password: _password.text);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on Object catch (error) {
      // A wrong password is a 401 that keeps the session: stay here and say so.
      if (mounted) {
        setState(() {
          _busy = false;
          _failure = toAppFailure(error);
          _password.clear();
        });
      }
    }
  }

  void _forgot() {
    final email = ref.read(meControllerProvider).value?.email;
    final router = GoRouter.of(context);
    Navigator.of(context).pop(false);
    router.push(AppRoutes.forgotPassword, extra: email);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final failure = _failure;
    final wrongPassword =
        failure is UnauthorizedFailure && failure.code == 'invalid_credentials';
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.page,
        0,
        AppSpacing.page,
        MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeading(l10n.reauthTitle),
            Gap.xs,
            BodyText(l10n.reauthBody),
            Gap.md,
            if (failure != null && !wrongPassword) ...[
              FailureNotice.of(context, failure),
              Gap.md,
            ],
            AppTextField(
              label: l10n.fieldPassword,
              controller: _password,
              obscureText: true,
              autofocus: true,
              enabled: !_busy,
              errorText: wrongPassword
                  ? l10n.reauthWrongPassword
                  : (_issue == null ? null : issueMessage(l10n, _issue!)),
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              onChanged: (_) => setState(() {
                _issue = null;
                if (wrongPassword) {
                  _failure = null;
                }
              }),
              onSubmitted: (_) => _confirm(),
            ),
            Gap.md,
            AppButton.primary(
              label: l10n.reauthConfirm,
              isLoading: _busy,
              onPressed: _confirm,
              expand: true,
            ),
            Gap.xs,
            AppButton.text(
              label: l10n.signInForgot,
              onPressed: _busy ? null : _forgot,
              expand: true,
            ),
            AppButton.text(
              label: l10n.cancel,
              onPressed: _busy ? null : () => Navigator.of(context).pop(false),
              expand: true,
            ),
          ],
        ),
      ),
    );
  }
}
