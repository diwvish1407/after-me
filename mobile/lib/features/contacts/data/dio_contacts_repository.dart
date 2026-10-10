import 'package:dio/dio.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import 'contacts_repository.dart';

/// The contacts API over Dio (API_SPEC.md §7, `GET /me/entitlements`).
///
/// Mutating requests carry no `Idempotency-Key`: the server does not replay them, so
/// they are never retried automatically (the retry policy only repeats GET/HEAD and
/// keyed requests). A failed save is shown to the person, who decides to try again.
/// Request bodies hold names and addresses and are never logged.
class DioContactsRepository implements ContactsRepository {
  DioContactsRepository({required this.dio});

  final Dio dio;

  static String _path([String? id, String? suffix]) =>
      '/v1/contacts${id == null ? '' : '/${Uri.encodeComponent(id)}'}'
      '${suffix == null ? '' : '/$suffix'}';

  /// Runs [call], converting every error to an [AppFailure].
  Future<T> _run<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (error) {
      throw mapDioException(error);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      // Malformed success body (CheckedFromJsonException, cast errors, ...).
      throw UnknownFailure(cause: error);
    }
  }

  Map<String, dynamic> _object(Response<Object?> response) {
    final data = response.data;
    if (data is Map<String, dynamic>) {
      return data;
    }
    throw const FormatException('Expected a JSON object');
  }

  @override
  Future<List<TrustedContact>> list() => _run(() async {
    final response = await dio.get<Object?>(_path());
    return ContactList.fromJson(_object(response)).items;
  });

  @override
  Future<TrustedContact> create(ContactDraft draft) => _run(() async {
    final response = await dio.post<Object?>(_path(), data: draft.toJson());
    return TrustedContact.fromJson(_object(response));
  });

  @override
  Future<TrustedContact> get(String id) => _run(() async {
    final response = await dio.get<Object?>(_path(id));
    return TrustedContact.fromJson(_object(response));
  });

  @override
  Future<TrustedContact> update(String id, ContactPatch patch) =>
      _run(() async {
        final response = await dio.patch<Object?>(
          _path(id),
          data: patch.toJson(),
        );
        return TrustedContact.fromJson(_object(response));
      });

  @override
  Future<void> delete(String id) =>
      _run(() => dio.delete<Object?>(_path(id))).then((_) {});

  @override
  Future<void> resendInvitation(String id) =>
      _run(() => dio.post<Object?>(_path(id, 'invitation'))).then((_) {});

  @override
  Future<Entitlements> entitlements() => _run(() async {
    final response = await dio.get<Object?>('/v1/me/entitlements');
    return Entitlements.fromJson(_object(response));
  });
}
