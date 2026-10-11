import 'package:flutter/foundation.dart';

/// The answer to `DELETE /v1/me` (202): the account is closed and its data is purged
/// after [purgeAfter].
@immutable
class AccountDeletion {
  const AccountDeletion({this.purgeAfter});

  /// When the remaining data is removed (`purge_after`, about 30 days away), or null when
  /// the answer did not carry a readable time. The deletion itself does not depend on it.
  final DateTime? purgeAfter;
}

/// The export is larger than this phone can hold in memory. Nothing was kept; the person
/// can still ask for their data on the web.
class ExportTooLargeException implements Exception {
  const ExportTooLargeException();

  @override
  String toString() => 'ExportTooLargeException';
}

/// Export and deletion of the account (API_SPEC.md §3).
///
/// Both need the password to have been entered in the last 60 seconds: they fail with a
/// 403 `reauth_required` otherwise, which callers handle with `withReauth`. Every method
/// throws an `AppFailure` on error (or [ExportTooLargeException]).
abstract interface class PrivacyRepository {
  /// `POST /v1/me/export`: the account as one JSON file, **as bytes**. The decrypted
  /// instructions are in it, so the bytes go to the system's save dialog and nowhere
  /// else: they are not decoded, logged, cached or kept. The request is never repeated
  /// by the client: each export spends the password confirmation and counts towards the
  /// 3 an hour.
  Future<Uint8List> exportData();

  /// `DELETE /v1/me` with `{"confirm": "DELETE"}`. A 202 means the account is closed and
  /// **every session of the account is already revoked**. The request is safe to make
  /// again: after a success the next call is a 401.
  Future<AccountDeletion> deleteAccount();
}
