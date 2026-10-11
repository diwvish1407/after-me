import 'package:flutter/foundation.dart';

/// One entry of the Activity feed (`GET /v1/activity`, API_SPEC.md §11): something that
/// happened on the account and is shown to its owner.
///
/// The server sends **what happened**, not a sentence: the app composes the words from
/// [action] and [params] (`describeActivity`). So that a newer server never breaks an
/// older app, nothing here is strict:
///
/// * an [action] this version does not know is kept as it is (it is shown as "Something
///   changed on your account", never hidden);
/// * [params] holds whatever the server sent for the action; a key that is missing, `null`
///   or of an unexpected type reads as "not there" (`contact_display_name` and
///   `instruction_title` are `null` when the name or title could not be opened);
/// * unknown fields are ignored.
@immutable
class ActivityItem {
  const ActivityItem({
    required this.action,
    required this.occurredAt,
    this.id,
    this.params = const <String, dynamic>{},
  });

  /// The audit row's number: stable and increasing, used only to tell entries apart.
  final int? id;

  /// Dotted action name, `checkin.recorded`, `release.viewed`, ...
  final String action;

  final DateTime occurredAt;

  /// The action's parameters. Never null; may be empty.
  final Map<String, dynamic> params;

  /// The entry in [json], or null when it has no readable time (nothing to place it by)
  /// or is not an object. A missing or non-text `action` becomes the empty string, which
  /// is shown generically.
  static ActivityItem? tryFromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final at = json['occurred_at'];
    final occurredAt = at is String ? DateTime.tryParse(at) : null;
    if (occurredAt == null) {
      return null;
    }
    final action = json['action'];
    final id = json['id'];
    final params = json['params'];
    return ActivityItem(
      id: id is num ? id.toInt() : null,
      action: action is String ? action : '',
      occurredAt: occurredAt,
      params: params is Map
          ? <String, dynamic>{
              for (final entry in params.entries) '${entry.key}': entry.value,
            }
          : const <String, dynamic>{},
    );
  }

  /// Shown names and titles never reach a log.
  @override
  String toString() => 'ActivityItem($action)';

  @override
  bool operator ==(Object other) =>
      other is ActivityItem &&
      other.id == id &&
      other.action == action &&
      other.occurredAt == occurredAt &&
      mapEquals(other.params, params);

  @override
  int get hashCode => Object.hash(id, action, occurredAt, params.length);
}

/// One page of `GET /v1/activity` (newest first). [nextCursor] is opaque and null on the
/// last page.
@immutable
class ActivityPage {
  const ActivityPage({this.items = const <ActivityItem>[], this.nextCursor});

  final List<ActivityItem> items;
  final String? nextCursor;

  /// Reads a response body. Entries that cannot be read at all (not an object, no time)
  /// are left out; everything else is kept. Throws [FormatException] when [json] is not
  /// an object, so a damaged answer is never taken for an empty feed.
  factory ActivityPage.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('Expected a JSON object');
    }
    final raw = json['items'];
    final cursor = json['next_cursor'];
    return ActivityPage(
      items: [
        if (raw is List)
          for (final entry in raw) ?ActivityItem.tryFromJson(entry),
      ],
      nextCursor: cursor is String && cursor.isNotEmpty ? cursor : null,
    );
  }
}
