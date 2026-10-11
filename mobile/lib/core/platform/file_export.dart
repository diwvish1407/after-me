import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What happened to a file handed to the system for saving.
enum FileExportResult {
  /// The system wrote the file where the person chose. Only this may be called "saved".
  saved,

  /// The person closed the system's save dialog without choosing a place.
  cancelled,
}

/// Why a file could not be handed over or written.
enum FileExportError {
  /// This device has nothing that can save a file (no document provider).
  unavailable,

  /// The system could not write the file where the person chose.
  failed,
}

class FileExportException implements Exception {
  const FileExportException(this.error);

  final FileExportError error;

  @override
  String toString() => 'FileExportException($error)';
}

/// Hands a file's bytes to the system so the **person** chooses where it is saved
/// (USER_FLOWS.md §11 export). It uses Android's Storage Access Framework
/// (`ACTION_CREATE_DOCUMENT`): no storage permission, and nothing is kept in the app's
/// own storage.
///
/// [save] completes with [FileExportResult.saved] only after the system has written the
/// file. The bytes are not logged, cached or kept by this class.
abstract interface class FileExportGateway {
  /// Throws [FileExportException] when nothing can save the file or the write failed.
  Future<FileExportResult> save({
    required Uint8List bytes,
    required String suggestedName,
    String mimeType,
  });
}

/// The platform implementation: a tiny `MethodChannel` handled by `MainActivity`
/// (`app.afterme/export`, method `saveFile`).
class PlatformFileExportGateway implements FileExportGateway {
  const PlatformFileExportGateway();

  static const MethodChannel _channel = MethodChannel('app.afterme/export');

  @override
  Future<FileExportResult> save({
    required Uint8List bytes,
    required String suggestedName,
    String mimeType = 'application/json',
  }) async {
    try {
      final answer = await _channel.invokeMethod<Object?>('saveFile', {
        'bytes': bytes,
        'name': suggestedName,
        'mimeType': mimeType,
      });
      return switch (answer) {
        'saved' => FileExportResult.saved,
        'cancelled' => FileExportResult.cancelled,
        // Anything else is not a confirmation: never report "saved" for it.
        _ => throw const FileExportException(FileExportError.failed),
      };
    } on MissingPluginException {
      // Not running on Android (tests, desktop previews).
      throw const FileExportException(FileExportError.unavailable);
    } on PlatformException catch (error) {
      throw FileExportException(
        error.code == 'unavailable'
            ? FileExportError.unavailable
            : FileExportError.failed,
      );
    }
  }
}

final fileExportGatewayProvider = Provider<FileExportGateway>(
  (ref) => const PlatformFileExportGateway(),
);
