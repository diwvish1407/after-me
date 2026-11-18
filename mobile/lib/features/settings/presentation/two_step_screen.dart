import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/repository_providers.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/design_system/app_button.dart';
import '../../../core/design_system/app_text_field.dart';
import '../../../core/design_system/brand.dart';
import '../../../core/design_system/form_page.dart';
import '../../../core/design_system/loading_view.dart';
import '../../../core/platform/clipboard_gateway.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../data/mfa_repository.dart';

final mfaStatusProvider = FutureProvider.autoDispose<MfaStatus>(
  (ref) => ref.watch(mfaRepositoryProvider).status(),
);

/// Two-step verification (design screen 12, "Security setup"): turn it on with an
/// authenticator app, see the recovery codes once, or turn it off.
class TwoStepScreen extends ConsumerStatefulWidget {
  const TwoStepScreen({super.key});

  @override
  ConsumerState<TwoStepScreen> createState() => _TwoStepScreenState();
}

class _TwoStepScreenState extends ConsumerState<TwoStepScreen> {
  final _code = TextEditingController();
  MfaSetup? _setup;
  List<String>? _recovery;
  bool _busy = false;
  AppFailure? _failure;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _failure = toAppFailure(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _start() => _run(() async {
    final setup = await withReauth(
      context,
      () => ref.read(mfaRepositoryProvider).setup(),
    );
    if (setup != null && mounted) {
      setState(() => _setup = setup);
    }
  });

  Future<void> _confirm() => _run(() async {
    final codes = await ref
        .read(mfaRepositoryProvider)
        .enable(_code.text.trim());
    _code.clear();
    if (mounted) {
      setState(() {
        _recovery = codes;
        _setup = null;
      });
    }
    ref.invalidate(mfaStatusProvider);
  });

  Future<void> _turnOff() async {
    final l10n = AppLocalizations.of(context);
    final field = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.twoStepTurnOffTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.twoStepTurnOffBody),
            Gap.md,
            AppTextField(label: l10n.signInCodeField, controller: field),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.adminCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(field.text.trim()),
            child: Text(l10n.twoStepTurnOff),
          ),
        ],
      ),
    );
    field.dispose();
    if (code == null || code.isEmpty || !mounted) {
      return;
    }
    await _run(() async {
      await withReauth(
        context,
        () => ref.read(mfaRepositoryProvider).disable(code),
      );
      ref.invalidate(mfaStatusProvider);
    });
  }

  Future<void> _copy(String text) async {
    final l10n = AppLocalizations.of(context);
    final ok = await ref.read(clipboardGatewayProvider).copy(text);
    if (ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.twoStepCopied)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final t = context.tokens;
    final status = ref.watch(mfaStatusProvider);
    final failure = _failure;
    final wrongCode =
        failure is UnauthorizedFailure && failure.code == 'invalid_otp';
    final recovery = _recovery;
    final setup = _setup;
    return BrandPage(
      title: l10n.twoStepTitle,
      children: [
        const Center(
          child: BrandImage(BrandIllustration.securityShield, height: 140),
        ),
        Gap.md,
        if (recovery != null)
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.twoStepRecoveryTitle, style: text.titleMedium),
                Gap.xs,
                Text(l10n.twoStepRecoveryBody, style: text.bodyMedium),
                Gap.md,
                SelectableText(
                  recovery.join('\n'),
                  style: text.titleMedium?.copyWith(
                    fontFamily: 'monospace',
                    letterSpacing: 1.5,
                  ),
                ),
                Gap.md,
                AppButton.secondary(
                  label: l10n.twoStepCopyCodes,
                  icon: Icons.copy_rounded,
                  onPressed: () => _copy(recovery.join('\n')),
                  expand: true,
                ),
                Gap.xs,
                AppButton.primary(
                  label: l10n.twoStepDone,
                  onPressed: () => setState(() => _recovery = null),
                  expand: true,
                ),
              ],
            ),
          )
        else if (setup != null)
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.twoStepKeyTitle, style: text.titleMedium),
                Gap.xs,
                Text(l10n.twoStepKeyBody, style: text.bodyMedium),
                Gap.md,
                SelectableText(
                  setup.secret.replaceAllMapped(
                    RegExp('.{4}'),
                    (m) => '${m[0]} ',
                  ),
                  style: text.titleMedium?.copyWith(fontFamily: 'monospace'),
                ),
                Gap.sm,
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _copy(setup.secret),
                      icon: const Icon(Icons.copy_rounded),
                      label: Text(l10n.twoStepCopyKey),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          await launchUrl(Uri.parse(setup.otpauthUri));
                        } on Object {
                          // No authenticator app: the key above can be typed in.
                        }
                      },
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: Text(l10n.twoStepOpenApp),
                    ),
                  ],
                ),
                Gap.md,
                AppTextField(
                  label: l10n.twoStepCodeField,
                  controller: _code,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  errorText: wrongCode ? l10n.twoStepInvalid : null,
                ),
                Gap.md,
                AppButton.primary(
                  label: l10n.twoStepConfirm,
                  onPressed: _busy ? null : _confirm,
                  isLoading: _busy,
                  expand: true,
                ),
              ],
            ),
          )
        else
          switch (status) {
            AsyncData(:final value) => GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        value.enabled
                            ? Icons.verified_user_rounded
                            : Icons.shield_outlined,
                        color: value.enabled ? t.ok : t.textMuted,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(l10n.twoStepTitle, style: text.titleMedium),
                      ),
                    ],
                  ),
                  Gap.sm,
                  Text(
                    value.enabled ? l10n.twoStepOnBody : l10n.twoStepOffBody,
                    style: text.bodyMedium,
                  ),
                  if (value.enabled) ...[
                    Gap.xs,
                    Text(
                      l10n.twoStepRecoveryLeft(value.recoveryCodesLeft),
                      style: text.bodySmall?.copyWith(color: t.textMuted),
                    ),
                  ],
                  Gap.md,
                  if (value.enabled)
                    AppButton.secondary(
                      label: l10n.twoStepTurnOff,
                      onPressed: _busy ? null : _turnOff,
                      expand: true,
                    )
                  else
                    AppButton.primary(
                      label: l10n.twoStepTurnOn,
                      onPressed: _busy ? null : _start,
                      isLoading: _busy,
                      expand: true,
                    ),
                ],
              ),
            ),
            AsyncError(:final error) => FailureNotice.of(
              context,
              toAppFailure(error),
            ),
            _ => const LoadingView(),
          },
        if (failure != null && !wrongCode) ...[
          Gap.md,
          FailureNotice.of(context, failure),
        ],
      ],
    );
  }
}
