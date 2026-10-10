import 'package:dio/dio.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import 'instructions_repository.dart';

/// The instructions API over Dio (API_SPEC.md §10).
///
/// Writes carry no `Idempotency-Key`: the server does not replay them, so they are never
/// retried automatically (the retry policy only repeats GET/HEAD and keyed requests). A
/// failed save is shown to the person, who decides to try again. Titles and bodies are
/// content: they are never logged, and a body is returned to the caller and not kept.
class DioInstructionsRepository implements InstructionsRepository {
  DioInstructionsRepository({required this.dio});

  final Dio dio;

  static String _path([String? id]) =>
      '/v1/instructions${id == null ? '' : '/${Uri.encodeComponent(id)}'}';

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
  Future<List<InstructionCategoryInfo>> categories() => _run(() async {
    final response = await dio.get<Object?>('/v1/instruction-categories');
    return InstructionCategoryList.fromJson(_object(response)).items;
  });

  @override
  Future<List<InstructionSummary>> list({InstructionCategory? category}) =>
      _run(() async {
        final response = await dio.get<Object?>(
          _path(),
          queryParameters: category == null
              ? null
              : <String, Object>{'category': category.id},
        );
        return InstructionList.fromJson(_object(response)).items;
      });

  @override
  Future<Instruction> get(String id) => _run(() async {
    final response = await dio.get<Object?>(_path(id));
    return Instruction.fromJson(_object(response));
  });

  @override
  Future<Instruction> create(InstructionDraft draft) => _run(() async {
    final response = await dio.post<Object?>(_path(), data: draft.toJson());
    return Instruction.fromJson(_object(response));
  });

  @override
  Future<Instruction> update(String id, InstructionPatch patch) =>
      _run(() async {
        final response = await dio.patch<Object?>(
          _path(id),
          data: patch.toJson(),
        );
        return Instruction.fromJson(_object(response));
      });

  @override
  Future<void> delete(String id) =>
      _run(() => dio.delete<Object?>(_path(id))).then((_) {});
}
