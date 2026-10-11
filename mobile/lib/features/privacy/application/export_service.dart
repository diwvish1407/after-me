import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/platform/file_export.dart';
import '../data/privacy_repository.dart';

/// The name offered in the system's save dialog.
const exportFileName = 'afterme-export.json';

/// The two steps of "Export my data": ask the server for the file, hand it to the system.
///
/// The bytes only pass through: they are returned to the caller, given to the system's
/// save dialog and dropped. They are never decoded, logged, cached, or kept here.
class ExportService {
  ExportService(this._ref);

  final Ref _ref;

  /// `POST /v1/me/export`. Throws an `AppFailure` (a 403 `reauth_required` is what
  /// `withReauth` reacts to) or `ExportTooLargeException`.
  Future<Uint8List> fetch() async {
    try {
      return await _ref.read(privacyRepositoryProvider).exportData();
    } on ExportTooLargeException {
      rethrow;
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  /// Opens the system save dialog. [FileExportResult.saved] is returned only once the
  /// system has written the file. Throws `FileExportException`.
  Future<FileExportResult> save(Uint8List bytes) => _ref
      .read(fileExportGatewayProvider)
      .save(
        bytes: bytes,
        suggestedName: exportFileName,
        mimeType: 'application/json',
      );
}

final exportServiceProvider = Provider<ExportService>(ExportService.new);
