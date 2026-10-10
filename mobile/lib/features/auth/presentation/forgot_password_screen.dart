import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/forms/validators.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/forgot_password_controller.dart';

/// Request a reset link. The link opens a web page (the reset happens there, never in
/// the app), and the answer is the same whether or not an account exists.
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({this.initialEmail, super.key});

  /// Prefilled from the sign-in form or the account, when known.
  final String? initialEmail;

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  late final TextEditingController _email = TextEditingController(
    text: widget.initialEmail ?? '',
  );
  FieldIssue? _issue;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final issue = Validators.email(_email.text);
    setState(() => _issue = issue);
    if (issue != null) {
      return;
    }
    FocusScope.of(context).unfocus();
    await ref
        .read(forgotPasswordControllerProvider.notifier)
        .submit(Validators.cleanEmail(_email.text));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(forgotPasswordControllerProvider);
    if (state.sent) {
      final t = context.tokens;
      return FormPage(
        title: l10n.forgotTitle,
        children: [
          Icon(Icons.mark_email_read_outlined, size: 48, color: t.primary),
          Gap.md,
          Semantics(
            header: true,
            liveRegion: true,
            child: Text(
              l10n.forgotSentHeading,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          Gap.sm,
          FitText(
            Validators.cleanEmail(_email.text),
            style: Theme.of(context).textTheme.titleMedium,
            alignment: Alignment.center,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(l10n.forgotSentBody, textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.sm),
          BodyText(l10n.forgotSentSteps, textAlign: TextAlign.center),
          Gap.lg,
          AppButton.primary(
            label: l10n.forgotBackToSignIn,
            onPressed: () =>
                context.canPop() ? context.pop() : context.go(AppRoutes.signIn),
            expand: true,
          ),
          Gap.xs,
          AppButton.text(
            label: l10n.forgotDifferentEmail,
            onPressed: () =>
                ref.read(forgotPasswordControllerProvider.notifier).reset(),
            expand: true,
          ),
        ],
      );
    }
    return FormPage(
      title: l10n.forgotTitle,
      children: [
        PageHeading(l10n.forgotHeading),
        Gap.xs,
        BodyText(l10n.forgotIntro),
        Gap.lg,
        if (state.failure != null) ...[
          FailureNotice.of(context, state.failure!),
          Gap.md,
        ],
        AppTextField(
          label: l10n.fieldEmail,
          controller: _email,
          errorText: _issue == null ? null : issueMessage(l10n, _issue!),
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.email],
          enabled: !state.busy,
          onChanged: (_) => setState(() => _issue = null),
          onSubmitted: (_) => _submit(),
        ),
        Gap.lg,
        AppButton.primary(
          label: l10n.forgotSubmit,
          isLoading: state.busy,
          onPressed: _submit,
          expand: true,
        ),
      ],
    );
  }
}
