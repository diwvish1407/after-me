import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session_store.dart';
import '../../../core/storage/secure_store.dart';

/// How old an unconfirmed tap may be and still be sent. It matches the 12 h minimum
/// window of ESCALATION_ENGINE.md §3.2: up to this age a delayed delivery is accepted
/// as the tap it was; older than this the tap is too old to count (the server stamps a
/// tap at receipt, so a late one would restart the deadline from then) and the app drops
/// it and says so (§9.1, stale replay).
const Duration pendingCheckInMaxAge = Duration(hours: 12);

/// One tap of I'M OK that the server has not confirmed yet.
///
/// The [idempotencyKey] belongs to this tap: every retry of it, in this process or after
/// the app was killed, sends the same key, so the server records the tap exactly once.
/// [userId] ties the record to the account that tapped, so a check-in can never be sent
/// for somebody who signed in later on the same phone. It is the id of the **session**
/// (`SessionKeys.userId`), never empty: a record that names nobody belongs to nobody and
/// is neither written nor read.
@immutable
class PendingCheckIn {
  const PendingCheckIn({
    required this.userId,
    required this.idempotencyKey,
    required this.reportedAt,
  });

  final String userId;
  final String idempotencyKey;

  /// The phone's clock at the tap. The server never trusts it; on the phone it is shown
  /// to the person as "You tapped at ..." and its age decides whether the tap is still
  /// sent ([isStaleAt]).
  final DateTime reportedAt;

  /// Whether the tap is too old to count at [now] (the phone's clock): made more than
  /// [pendingCheckInMaxAge] ago. A clock that moved back gives a negative age, which is
  /// never too old: a tap is not dropped because of a clock jump.
  bool isStaleAt(DateTime now) =>
      now.difference(reportedAt) > pendingCheckInMaxAge;

  String encode() => jsonEncode(<String, Object?>{
    'v': 1,
    'user': userId,
    'key': idempotencyKey,
    'reported_at': reportedAt.toUtc().toIso8601String(),
  });

  /// The record in [raw], or null when it is missing or damaged.
  static PendingCheckIn? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic> || json['v'] != 1) {
        return null;
      }
      final user = json['user'];
      final key = json['key'];
      final reported = json['reported_at'];
      if (user is! String || user.isEmpty || key is! String || key.isEmpty) {
        return null;
      }
      if (reported is! String) {
        return null;
      }
      return PendingCheckIn(
        userId: user,
        idempotencyKey: key,
        reportedAt: DateTime.parse(reported),
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PendingCheckIn &&
      other.userId == userId &&
      other.idempotencyKey == idempotencyKey &&
      other.reportedAt == reportedAt;

  @override
  int get hashCode => Object.hash(userId, idempotencyKey, reportedAt);
}

/// Keeps the pending check-in in secure storage (ARCHITECTURE.md §5.4): the instant of a
/// tap is part of the person's daily pattern (SECURITY.md §2). The record holds only an
/// opaque account id, a random key and a time: no names, addresses or schedule.
///
/// **One record per account.** The newest account's record is under [storageKey]; when
/// another account taps on the same phone, the record already there is moved aside under
/// `checkin.pending.<account id>` instead of being replaced, so a tap one person made and
/// the server never confirmed is still sent when that person is signed in again. A record
/// is only ever read for its own account (the server binds a check-in to the session's
/// account in any case).
///
/// Storage failures never stop a check-in: a record that cannot be written still works
/// for as long as the process lives.
class PendingCheckInStore {
  PendingCheckInStore({required this._secure});

  /// The secure-storage key of the record.
  static const storageKey = 'checkin.pending';

  /// The key a record that was moved aside is kept under.
  static String _parkedKey(String userId) => '$storageKey.$userId';

  final SecureStore _secure;

  /// The account the app is signed in as, as an opaque id: the one the session was
  /// started for (`SessionKeys.userId`, written with the tokens at sign-in and removed
  /// with them). Empty when it is not known (no session, or storage cannot be read).
  Future<String> currentUserId() async {
    try {
      return await _secure.read(SessionKeys.userId) ?? '';
    } on Object {
      return '';
    }
  }

  /// The saved record when it belongs to [userId]. A record of another account is left
  /// alone (it is not this person's tap) and reported as none, and so is anything for an
  /// empty [userId]: nobody is signed in as nobody.
  Future<PendingCheckIn?> read(String userId) async {
    if (userId.isEmpty) {
      return null;
    }
    try {
      final record = PendingCheckIn.tryDecode(await _secure.read(storageKey));
      if (record != null && record.userId == userId) {
        return record;
      }
      // Moved aside by another account's tap on this phone.
      final parked = PendingCheckIn.tryDecode(
        await _secure.read(_parkedKey(userId)),
      );
      return parked != null && parked.userId == userId ? parked : null;
    } on Object {
      return null;
    }
  }

  /// Keeps [record] for a restart. A record without an owner is not kept: it could be
  /// sent for the wrong person later. The tap itself still works for as long as the
  /// process lives.
  Future<void> write(PendingCheckIn record) async {
    if (record.userId.isEmpty) {
      return;
    }
    try {
      final existing = PendingCheckIn.tryDecode(await _secure.read(storageKey));
      if (existing != null && existing.userId != record.userId) {
        // Another account's unsent tap is not ours to replace. One that is already too
        // old to be sent (it would be dropped when read) is not worth keeping.
        if (!existing.isStaleAt(record.reportedAt)) {
          await _secure.write(_parkedKey(existing.userId), existing.encode());
        }
      }
      await _secure.write(storageKey, record.encode());
      // This account's earlier record, if one was moved aside, is replaced by this one.
      await _secure.delete(_parkedKey(record.userId));
    } on Object {
      // Still retried for as long as the app runs.
    }
  }

  /// Removes the record in the **main slot**, whoever it belongs to. It never touches a
  /// record that another account's tap moved aside (`checkin.pending.<id>`): those are
  /// those accounts' own, and a call that cannot name an account has no business
  /// deleting them one by one. Closing an account whose id cannot be read uses
  /// [clearAll]; everything else uses [clearFor].
  Future<void> clear() async {
    try {
      await _secure.delete(storageKey);
    } on Object {
      // Nothing more to do; a leftover record is replayed with the same key, which
      // the server answers with the original result.
    }
  }

  /// Removes **every** record this phone keeps: the main slot and each one that was
  /// moved aside. Only for the closure of an account whose id is unknown (so its parked
  /// copy cannot be named): the closed account's trace of its daily pattern outweighs
  /// another account's unsent tap, which is worth nothing after
  /// [pendingCheckInMaxAge] in any case. Each deletion is independent: one that fails
  /// never stops the others.
  Future<void> clearAll() async {
    await clear();
    Set<String> keys;
    try {
      keys = await _secure.keys();
    } on Object {
      return;
    }
    for (final key in keys) {
      if (key.startsWith('$storageKey.')) {
        try {
          await _secure.delete(key);
        } on Object {
          // As in [clear].
        }
      }
    }
  }

  /// Removes the record when it is [userId]'s (or is damaged and so nobody's). A record
  /// of another account stays: this tap was confirmed, or dropped, and that one is not
  /// ours to forget.
  Future<void> clearFor(String userId) async {
    if (userId.isNotEmpty) {
      try {
        await _secure.delete(_parkedKey(userId));
      } on Object {
        // As in [clear].
      }
    }
    try {
      final raw = await _secure.read(storageKey);
      if (raw == null) {
        return;
      }
      final record = PendingCheckIn.tryDecode(raw);
      if (record != null && record.userId != userId) {
        return;
      }
      await _secure.delete(storageKey);
    } on Object {
      // As in [clear].
    }
  }
}

final pendingCheckInStoreProvider = Provider<PendingCheckInStore>(
  (ref) => PendingCheckInStore(secure: ref.watch(secureStoreProvider)),
);
