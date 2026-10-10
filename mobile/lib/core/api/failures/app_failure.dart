import 'package:flutter/foundation.dart';

import '../models/api_problem.dart';

/// Every way an API call can fail, as seen by the UI (ARCHITECTURE.md §5.3).
///
/// The hierarchy is sealed, so a `switch` over a failure must handle every case.
/// Map raw errors with `mapDioException` / `toAppFailure`; never show [problem]
/// fields such as `detail` verbatim in place of the app's own copy.
@immutable
sealed class AppFailure implements Exception {
  const AppFailure({this.problem});

  /// The parsed problem+json body, when the server sent one.
  final ApiProblem? problem;

  /// The server's request ID, for support conversations.
  String? get requestId => problem?.requestId;

  /// Whether trying the same action again later can succeed without user changes.
  bool get isTransient => false;

  @override
  String toString() =>
      '$runtimeType(code: ${problem?.code}, status: ${problem?.status})';
}

/// No usable response: offline, DNS, TLS, connection reset or a timeout.
final class NetworkFailure extends AppFailure {
  const NetworkFailure({super.problem, this.cause});

  final Object? cause;

  @override
  bool get isTransient => true;
}

/// 401. [code] is `unauthenticated`, `token_expired`, `session_revoked` or
/// `invalid_credentials` (API_SPEC.md §1.1).
final class UnauthorizedFailure extends AppFailure {
  const UnauthorizedFailure({this.code, super.problem});

  final String? code;
}

/// 403. [code] is `reauth_required`, `email_unverified`, `plan_limit_reached`, ...
base class ForbiddenFailure extends AppFailure {
  const ForbiddenFailure({this.code, super.problem});

  final String? code;
}

/// 403 `plan_limit_reached`: the tier's limit for [resource] is used up. [limit] and
/// [current] come from the problem body; either may be null if the server left it out.
final class PlanLimitFailure extends ForbiddenFailure {
  const PlanLimitFailure({
    this.limit,
    this.current,
    this.resource,
    super.problem,
  }) : super(code: 'plan_limit_reached');

  final int? limit;
  final int? current;
  final String? resource;
}

/// 404: missing **or not yours** (the API does not distinguish).
final class NotFoundFailure extends AppFailure {
  const NotFoundFailure({super.problem});
}

/// 409 (state conflicts such as `safe_required`, `incident_open`), and the
/// optimistic-concurrency statuses 412 `precondition_failed` / 428
/// `precondition_required`.
base class ConflictFailure extends AppFailure {
  const ConflictFailure({this.code, super.problem});

  final String? code;
}

/// 409 `contact_duplicate`: another of the user's contacts already uses this email.
final class ContactDuplicateFailure extends ConflictFailure {
  const ContactDuplicateFailure({super.problem})
    : super(code: 'contact_duplicate');
}

/// 409 `invalid_state`: the action is not possible in the resource's current state
/// (for example resending an invitation to someone who declined).
final class InvalidStateFailure extends ConflictFailure {
  const InvalidStateFailure({super.problem}) : super(code: 'invalid_state');
}

/// 409 `activation_requirements_unmet`: check-ins cannot be turned on yet. The
/// [requirements] are the codes the server listed (`no_contacts`, and later `no_stages`
/// and others). Codes this app version does not know are kept, so the screen can say
/// that something else is still missing instead of guessing.
final class ActivationRequirementsFailure extends ConflictFailure {
  const ActivationRequirementsFailure({
    this.requirements = const <String>[],
    super.problem,
  }) : super(code: 'activation_requirements_unmet');

  final List<String> requirements;
}

/// 422 `validation_failed` with [fieldErrors]; also 400 (`invalid_code`) and 413
/// (`payload_too_large`), which are problems with what the user entered.
base class ValidationFailure extends AppFailure {
  const ValidationFailure({
    this.code,
    this.fieldErrors = const <ApiFieldError>[],
    super.problem,
  });

  final String? code;
  final List<ApiFieldError> fieldErrors;
}

/// 422 `cannot_be_own_email`: a contact cannot use the account's own address.
final class CannotBeOwnEmailFailure extends ValidationFailure {
  const CannotBeOwnEmailFailure({super.fieldErrors, super.problem})
    : super(code: 'cannot_be_own_email');
}

/// 429. [retryAfter] comes from the `Retry-After` header when present.
final class RateLimitedFailure extends AppFailure {
  const RateLimitedFailure({this.retryAfter, super.problem});

  final Duration? retryAfter;

  @override
  bool get isTransient => true;
}

/// 426: this app version is no longer supported.
final class UpgradeRequiredFailure extends AppFailure {
  const UpgradeRequiredFailure({super.problem});
}

/// 5xx, including 503 `service_unavailable` after retries were exhausted.
final class ServerFailure extends AppFailure {
  const ServerFailure({this.statusCode, super.problem});

  final int? statusCode;

  @override
  bool get isTransient => true;
}

/// Anything else: cancelled requests, unexpected statuses, malformed responses,
/// programming errors.
final class UnknownFailure extends AppFailure {
  const UnknownFailure({this.cause, this.statusCode, super.problem});

  final Object? cause;
  final int? statusCode;

  @override
  bool get isTransient => true;
}
