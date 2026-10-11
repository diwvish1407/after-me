import 'dart:convert';
import 'dart:typed_data';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/platform/file_export.dart';
import 'package:afterme/features/privacy/data/privacy_repository.dart';

import 'fake_auth_repository.dart';

/// The export and deletion "server": it keeps the rules that matter to the app.
///
/// * Both need the password to have been entered in the last 60 seconds (`403
///   reauth_required` otherwise); an export **spends** that confirmation.
/// * The export is limited to 3 an hour (`429`).
/// * After a deletion every request is a 401.
/// * Failures (`export`, `delete`) can be scripted; with [loseAnswer] the action is
///   carried out but its answer never arrives (a network error), like a dropped
///   connection after the server did its work.
class FakePrivacyRepository implements PrivacyRepository {
  FakePrivacyRepository({required this.auth, required this.clock});

  final FakeAuthRepository auth;
  final DateTime Function() clock;

  /// The bytes the export returns.
  Uint8List exportBytes = Uint8List.fromList(
    utf8.encode('{"format_version":1,"instructions":[]}'),
  );

  /// Throws [ExportTooLargeException] instead of returning bytes.
  bool tooLarge = false;

  /// Exports per hour before a 429.
  int exportsPerHour = 3;

  final List<String> calls = [];
  final List<DateTime> _exports = [];
  int _spentCount = 0;

  /// The deletion was carried out.
  bool deleted = false;

  /// The purge date the 202 carries.
  DateTime purgeAfter = DateTime.utc(2026, 11, 7, 9, 2, 40);

  /// Failures thrown by the next calls, consumed in order, before anything is done.
  final Map<String, List<AppFailure>> failures = {};

  /// The next call is carried out, then answered with a network error.
  bool loseAnswer = false;

  /// Waits before answering (to show the sending state).
  Future<void>? gate;

  bool get _fresh {
    final at = auth.lastReauthAt;
    if (at == null || auth.reauthCount <= _spentCount) {
      return false;
    }
    return clock().difference(at) <= const Duration(seconds: 60);
  }

  AppFailure _reauthRequired() => const ForbiddenFailure(
    code: 'reauth_required',
    problem: ApiProblem(status: 403, code: 'reauth_required'),
  );

  Future<void> _enter(String call) async {
    calls.add(call);
    await gate;
    final queue = failures[call];
    if (queue != null && queue.isNotEmpty) {
      throw queue.removeAt(0);
    }
    if (deleted) {
      throw const UnauthorizedFailure(code: 'session_revoked');
    }
  }

  @override
  Future<Uint8List> exportData() async {
    await _enter('export');
    if (!_fresh) {
      throw _reauthRequired();
    }
    final cutoff = clock().subtract(const Duration(hours: 1));
    _exports.removeWhere((at) => at.isBefore(cutoff));
    if (_exports.length >= exportsPerHour) {
      throw const RateLimitedFailure(retryAfter: Duration(minutes: 40));
    }
    if (tooLarge) {
      throw const ExportTooLargeException();
    }
    _exports.add(clock());
    _spentCount = auth.reauthCount;
    if (loseAnswer) {
      loseAnswer = false;
      throw const NetworkFailure();
    }
    return exportBytes;
  }

  @override
  Future<AccountDeletion> deleteAccount() async {
    await _enter('delete');
    if (!_fresh) {
      throw _reauthRequired();
    }
    deleted = true;
    _spentCount = auth.reauthCount;
    if (loseAnswer) {
      loseAnswer = false;
      throw const NetworkFailure();
    }
    return AccountDeletion(purgeAfter: purgeAfter);
  }
}

/// A scriptable save dialog: records what it was given and answers as scripted.
class FakeFileExportGateway implements FileExportGateway {
  /// Answers consumed in order; [FileExportResult.saved] when empty.
  final List<Object> answers = [];

  /// What was handed over, in order.
  final List<({Uint8List bytes, String name, String mimeType})> saves = [];

  /// Waits before answering (the dialog is open).
  Future<void>? gate;

  @override
  Future<FileExportResult> save({
    required Uint8List bytes,
    required String suggestedName,
    String mimeType = 'application/json',
  }) async {
    saves.add((bytes: bytes, name: suggestedName, mimeType: mimeType));
    await gate;
    if (answers.isEmpty) {
      return FileExportResult.saved;
    }
    final answer = answers.removeAt(0);
    if (answer is FileExportResult) {
      return answer;
    }
    throw answer;
  }
}
