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

/// Why the password is asked for, when the generic "for your security" line would leave
/// the person guessing. Each reason says plainly what the change decides: the safety net
/// is what tells people when a check-in is missed, and what each person is shown
/// (SECURITY.md §7).
enum ReauthReason {
  /// Saving the escalation plan while check-ins are on (`PUT /plan`).
  plan,

  /// Removing a trusted contact who is in the plan (`DELETE /contacts/{id}`).
  removeContact,

  /// Changing the email address of a trusted contact who is in the plan
  /// (`PATCH /contacts/{id}`).
  contactEmail,

  /// Removing a trusted contact who is not in the plan but receives an active
  /// instruction (`DELETE /contacts/{id}`).
  removeRecipient,

  /// Changing the email address of a contact who receives an active instruction and is
  /// not in the plan (`PATCH /contacts/{id}`).
  recipientEmail,

  /// Choosing or changing who receives an instruction (`POST` with recipients, `PATCH`
  /// that changes them) while check-ins are on.
  instructionRecipients,

  /// Switching off, or deleting, an instruction that has recipients while check-ins are
  /// on (`PATCH` status `inactive`, `DELETE`).
  instructionOff,

  /// Saving an instruction whose time the plan has no stage for yet: the plan gets the
  /// stage (`PUT /plan`) and the instruction its recipients, under one password.
  instructionNewTime,
}

/// The sentence of [reason] in the sheet's body.
String reauthReasonText(AppLocalizations l10n, ReauthReason reason) =>
    switch (reason) {
      ReauthReason.plan => l10n.reauthReasonPlan,
      ReauthReason.removeContact => l10n.reauthReasonRemoveContact,
      ReauthReason.contactEmail => l10n.reauthReasonContactEmail,
      ReauthReason.removeRecipient => l10n.reauthReasonRemoveRecipient,
      ReauthReason.recipientEmail => l10n.reauthReasonRecipientEmail,
      ReauthReason.instructionRecipients =>
        l10n.reauthReasonInstructionRecipients,
      ReauthReason.instructionOff => l10n.reauthReasonInstructionOff,
      ReauthReason.instructionNewTime => l10n.reauthReasonInstructionNewTime,
    };

/// Asks for the password again before a sensitive action (USER_FLOWS.md §7). Returns
/// true when `POST /auth/reauth` accepted it (the server remembers this for 5 minutes),
/// false when the person dismissed the sheet. [reason] replaces the generic body with
/// why this action needs it.
///
/// Any feature can use it directly, or through [withReauth].
Future<bool> showReauthSheet(
  BuildContext context, {
  ReauthReason? reason,
}) async {
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => ReauthSheet(reason: reason),
  );
  return confirmed ?? false;
}

/// Runs [action]; when the server asks for a recent re-authentication
/// (`403 reauth_required`) shows the [ReauthSheet] and, once confirmed, runs [action]
/// once more. Returns null when the person dismissed the sheet: [action] was then run
/// only once and changed nothing. Other failures are rethrown for the caller to show.
///
/// [action] must send the same request both times (build the body before calling this,
/// not inside it): the server answers `reauth_required` before it changes anything, so
/// the second run is the request the person asked for, once.
Future<T?> withReauth<T>(
  BuildContext context,
  Future<T> Function() action, {
  ReauthReason? reason,
}) async {
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
  if (!await showReauthSheet(context, reason: reason)) {
    return null;
  }
  return action();
}

/// The bottom sheet itself. The password is held by the text field only for as long as
/// the sheet is open and is never stored or logged.
class ReauthSheet extends ConsumerStatefulWidget {
  const ReauthSheet({this.reason, super.key});

  /// Why the password is needed here; the generic line when null.
  final ReauthReason? reason;

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
            BodyText(
              widget.reason == null
                  ? l10n.reauthBody
                  : reauthReasonText(l10n, widget.reason!),
            ),
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
