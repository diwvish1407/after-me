import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/forms/digits_formatter.dart';
import '../../../core/forms/validators.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/application/me_controller.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/presentation/reauth_sheet.dart';

/// Settings > Security > Change email: new address, then the code sent to it.
///
/// The server answers the first step the same way whether or not the address can be
/// used, so this screen never says whether an address is taken.
class ChangeEmailScreen extends ConsumerStatefulWidget {
  const ChangeEmailScreen({super.key});

  @override
  ConsumerState<ChangeEmailScreen> createState() => _ChangeEmailScreenState();
}

class _ChangeEmailScreenState extends ConsumerState<ChangeEmailScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _codeStep = false;
  bool _busy = false;
  AppFailure? _failure;
  FieldIssue? _issue;
  bool _codeRejected = false;
  String _sentTo = '';

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final issue = Validators.email(_email.text);
    final current = ref.read(meControllerProvider).value?.email;
    final candidate = Validators.cleanEmail(_email.text);
    final same =
        current != null && candidate.toLowerCase() == current.toLowerCase();
    setState(() => _issue = issue ?? (same ? FieldIssue.sameEmail : null));
    if (issue != null || same) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final started = await withReauth<bool>(context, () async {
        await ref
            .read(authRepositoryProvider)
            .emailChangeStart(newEmail: candidate);
        return true;
      });
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        if (started ?? false) {
          _codeStep = true;
          _sentTo = candidate;
        }
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failure = toAppFailure(error);
        });
      }
    }
  }

  Future<void> _verify() async {
    final issue = Validators.code(_code.text);
    setState(() => _issue = issue);
    if (issue != null) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _failure = null;
      _codeRejected = false;
    });
    try {
      final me = await ref
          .read(authRepositoryProvider)
          .emailChangeVerify(code: Validators.normalizeCode(_code.text));
      ref.read(meControllerProvider.notifier).apply(me);
      if (!mounted) {
        return;
      }
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.changeEmailDone)));
      context.pop();
    } on Object catch (error) {
      final failure = toAppFailure(error);
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _code.clear();
        if (failure is ValidationFailure && failure.code == 'invalid_code') {
          _codeRejected = true;
        } else {
          _failure = failure;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final current = ref.watch(meControllerProvider).value?.email;
    final failure = _failure;
    final serverEmail = failure is ValidationFailure
        ? issueForField(failure.fieldErrors, 'new_email')
        : null;
    if (_codeStep) {
      return FormPage(
        title: l10n.securityChangeEmail,
        children: [
          PageHeading(l10n.changeEmailCodeHeading),
          Gap.xs,
          BodyText(l10n.changeEmailCodeIntro),
          Gap.xs,
          FitText(_sentTo, style: Theme.of(context).textTheme.titleMedium),
          Gap.lg,
          if (_codeRejected) ...[
            FailureNotice(message: l10n.codeWrong),
            Gap.md,
          ] else if (failure != null) ...[
            FailureNotice.of(context, failure),
            Gap.md,
          ],
          AppTextField(
            label: l10n.fieldCode,
            controller: _code,
            errorText: _issue == null ? null : issueMessage(l10n, _issue!),
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.oneTimeCode],
            autofocus: true,
            textAlign: TextAlign.center,
            enabled: !_busy,
            inputFormatters: const [DigitsOnlyFormatter()],
            onChanged: (_) => setState(() => _issue = null),
            onSubmitted: (_) => _verify(),
          ),
          Gap.lg,
          AppButton.primary(
            label: l10n.changeEmailVerify,
            isLoading: _busy,
            onPressed: _verify,
            expand: true,
          ),
          Gap.xs,
          AppButton.text(
            label: l10n.changeEmailDifferent,
            onPressed: _busy
                ? null
                : () => setState(() {
                    _codeStep = false;
                    _code.clear();
                    _failure = null;
                    _codeRejected = false;
                  }),
            expand: true,
          ),
        ],
      );
    }
    return FormPage(
      title: l10n.securityChangeEmail,
      children: [
        if (current != null) ...[
          BodyText(l10n.changeEmailCurrent),
          Gap.xs,
          FitText(current, style: Theme.of(context).textTheme.titleMedium),
        ],
        Gap.sm,
        BodyText(l10n.changeEmailIntro),
        Gap.lg,
        if (failure != null && serverEmail == null) ...[
          FailureNotice.of(context, failure),
          Gap.md,
        ],
        AppTextField(
          label: l10n.fieldNewEmail,
          controller: _email,
          errorText: (_issue ?? serverEmail) == null
              ? null
              : issueMessage(l10n, (_issue ?? serverEmail)!),
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.email],
          enabled: !_busy,
          onChanged: (_) => setState(() => _issue = null),
          onSubmitted: (_) => _start(),
        ),
        Gap.lg,
        AppButton.primary(
          label: l10n.changeEmailSend,
          isLoading: _busy,
          onPressed: _start,
          expand: true,
        ),
        Gap.sm,
        BodyText(l10n.changeEmailNotice),
      ],
    );
  }
}
