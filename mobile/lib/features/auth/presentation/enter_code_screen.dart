import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/forms/digits_formatter.dart';
import '../../../core/forms/validators.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/signup_controller.dart';
import 'resend_countdown.dart';

/// USER_FLOWS.md §3 step 3: the 6-digit code from the email.
class EnterCodeScreen extends ConsumerStatefulWidget {
  const EnterCodeScreen({super.key});

  @override
  ConsumerState<EnterCodeScreen> createState() => _EnterCodeScreenState();
}

class _EnterCodeScreenState extends ConsumerState<EnterCodeScreen> {
  final _code = TextEditingController();
  late final SignupController _signup;
  FieldIssue? _issue;

  @override
  void initState() {
    super.initState();
    _signup = ref.read(signupControllerProvider.notifier);
    // Nothing to verify (for example after the process was restarted): start over.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_signup.hasPassword) {
        context.go(AppRoutes.welcome);
      }
    });
  }

  @override
  void dispose() {
    _signup.abandon();
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final issue = Validators.code(_code.text);
    setState(() => _issue = issue);
    if (issue != null) {
      return;
    }
    FocusScope.of(context).unfocus();
    final ok = await _signup.verify(Validators.normalizeCode(_code.text));
    if (!ok && mounted) {
      _code.clear();
    }
    // On success the session starts and the router moves on by itself.
  }

  Future<void> _resend() async {
    await _signup.resend();
    if (!mounted) {
      return;
    }
    if (ref.read(signupControllerProvider).failure == null) {
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.codeResent)));
    }
  }

  void _changeEmail() {
    _signup.changeEmail();
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.createAccount);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(signupControllerProvider);
    final failure = state.failure;
    return FormPage(
      title: l10n.codeTitle,
      children: [
        PageHeading(l10n.codeHeading),
        Gap.xs,
        BodyText(l10n.codeIntro),
        Gap.xs,
        FitText(state.email, style: Theme.of(context).textTheme.titleMedium),
        Gap.xs,
        BodyText(l10n.codeValidity),
        Gap.lg,
        if (state.codeRejected) ...[
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
          enabled: !state.busy,
          inputFormatters: const [DigitsOnlyFormatter()],
          onChanged: (_) => setState(() => _issue = null),
          onSubmitted: (_) => _verify(),
        ),
        Gap.lg,
        AppButton.primary(
          label: l10n.codeVerify,
          isLoading: state.busy,
          onPressed: _verify,
          expand: true,
        ),
        Gap.sm,
        ResendCountdown(
          availableAt: state.resendAvailableAt,
          busy: state.resending,
          onResend: _resend,
        ),
        AppButton.text(
          label: l10n.codeWrongEmail,
          onPressed: state.busy ? null : _changeEmail,
          expand: true,
        ),
        Gap.md,
        BodyText(l10n.codeSpamHint),
      ],
    );
  }
}
