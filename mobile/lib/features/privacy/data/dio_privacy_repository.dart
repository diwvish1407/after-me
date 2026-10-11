import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import 'privacy_repository.dart';

/// The largest export this app will take into memory (32 MiB). A real export is far
/// smaller: it is text. A bigger answer is stopped while it arrives instead of being
/// held in memory.
const int maxExportBytes = 32 * 1024 * 1024;

/// `POST /v1/me/export` and `DELETE /v1/me` over Dio.
///
/// Neither request is idempotent and neither carries an `Idempotency-Key`, so the API
/// client never repeats them by itself. The export is read as **bytes**: an error body
/// arrives as bytes too and is read by the same failure mapper as any problem.
class DioPrivacyRepository implements PrivacyRepository {
  DioPrivacyRepository({required this.dio, this.maxBytes = maxExportBytes});

  final Dio dio;

  /// The size above which an export is refused (tests lower it).
  final int maxBytes;

  @override
  Future<Uint8List> exportData() async {
    final cancel = CancelToken();
    try {
      final response = await dio.post<List<int>>(
        '/v1/me/export',
        options: Options(
          responseType: ResponseType.bytes,
          // Building the document can take a while on the server.
          receiveTimeout: const Duration(seconds: 90),
        ),
        cancelToken: cancel,
        onReceiveProgress: (received, total) {
          if (received > maxBytes || total > maxBytes) {
            cancel.cancel('export too large');
          }
        },
      );
      final data = response.data;
      if (data == null || data.isEmpty) {
        throw const FormatException('The export is empty');
      }
      final bytes = data is Uint8List ? data : Uint8List.fromList(data);
      if (bytes.length > maxBytes) {
        throw const ExportTooLargeException();
      }
      if (!_looksLikeJsonObject(bytes)) {
        // A proxy's page or anything else: nothing is offered for saving.
        throw const FormatException('The export is not a JSON document');
      }
      return bytes;
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel && cancel.isCancelled) {
        throw const ExportTooLargeException();
      }
      throw mapDioException(error);
    } on ExportTooLargeException {
      rethrow;
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw UnknownFailure(cause: error);
    }
  }

  /// The first byte that is not white space is `{`.
  static bool _looksLikeJsonObject(Uint8List bytes) {
    for (final byte in bytes) {
      if (byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09) {
        continue;
      }
      return byte == 0x7B;
    }
    return false;
  }

  @override
  Future<AccountDeletion> deleteAccount() async {
    try {
      final response = await dio.delete<Object?>(
        '/v1/me',
        data: const <String, Object?>{'confirm': 'DELETE'},
      );
      // The 202 is the confirmation. The body only says when the rest is purged; a body
      // that cannot be read does not make the deletion any less done.
      final data = response.data;
      DateTime? purgeAfter;
      if (data is Map) {
        final raw = data['purge_after'];
        purgeAfter = raw is String ? DateTime.tryParse(raw) : null;
      }
      return AccountDeletion(purgeAfter: purgeAfter);
    } on DioException catch (error) {
      throw mapDioException(error);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw UnknownFailure(cause: error);
    }
  }
}
