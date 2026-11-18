import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/auth/session_ended_notice.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/device/device_info_source.dart';
import '../../../core/forms/validators.dart';
import '../../../core/security/secure_screen.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/login_controller.dart';
import '../data/google_sign_in_gateway.dart';

/// Sign in with email and password. A not-yet-verified account continues with its code.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();

  /// Two-step verification asked for a code (after a right password, or after Google).
  bool _needsCode = false;

  /// The Google ID token kept for the second step of a Google sign-in.
  String? _googleToken;
  bool _googleUnavailable = false;
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
    _code.dispose();
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
    if (_googleToken != null) {
      await _google();
      return;
    }
    final result = await ref
        .read(loginControllerProvider.notifier)
        .signIn(
          email: Validators.cleanEmail(_email.text),
          password: _password.text,
          otp: _needsCode ? _code.text.trim() : null,
        );
    if (!mounted) {
      return;
    }
    if (result == LoginResult.needsCode) {
      setState(() => _needsCode = true);
      return;
    }
    if (result == LoginResult.needsVerification) {
      unawaited(context.push<void>(AppRoutes.verifyCode));
    }
    // LoginResult.signedIn: the router leaves this screen by itself.
  }

  Future<void> _google() async {
    if (!ref.read(googleSignInGatewayProvider).configured) {
      setState(() => _googleUnavailable = true);
      return;
    }
    final (result, token) = await ref
        .read(loginControllerProvider.notifier)
        .signInWithGoogle(
          timezone:
              await ref.read(deviceInfoSourceProvider).timezone() ?? 'UTC',
          idToken: _googleToken,
          otp: _googleToken != null && _needsCode ? _code.text.trim() : null,
        );
    if (!mounted) {
      return;
    }
    setState(() {
      _googleToken = result == LoginResult.needsCode ? token : null;
      _needsCode = result == LoginResult.needsCode;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(loginControllerProvider);
    final failure = state.failure;
    final text = Theme.of(context).textTheme;
    final t = context.tokens;
    final wrongCode =
        failure is UnauthorizedFailure && failure.code == 'invalid_otp';
    final googleOff =
        _googleUnavailable ||
        (failure is ServerFailure &&
            failure.problem?.code == 'google_unavailable');
    return SecureScreen(
      child: Scaffold(
        appBar: BrandAppBar(title: l10n.signInTitle),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
            children: [
              // The hero continues the app bar's gradient.
              Container(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  AppSpacing.sm,
                  AppSpacing.page,
                  AppSpacing.xl,
                ),
                decoration: const BoxDecoration(gradient: brandHeaderGradient),
                child: Column(
                  children: [
                    const LogoMark(size: 72),
                    const SizedBox(height: AppSpacing.sm),
                    const Wordmark(fontSize: 36),
                    Text(
                      l10n.tagline,
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(color: Colors.white),
                    ),
                  ],
                ),
              ),
              Transform.translate(
                offset: const Offset(0, -AppSpacing.md),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.page,
                  ),
                  child: GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        PageHeading(
                          _needsCode
                              ? l10n.signInCodeTitle
                              : l10n.signInWelcomeBack,
                        ),
                        Text(
                          _needsCode
                              ? l10n.signInCodeBody
                              : l10n.signInWelcomeBody,
                          style: text.bodyMedium?.copyWith(color: t.textMuted),
                        ),
                        Gap.lg,
                        if (ref.watch(sessionEndedNoticeProvider)) ...[
                          StatusBanner(
                            kind: StatusBannerKind.info,
                            message: l10n.errorSessionExpired,
                            liveRegion: true,
                          ),
                          Gap.md,
                        ],
                        if (failure != null && !wrongCode && !googleOff) ...[
                          FailureNotice(
                            message: failure is UnauthorizedFailure
                                ? l10n.signInWrongDetails
                                : failureMessage(l10n, failure),
                          ),
                          Gap.md,
                        ],
                        if (googleOff) ...[
                          StatusBanner(
                            kind: StatusBannerKind.info,
                            message: l10n.signInGoogleUnavailable,
                            liveRegion: true,
                          ),
                          Gap.md,
                        ],
                        if (_needsCode) ...[
                          AppTextField(
                            label: l10n.signInCodeField,
                            controller: _code,
                            errorText: wrongCode ? l10n.twoStepInvalid : null,
                            keyboardType: TextInputType.visiblePassword,
                            autofillHints: const [AutofillHints.oneTimeCode],
                            autofocus: true,
                            enabled: !state.busy,
                            textInputAction: TextInputAction.done,
                            onChanged: (_) => ref
                                .read(loginControllerProvider.notifier)
                                .clearFailure(),
                            onSubmitted: (_) => _submit(),
                          ),
                        ] else ...[
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
                              ref
                                  .read(loginControllerProvider.notifier)
                                  .clearFailure();
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
                              ref
                                  .read(loginControllerProvider.notifier)
                                  .clearFailure();
                              setState(() => _passwordIssue = null);
                            },
                            onSubmitted: (_) => _submit(),
                          ),
                          Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: AppButton.text(
                              label: l10n.signInForgot,
                              onPressed: state.busy
                                  ? null
                                  : () => context.push(
                                      AppRoutes.forgotPassword,
                                      extra: _email.text.trim(),
                                    ),
                            ),
                          ),
                        ],
                        Gap.md,
                        AppButton.primary(
                          label: _needsCode
                              ? l10n.signInCodeSubmit
                              : l10n.signInSubmit,
                          icon: Icons.arrow_forward_rounded,
                          isLoading: state.busy,
                          onPressed: _submit,
                          expand: true,
                        ),
                        if (!_needsCode) ...[
                          Gap.md,
                          Row(
                            children: [
                              const Expanded(child: Divider()),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.sm,
                                ),
                                child: Text(
                                  l10n.signInOr,
                                  style: text.bodySmall?.copyWith(
                                    color: t.textMuted,
                                  ),
                                ),
                              ),
                              const Expanded(child: Divider()),
                            ],
                          ),
                          Gap.md,
                          OutlinedButton.icon(
                            onPressed: state.busy ? null : _google,
                            icon: const Icon(
                              Icons.g_mobiledata_rounded,
                              size: 28,
                            ),
                            label: Text(l10n.signInGoogle),
                          ),
                          Gap.sm,
                          AppButton.text(
                            label: l10n.signInCreateAccount,
                            onPressed: state.busy
                                ? null
                                : () => context.push(AppRoutes.createAccount),
                            expand: true,
                          ),
                        ] else
                          AppButton.text(
                            label: l10n.back,
                            onPressed: state.busy
                                ? null
                                : () => setState(() {
                                    _needsCode = false;
                                    _googleToken = null;
                                    _code.clear();
                                  }),
                            expand: true,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
