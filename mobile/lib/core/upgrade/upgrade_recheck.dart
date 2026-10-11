import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_options.dart';
import '../api/failures/app_failure.dart';
import '../api/failures/failure_mapper.dart';

/// What "Check again" on the update screen found out.
enum UpgradeRecheck {
  /// The server answered, and it did not refuse this version: the update screen goes.
  accepted,

  /// The server answered 426: this version is still not supported.
  refused,

  /// No usable answer (offline, a timeout, server trouble, a rate limit). Nothing is
  /// known, so nothing is claimed: not "still not supported", and the screen stays.
  inconclusive,
}

/// What a request made for "Check again" says about the version.
///
/// [failure] is how that request ended (null: a 2xx). [gateRaised] is whether the update
/// screen is still up after it: a 2xx lifts it by itself, so a null failure with the gate
/// still up means the request was not really made (no session, or it was joined to one
/// that was already running): that is no answer either.
///
/// Only a 426 refuses this version, and only a network or server problem leaves it
/// open. Any other answer (a 401, a 403, a 404) comes from the API **after** its version
/// check, so this version was accepted.
UpgradeRecheck classifyUpgradeRecheck(
  AppFailure? failure, {
  required bool gateRaised,
}) => switch (failure) {
  null => gateRaised ? UpgradeRecheck.inconclusive : UpgradeRecheck.accepted,
  UpgradeRequiredFailure() => UpgradeRecheck.refused,
  NetworkFailure() ||
  ServerFailure() ||
  RateLimitedFailure() ||
  UnknownFailure() => UpgradeRecheck.inconclusive,
  _ => UpgradeRecheck.accepted,
};

/// A request that asks the server one thing, whether it accepts this version, without a
/// session: `GET /v1/me` with no token. The version check runs before authentication
/// (only `/v1/...` is checked; `/health` is not, so it would prove nothing), so the
/// answer is 426 for a refused version and 401 `unauthenticated` for an accepted one.
/// Returns how it ended (null: a 2xx).
///
/// It is its own provider so tests make the answer whatever they need.
final upgradeProbeProvider = Provider<Future<AppFailure?> Function()>(
  (ref) => () async {
    try {
      await ref
          .read(apiClientProvider)
          .get<Object?>('/v1/me', options: apiOptions(authenticated: false));
      return null;
    } on Object catch (error) {
      return toAppFailure(error);
    }
  },
);
