import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/features/activity/data/activity_repository.dart';

/// The Activity "server": a list of entries (newest first) served in pages with opaque
/// cursors, like `GET /v1/activity`. Failures can be scripted per call.
class FakeActivityServer implements ActivityRepository {
  /// Newest first.
  List<ActivityItem> items = [];

  /// A cursor the server does not accept answers 422 (`cursor` `invalid`).
  final List<String> issuedCursors = [];

  /// Failures thrown by the next calls to `list`, consumed in order.
  final List<AppFailure> failures = [];

  /// One entry per call: `limit` and `cursor`.
  final List<({int limit, String? cursor})> calls = [];

  /// Waits before answering (to show the loading state).
  Future<void>? gate;

  @override
  Future<ActivityPage> list({int limit = 20, String? cursor}) async {
    calls.add((limit: limit, cursor: cursor));
    await gate;
    if (failures.isNotEmpty) {
      throw failures.removeAt(0);
    }
    var start = 0;
    if (cursor != null) {
      if (!issuedCursors.contains(cursor)) {
        throw const ValidationFailure(code: 'validation_failed');
      }
      start = int.parse(cursor.substring('cursor-'.length));
    }
    final end = (start + limit).clamp(0, items.length);
    final next = end < items.length ? 'cursor-$end' : null;
    if (next != null && !issuedCursors.contains(next)) {
      issuedCursors.add(next);
    }
    return ActivityPage(items: items.sublist(start, end), nextCursor: next);
  }
}

/// An entry as the server sends it.
ActivityItem activityItem(
  String action, {
  int id = 1,
  DateTime? at,
  Map<String, dynamic> params = const <String, dynamic>{},
}) => ActivityItem(
  id: id,
  action: action,
  occurredAt: at ?? DateTime.utc(2026, 10, 8, 9),
  params: params,
);
