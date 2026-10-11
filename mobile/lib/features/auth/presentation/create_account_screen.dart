import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/device/device_info_source.dart';
import '../../../core/forms/validators.dart';
import '../../../core/pickers/pickers.dart';
import '../../../core/security/secure_screen.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/signup_controller.dart';
import 'legal_links.dart';

/// USER_FLOWS.md §3 step 2: name, email, password, timezone, consent.
class CreateAccountScreen extends ConsumerStatefulWidget {
  const CreateAccountScreen({super.key});

  @override
  ConsumerState<CreateAccountScreen> createState() =>
      _CreateAccountScreenState();
}

class _CreateAccountScreenState extends ConsumerState<CreateAccountScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  late final SignupController _signup;

  String _timezone = 'UTC';
  bool _timezoneDetected = false;
  bool _adult = false;
  bool _agreed = false;
  bool _submitted = false;

  FieldIssue? _nameIssue;
  FieldIssue? _emailIssue;
  FieldIssue? _passwordIssue;

  @override
  void initState() {
    super.initState();
    _signup = ref.read(signupControllerProvider.notifier);
    // The controller outlives this screen: a failure from an earlier visit must not
    // greet a fresh form. Only on the form stage; a verification in progress keeps it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          ref.read(signupControllerProvider).stage == SignupStage.form) {
        _signup.clearFailure();
      }
    });
    _detectTimezone();
  }

  Future<void> _detectTimezone() async {
    final detected = await ref.read(deviceInfoSourceProvider).timezone();
    if (!mounted || _timezoneDetected) {
      return;
    }
    if (detected != null && detected.isNotEmpty) {
      setState(() => _timezone = detected);
    }
  }

  @override
  void dispose() {
    // Leaving the screens ends the flow: forget the password.
    _signup.abandon();
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  bool _validate() {
    setState(() {
      _submitted = true;
      _nameIssue = Validators.displayName(_name.text);
      _emailIssue = Validators.email(_email.text);
      _passwordIssue = Validators.newPassword(
        _password.text,
        email: _email.text,
      );
    });
    return _nameIssue == null &&
        _emailIssue == null &&
        _passwordIssue == null &&
        _adult &&
        _agreed;
  }

  Future<void> _submit() async {
    if (!_validate()) {
      return;
    }
    FocusScope.of(context).unfocus();
    final started = await _signup.start(
      displayName: _name.text.trim(),
      email: Validators.cleanEmail(_email.text),
      password: _password.text,
      timezone: _timezone,
    );
    if (started && mounted) {
      unawaited(context.push<void>(AppRoutes.verifyCode));
    }
  }

  Future<void> _changeTimezone() async {
    final available = await ref
        .read(deviceInfoSourceProvider)
        .availableTimezones();
    if (!mounted) {
      return;
    }
    final chosen = await pickTimezone(
      context,
      available: available,
      selected: _timezone,
    );
    if (chosen != null && mounted) {
      setState(() {
        _timezone = chosen;
        _timezoneDetected = true;
      });
    }
  }

  /// A server-side field error that the device checks did not catch.
  FieldIssue? _serverIssue(AppFailure? failure, String field) {
    if (failure is ValidationFailure) {
      return issueForField(failure.fieldErrors, field);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final state = ref.watch(signupControllerProvider);
    final failure = state.failure;
    final serverName = _serverIssue(failure, 'display_name');
    final serverEmail = _serverIssue(failure, 'email');
    final serverPassword = _serverIssue(failure, 'password');
    final handledByField =
        serverName != null || serverEmail != null || serverPassword != null;
    final strength = passwordStrength(_password.text, email: _email.text);

    String? errorOf(FieldIssue? local, FieldIssue? server) {
      final issue = local ?? server;
      return issue == null ? null : issueMessage(l10n, issue);
    }

    return SecureScreen(
      child: FormPage(
        title: l10n.createAccountTitle,
        children: [
          PageHeading(l10n.createAccountHeading),
          Gap.xs,
          BodyText(l10n.createAccountIntro),
          Gap.lg,
          if (failure != null && !handledByField) ...[
            FailureNotice.of(context, failure),
            Gap.md,
          ],
          AppTextField(
            label: l10n.fieldName,
            controller: _name,
            errorText: errorOf(_nameIssue, serverName),
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.givenName],
            textCapitalization: TextCapitalization.words,
            enabled: !state.busy,
            onChanged: (_) => setState(() => _nameIssue = null),
          ),
          Gap.md,
          AppTextField(
            label: l10n.fieldEmail,
            controller: _email,
            errorText: errorOf(_emailIssue, serverEmail),
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
            enabled: !state.busy,
            onChanged: (_) => setState(() => _emailIssue = null),
          ),
          Gap.md,
          AppTextField(
            label: l10n.fieldPassword,
            controller: _password,
            obscureText: true,
            errorText: errorOf(_passwordIssue, serverPassword),
            helperText: passwordStrengthHint(l10n, strength),
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.newPassword],
            enabled: !state.busy,
            onChanged: (_) => setState(() => _passwordIssue = null),
            onSubmitted: (_) => _submit(),
          ),
          Gap.md,
          _TimezoneRow(
            timezone: _timezone,
            onChange: state.busy ? null : _changeTimezone,
          ),
          Gap.sm,
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _adult,
            onChanged: state.busy
                ? null
                : (value) => setState(() => _adult = value ?? false),
            title: Text(l10n.consentAdult),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _agreed,
            onChanged: state.busy
                ? null
                : (value) => setState(() => _agreed = value ?? false),
            title: Text(l10n.consentTerms),
          ),
          const LegalLinks(),
          if (_submitted && (!_adult || !_agreed)) ...[
            Gap.xs,
            Semantics(
              liveRegion: true,
              child: Text(
                l10n.consentRequired,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: t.escalation),
              ),
            ),
          ],
          Gap.lg,
          AppButton.primary(
            label: l10n.createAccountSubmit,
            isLoading: state.busy,
            onPressed: _submit,
            expand: true,
          ),
          Gap.xs,
          AppButton.text(
            label: l10n.createAccountHaveAccount,
            onPressed: () => context.push(AppRoutes.signIn),
            expand: true,
          ),
          Gap.md,
          _PrivacyNote(text: l10n.createAccountPasswordNote),
        ],
      ),
    );
  }
}

class _TimezoneRow extends StatelessWidget {
  const _TimezoneRow({required this.timezone, required this.onChange});

  final String timezone;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.public_rounded, color: t.textMuted),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Semantics(
                label: '${l10n.timezoneYours}: $timezone',
                excludeSemantics: true,
                child: FitText(
                  timezone,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ],
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: AppButton.text(
            label: l10n.timezoneChange,
            onPressed: onChange,
          ),
        ),
      ],
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline_rounded, size: 20, color: t.textMuted),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: t.textMuted),
          ),
        ),
      ],
    );
  }
}
