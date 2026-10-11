import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/platform/file_export.dart';
import '../../../core/security/app_lock/app_lock_controller.dart';
import '../../../core/security/secure_screen.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../application/export_service.dart';
import '../data/privacy_repository.dart';

/// What the screen last did, in words the person can act on.
enum _Outcome {
  none,
  saved,
  cancelled,
  tooLarge,
  noSaveApp,
  saveFailed,
  requestFailed,
}

/// Settings > Privacy and data > Export my data (USER_FLOWS.md §11, SECURITY.md §19).
///
/// The file holds the decrypted instructions, so the screen says that **before** it asks
/// for anything. Then: the password (`withReauth`), `POST /v1/me/export` at once (the
/// confirmation lasts 60 seconds and one export spends it), and the bytes go straight to
/// the system's save dialog, where the person chooses the place. "Saved" is said only
/// after the system confirmed the write. The bytes are never decoded, logged, cached or
/// kept; closing the screen while the file is on its way drops them.
class ExportDataScreen extends ConsumerStatefulWidget {
  const ExportDataScreen({super.key});

  @override
  ConsumerState<ExportDataScreen> createState() => _ExportDataScreenState();
}

class _ExportDataScreenState extends ConsumerState<ExportDataScreen> {
  bool _requesting = false;
  bool _saving = false;
  _Outcome _outcome = _Outcome.none;
  AppFailure? _failure;

  bool get _busy => _requesting || _saving;

  Future<void> _export() async {
    if (_busy) {
      return;
    }
    setState(() {
      _requesting = true;
      _outcome = _Outcome.none;
      _failure = null;
    });
    final service = ref.read(exportServiceProvider);
    Uint8List? bytes;
    try {
      bytes = await withReauth<Uint8List>(
        context,
        service.fetch,
        reason: ReauthReason.exportData,
      );
    } on ExportTooLargeException {
      _finish(_Outcome.tooLarge);
      return;
    } on AppFailure catch (failure) {
      _finish(_Outcome.requestFailed, failure: failure);
      return;
    }
    if (bytes == null || !mounted) {
      // The password sheet was dismissed (nothing was asked of the server), or the
      // screen was left: the file is dropped, nothing is saved behind the person's back.
      _finish(_Outcome.none);
      return;
    }
    final file = bytes;
    setState(() {
      _requesting = false;
      _saving = true;
    });
    try {
      // The system's save screen takes the app out of the foreground, which must not
      // lock it (like the contact picker and the permission dialogs).
      final result = await ref
          .read(appLockControllerProvider.notifier)
          .runWithoutLocking(() => service.save(file));
      _finish(
        result == FileExportResult.saved ? _Outcome.saved : _Outcome.cancelled,
      );
    } on FileExportException catch (error) {
      _finish(
        error.error == FileExportError.unavailable
            ? _Outcome.noSaveApp
            : _Outcome.saveFailed,
      );
    }
  }

  void _finish(_Outcome outcome, {AppFailure? failure}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _requesting = false;
      _saving = false;
      _outcome = outcome;
      _failure = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final failure = _failure;
    return SecureScreen(
      child: FormPage(
        title: l10n.settingsExport,
        children: [
          PageHeading(l10n.settingsExport),
          Gap.xs,
          BodyText(l10n.exportIntro),
          Gap.md,
          StatusBanner(
            kind: StatusBannerKind.attention,
            title: l10n.exportWarningTitle,
            message: l10n.exportWarning,
          ),
          Gap.md,
          Text(l10n.exportWhere),
          Gap.xs,
          BodyText(l10n.exportNeedsPassword),
          Gap.lg,
          if (_requesting || _saving) ...[
            Semantics(
              liveRegion: true,
              container: true,
              child: StatusBanner(
                kind: StatusBannerKind.info,
                message: _saving ? l10n.exportSaving : l10n.exportWorking,
              ),
            ),
            Gap.md,
          ],
          if (_outcome != _Outcome.none) ...[
            Semantics(
              liveRegion: true,
              container: true,
              child: switch (_outcome) {
                _Outcome.saved => StatusBanner(
                  kind: StatusBannerKind.ok,
                  message: l10n.exportSaved,
                ),
                _Outcome.cancelled => StatusBanner(
                  kind: StatusBannerKind.info,
                  message: l10n.exportCancelled,
                ),
                _Outcome.tooLarge => FailureNotice(
                  message: l10n.exportTooLarge,
                ),
                _Outcome.noSaveApp => FailureNotice(
                  message: l10n.exportNoSaveApp,
                ),
                _Outcome.saveFailed => FailureNotice(
                  message: l10n.exportSaveFailed,
                ),
                _Outcome.requestFailed => FailureNotice(
                  message: actionFailureMessage(
                    l10n,
                    failure ?? const UnknownFailure(),
                    UnconfirmedAction.export,
                  ),
                ),
                _Outcome.none => const SizedBox.shrink(),
              },
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          AppButton.primary(
            label: l10n.exportButton,
            icon: Icons.download_outlined,
            isLoading: _busy,
            onPressed: _busy ? null : () => unawaited(_export()),
            expand: true,
          ),
        ],
      ),
    );
  }
}
