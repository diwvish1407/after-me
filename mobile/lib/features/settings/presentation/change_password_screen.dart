import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/forms/validators.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/application/me_controller.dart';
import '../../auth/data/auth_repository.dart';

/// Settings > Security > Change password. Other devices are signed out by the server.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  AppFailure? _failure;
  FieldIssue? _currentIssue;
  FieldIssue? _newIssue;
  FieldIssue? _confirmIssue;
  bool _currentWrong = false;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = ref.read(meControllerProvider).value?.email;
    setState(() {
      _failure = null;
      _currentWrong = false;
      _currentIssue = Validators.existingPassword(_current.text);
      _newIssue =
          Validators.newPassword(_new.text, email: email) ??
          (_new.text == _current.text ? FieldIssue.samePassword : null);
      _confirmIssue = _confirm.text != _new.text
          ? FieldIssue.passwordsDiffer
          : null;
    });
    if (_currentIssue != null || _newIssue != null || _confirmIssue != null) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      await ref
          .read(authRepositoryProvider)
          .changePassword(
            currentPassword: _current.text,
            newPassword: _new.text,
          );
      if (!mounted) {
        return;
      }
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.changePasswordDone)));
      context.pop();
    } on Object catch (error) {
      final failure = toAppFailure(error);
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        if (failure is UnauthorizedFailure &&
            failure.code == 'invalid_credentials') {
          _currentWrong = true;
          _current.clear();
        } else {
          _failure = failure;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final email = ref.watch(meControllerProvider).value?.email;
    final failure = _failure;
    final serverNew = failure is ValidationFailure
        ? issueForField(failure.fieldErrors, 'new_password')
        : null;
    final strength = passwordStrength(_new.text, email: email);
    String? msg(FieldIssue? issue) =>
        issue == null ? null : issueMessage(l10n, issue);
    return FormPage(
      title: l10n.securityChangePassword,
      children: [
        BodyText(l10n.changePasswordIntro),
        Gap.lg,
        if (failure != null && serverNew == null) ...[
          FailureNotice.of(context, failure),
          Gap.md,
        ],
        AppTextField(
          label: l10n.fieldCurrentPassword,
          controller: _current,
          obscureText: true,
          errorText: _currentWrong
              ? l10n.reauthWrongPassword
              : msg(_currentIssue),
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.password],
          enabled: !_busy,
          onChanged: (_) => setState(() {
            _currentIssue = null;
            _currentWrong = false;
          }),
        ),
        Gap.md,
        AppTextField(
          label: l10n.fieldNewPassword,
          controller: _new,
          obscureText: true,
          errorText: msg(_newIssue ?? serverNew),
          helperText: passwordStrengthHint(l10n, strength),
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.newPassword],
          enabled: !_busy,
          onChanged: (_) => setState(() => _newIssue = null),
        ),
        Gap.md,
        AppTextField(
          label: l10n.fieldConfirmPassword,
          controller: _confirm,
          obscureText: true,
          errorText: msg(_confirmIssue),
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.newPassword],
          enabled: !_busy,
          onChanged: (_) => setState(() => _confirmIssue = null),
          onSubmitted: (_) => _submit(),
        ),
        Gap.sm,
        BodyText(l10n.changePasswordEffect),
        Gap.lg,
        AppButton.primary(
          label: l10n.changePasswordSubmit,
          isLoading: _busy,
          onPressed: _submit,
          expand: true,
        ),
      ],
    );
  }
}
