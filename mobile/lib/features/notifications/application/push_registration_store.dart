import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/secure_store.dart';

/// What the phone last told the server about its push token, so a token that has not
/// changed is not sent again until a day has passed.
///
/// It is bound to the account (an opaque id) and holds the token itself: a token is
/// compared by value, and it belongs in the Keystore-backed secure store like every other
/// piece of this device's identity, never in preferences or a log.
@immutable
class PushRegistration {
  const PushRegistration({
    required this.userId,
    required this.at,
    required this.facts,
    this.token,
    this.accepted = true,
  });

  /// The account the registration was made for.
  final String userId;

  /// The token that was sent, or null once the token was removed (notifications off).
  final String? token;

  /// A summary of the device facts that were sent (app version, system version, locale):
  /// when one changes (an update) the facts are sent again.
  final String facts;

  /// When it was sent (or refused).
  final DateTime at;

  /// The server took it. False when it refused the token (422): the same token is not
  /// offered again until the next day or until FCM issues another.
  final bool accepted;

  Map<String, Object?> toJson() => <String, Object?>{
    'user_id': userId,
    'token': token,
    'facts': facts,
    'at': at.toUtc().toIso8601String(),
    'accepted': accepted,
  };

  /// Null for anything that is not a record written by this class.
  static PushRegistration? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final userId = json['user_id'];
    final facts = json['facts'];
    final at = DateTime.tryParse('${json['at']}');
    final token = json['token'];
    final accepted = json['accepted'];
    if (userId is! String ||
        userId.isEmpty ||
        facts is! String ||
        at == null ||
        (token != null && token is! String) ||
        accepted is! bool) {
      return null;
    }
    return PushRegistration(
      userId: userId,
      token: token as String?,
      facts: facts,
      at: at,
      accepted: accepted,
    );
  }

  @override
  String toString() => 'PushRegistration(<redacted>)';
}

/// Secure-storage keys of the push registration.
abstract final class PushKeys {
  static const registration = 'push.registration';

  /// Set while the local FCM token still has to be deleted (it could not be, offline).
  static const deletePending = 'push.delete_pending';
}

/// Reads and writes the [PushRegistration] and the "token still to delete" marker.
class PushRegistrationStore {
  PushRegistrationStore(this._store);

  final SecureStore _store;

  /// The record, or null when there is none or it cannot be read.
  Future<PushRegistration?> read() async {
    try {
      final raw = await _store.read(PushKeys.registration);
      if (raw == null || raw.isEmpty) {
        return null;
      }
      return PushRegistration.fromJson(jsonDecode(raw));
    } on Object {
      return null;
    }
  }

  Future<void> write(PushRegistration registration) async {
    try {
      await _store.write(
        PushKeys.registration,
        jsonEncode(registration.toJson()),
      );
    } on Object {
      // Remembering is a convenience: the token is simply sent again next time.
    }
  }

  Future<void> clear() async {
    try {
      await _store.delete(PushKeys.registration);
    } on Object {
      // Nothing more can be done.
    }
  }

  Future<bool> isDeletePending() async {
    try {
      return await _store.read(PushKeys.deletePending) != null;
    } on Object {
      return false;
    }
  }

  Future<void> setDeletePending({required bool pending}) async {
    try {
      if (pending) {
        await _store.write(PushKeys.deletePending, '1');
      } else {
        await _store.delete(PushKeys.deletePending);
      }
    } on Object {
      // The marker is a convenience for the rare offline sign-out.
    }
  }
}

final pushRegistrationStoreProvider = Provider<PushRegistrationStore>(
  (ref) => PushRegistrationStore(ref.watch(secureStoreProvider)),
);
