import 'dart:async';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/incidents/data/incidents_repository.dart';

import 'fake_checkin_server.dart';

String _rfc3339(DateTime instant) {
  final iso = instant.toUtc().toIso8601String();
  return '${iso.substring(0, iso.indexOf('.'))}Z';
}

/// The incidents "server" for tests, behaving like `docs/contracts/phase5`: the open
/// incident is the one on the check-in server (Home reads the same object), `GET
/// /incidents` lists it with the closed ones newest first, and `POST /incidents/{id}/safe`
/// needs the password re-auth and an `Idempotency-Key`, stops the incident, restarts the
/// schedule and answers a replay of the same key with the stored answer.
///
/// It lives in `test/` on purpose: the app itself talks to the real API.
class FakeIncidentServer implements IncidentsRepository {
  FakeIncidentServer({
    required this.serverOf,
    required this.clock,
    required this.reauthenticated,
  });

  /// The check-in "server": it owns the open incident, which Home reads.
  final FakeCheckInServer Function() serverOf;
  FakeCheckInServer get server => serverOf();

  final DateTime Function() clock;

  /// Whether the session entered its password within the last 5 minutes.
  final bool Function() reauthenticated;

  // --- scripting and inspection -------------------------------------------------------
  final List<String> calls = [];

  /// Every `Idempotency-Key` that reached [markSafe], in order (replays included).
  final List<String> safeKeys = [];

  /// Failures thrown by the next calls to the named method (`list`, `get`, `markSafe`),
  /// consumed in order.
  final Map<String, List<AppFailure>> failures = {};

  /// Like [failures] for `markSafe`, but thrown only after the incident was stopped:
  /// the answer is lost on the way back. The retry with the same key must not stop it
  /// (or tell anyone) again.
  final List<AppFailure> failAfterRecording = [];

  /// Answers `all_clear_sent_to` in the opposite order (the server's order of that list
  /// is not a contract the app may rely on).
  bool reverseAllClear = false;

  /// Waits before answering (to show the sending state).
  Future<void>? safeGate;
  Future<void>? getGate;

  /// The answer to I'M SAFE has no next deadline (the schedule is off).
  bool scheduleOffAfterSafe = false;

  /// How many requests were answered from the idempotency record.
  int replays = 0;

  /// How many times the incident was really stopped.
  int stopped = 0;

  /// The closed incidents (objects as on the wire), newest first.
  final List<Map<String, dynamic>> closed = [];

  final Map<String, SafeResult> _byKey = {};

  void _enter(String method) {
    calls.add(method);
    final queue = failures[method];
    if (queue != null && queue.isNotEmpty) {
      throw queue.removeAt(0);
    }
  }

  /// Wires the check-in server so an I'M OK that closes the incident lands in the
  /// history too.
  void attach() {
    server.onIncidentClosed = (closedBy) => _archive(closedBy: closedBy);
  }

  /// Opens [incident] (an object as on the wire) the way the worker does.
  void open(Map<String, dynamic> incident) {
    server
      ..openIncident(details: incident)
      ..contactsMessaged = incident['contacts_messaged'] == true;
  }

  /// A past incident, as `GET /incidents` and `GET /incidents/{id}` return it.
  void addClosed(Map<String, dynamic> incident) {
    closed
      ..add(incident)
      ..sort(
        (a, b) =>
            (b['anchor_at'] as String).compareTo(a['anchor_at'] as String),
      );
  }

  void _archive({required String closedBy}) {
    final current = server.incident;
    if (current == null) {
      return;
    }
    final at = _rfc3339(clock().add(server.skew));
    final revokeReason = closedBy == 'user_safe' ? 'user_safe' : 'user_checkin';
    addClosed({
      ...current,
      'status': closedBy == 'user_safe' ? 'cancelled' : 'resolved',
      'requires': null,
      'closed_at': at,
      'closed_by': closedBy,
      'server_time': at,
      'timeline': [
        for (final item in (current['timeline'] as List? ?? const []))
          {
            ...(item as Map<String, dynamic>),
            if (item['status'] == 'pending') 'status': 'cancelled',
          },
      ],
      'releases': [
        for (final release in (current['releases'] as List? ?? const []))
          {
            ...(release as Map<String, dynamic>),
            if (release['revoked_at'] == null) ...{
              'revoked_at': at,
              'revoke_reason': revokeReason,
            },
          },
      ],
    });
  }

  Map<String, dynamic> _summary(Map<String, dynamic> incident) => {
    'id': incident['id'],
    'status': incident['status'],
    'missed_due_at': incident['missed_due_at'],
    'opened_at': incident['anchor_at'],
    'closed_at': incident['closed_at'],
    'closed_by': incident['closed_by'],
    'contacts_messaged': incident['contacts_messaged'],
  };

  // --- IncidentsRepository ----------------------------------------------------------------

  @override
  Future<IncidentPage> list({int limit = 20, String? cursor}) async {
    _enter('list');
    final all = <Map<String, dynamic>>[
      if (server.incident != null) _summary(server.incident!),
      for (final incident in closed) _summary(incident),
    ];
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = (start + limit).clamp(0, all.length);
    return IncidentPage.fromJson({
      'items': all.sublist(start, end),
      'next_cursor': end < all.length ? '$end' : null,
    });
  }

  @override
  Future<Incident> get(String id) async {
    _enter('get');
    await getGate;
    final current = server.incident;
    if (current != null && current['id'] == id) {
      return Incident.fromJson({
        ...current,
        'server_time': _rfc3339(clock().add(server.skew)),
      });
    }
    for (final incident in closed) {
      if (incident['id'] == id) {
        return Incident.fromJson(incident);
      }
    }
    throw const NotFoundFailure();
  }

  @override
  Future<SafeResult> markSafe(
    String incidentId, {
    required String idempotencyKey,
  }) async {
    safeKeys.add(idempotencyKey);
    _enter('markSafe');
    await safeGate;
    final earlier = _byKey[idempotencyKey];
    if (earlier != null) {
      // The original answer, whenever it is asked for again.
      replays++;
      return earlier;
    }
    if (!reauthenticated()) {
      throw const ForbiddenFailure(code: 'reauth_required');
    }
    final current = server.incident;
    if (current == null || current['id'] != incidentId) {
      throw const InvalidStateFailure();
    }
    final told = <AllClearTarget>[];
    final seen = <String>{};
    for (final item in (current['timeline'] as List? ?? const [])) {
      final contacts = (item as Map<String, dynamic>)['contacts'] as List?;
      for (final contact in contacts ?? const <Object?>[]) {
        final c = contact! as Map<String, dynamic>;
        if (c['result'] == 'messaged' && seen.add(c['id'] as String)) {
          told.add(
            AllClearTarget(
              contactId: c['id'] as String,
              displayName: c['display_name'] as String,
            ),
          );
        }
      }
    }
    _archive(closedBy: 'user_safe');
    var nextDue = server.closeIncidentSafe();
    if (scheduleOffAfterSafe) {
      server
        ..status = CheckInStatus.inactive
        ..nextDueAt = null;
      nextDue = null;
    }
    stopped++;
    final result = SafeResult(
      incidentId: incidentId,
      allClearSentTo: reverseAllClear ? told.reversed.toList() : told,
      nextDueAt: nextDue,
      serverTime: clock().add(server.skew),
    );
    _byKey[idempotencyKey] = result;
    if (failAfterRecording.isNotEmpty) {
      throw failAfterRecording.removeAt(0);
    }
    return result;
  }
}
