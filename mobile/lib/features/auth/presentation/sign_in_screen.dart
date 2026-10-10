import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/auth/session_ended_notice.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/forms/validators.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/login_controller.dart';

/// Sign in with email and password. A not-yet-verified account continues with its code.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  FieldIssue? _emailIssue;
  FieldIssue? _passwordIssue;

  @override
  void initState() {
    super.initState();
    // The controller outlives this screen: a failure from an earlier visit must not
    // greet a fresh form (and be announced as a live region).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(loginControllerProvider.notifier).clearFailure();
      }
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _emailIssue = Validators.email(_email.text);
      _passwordIssue = Validators.existingPassword(_password.text);
    });
    if (_emailIssue != null || _passwordIssue != null) {
      return;
    }
    FocusScope.of(context).unfocus();
    final result = await ref
        .read(loginControllerProvider.notifier)
        .signIn(
          email: Validators.cleanEmail(_email.text),
          password: _password.text,
        );
    if (!mounted) {
      return;
    }
    if (result == LoginResult.needsVerification) {
      unawaited(context.push<void>(AppRoutes.verifyCode));
    }
    // LoginResult.signedIn: the router leaves this screen by itself.
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(loginControllerProvider);
    final failure = state.failure;
    return FormPage(
      title: l10n.signInTitle,
      children: [
        PageHeading(l10n.signInHeading),
        Gap.lg,
        if (ref.watch(sessionEndedNoticeProvider)) ...[
          Semantics(
            liveRegion: true,
            container: true,
            child: StatusBanner(
              kind: StatusBannerKind.info,
              message: l10n.errorSessionExpired,
            ),
          ),
          Gap.md,
        ],
        if (failure != null) ...[
          FailureNotice(
            message: failure is UnauthorizedFailure
                ? l10n.signInWrongDetails
                : failureMessage(l10n, failure),
          ),
          Gap.md,
        ],
        AppTextField(
          label: l10n.fieldEmail,
          controller: _email,
          errorText: _emailIssue == null
              ? null
              : issueMessage(l10n, _emailIssue!),
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.email],
          enabled: !state.busy,
          onChanged: (_) {
            ref.read(loginControllerProvider.notifier).clearFailure();
            setState(() => _emailIssue = null);
          },
        ),
        Gap.md,
        AppTextField(
          label: l10n.fieldPassword,
          controller: _password,
          obscureText: true,
          errorText: _passwordIssue == null
              ? null
              : issueMessage(l10n, _passwordIssue!),
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.password],
          enabled: !state.busy,
          onChanged: (_) {
            ref.read(loginControllerProvider.notifier).clearFailure();
            setState(() => _passwordIssue = null);
          },
          onSubmitted: (_) => _submit(),
        ),
        Gap.lg,
        AppButton.primary(
          label: l10n.signInSubmit,
          isLoading: state.busy,
          onPressed: _submit,
          expand: true,
        ),
        Gap.xs,
        AppButton.text(
          label: l10n.signInForgot,
          onPressed: state.busy
              ? null
              : () => context.push(
                  AppRoutes.forgotPassword,
                  extra: _email.text.trim(),
                ),
          expand: true,
        ),
        AppButton.text(
          label: l10n.signInCreateAccount,
          onPressed: state.busy
              ? null
              : () => context.push(AppRoutes.createAccount),
          expand: true,
        ),
      ],
    );
  }
}
