"""RFC 9457 problem details (``application/problem+json``) and the application error types.

Every error leaves the API in the same shape::

    {"type": "<PUBLIC_BASE_URL>/problems/<code-with-hyphens>", "title": "...", "status": 409,
     "code": "...", "detail": "...", "request_id": "...", ...extras}

Error bodies never contain internals: no exception messages, SQL, stack traces or input values.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from typing import Any, ClassVar

from starlette.responses import JSONResponse

PROBLEM_JSON = "application/problem+json"


class AppError(Exception):
    """An expected error that maps to a problem+json response."""

    status_code: ClassVar[int] = 500
    code: ClassVar[str] = "internal_error"
    title: ClassVar[str] = "Something went wrong"
    default_detail: ClassVar[str | None] = None

    def __init__(
        self,
        detail: str | None = None,
        *,
        headers: Mapping[str, str] | None = None,
        **extras: Any,
    ) -> None:
        super().__init__(self.code)
        self.detail = detail if detail is not None else self.default_detail
        self.headers: dict[str, str] = dict(headers or {})
        self.extras: dict[str, Any] = extras


class BadRequest(AppError):
    status_code = 400
    code = "bad_request"
    title = "Bad request"


class InvalidCode(AppError):
    status_code = 400
    code = "invalid_code"
    title = "Invalid code"
    default_detail = "That code is wrong or has expired."


class _BearerChallenge(AppError):
    def __init__(self, detail: str | None = None, **extras: Any) -> None:
        super().__init__(detail, headers={"WWW-Authenticate": "Bearer"}, **extras)


class Unauthenticated(_BearerChallenge):
    status_code = 401
    code = "unauthenticated"
    title = "Not signed in"
    default_detail = "A valid access token is required."


class TokenExpired(_BearerChallenge):
    status_code = 401
    code = "token_expired"
    title = "Access token expired"
    default_detail = "Refresh the access token and try again."


class SessionRevoked(_BearerChallenge):
    status_code = 401
    code = "session_revoked"
    title = "Session ended"
    default_detail = "Please sign in again."


class InvalidCredentials(_BearerChallenge):
    status_code = 401
    code = "invalid_credentials"
    title = "Sign-in failed"
    default_detail = "The email or password is incorrect."


class ReauthRequired(AppError):
    status_code = 403
    code = "reauth_required"
    title = "Confirm your password"
    default_detail = "Enter your password again to continue."


class EmailUnverified(AppError):
    status_code = 403
    code = "email_unverified"
    title = "Email not verified"
    default_detail = "Enter the code we sent to your email to finish creating your account."


class Forbidden(AppError):
    status_code = 403
    code = "forbidden"
    title = "Not allowed"


class NotFound(AppError):
    status_code = 404
    code = "not_found"
    title = "Not found"
    default_detail = "The resource does not exist."


class MethodNotAllowed(AppError):
    status_code = 405
    code = "method_not_allowed"
    title = "Method not allowed"


class PlanLimitReached(AppError):
    status_code = 403
    code = "plan_limit_reached"
    title = "Plan limit reached"
    default_detail = "Your plan does not allow more of these. Remove one or upgrade."

    def __init__(self, *, resource: str, limit: int, current: int) -> None:
        super().__init__(limit=limit, current=current, resource=resource)


class InvalidState(AppError):
    status_code = 409
    code = "invalid_state"
    title = "Conflict"


class SafeRequired(AppError):
    status_code = 409
    code = "safe_required"
    title = "Confirm you're safe"
    default_detail = "Your contacts have been notified. Confirm I'M SAFE to stop the escalation."

    def __init__(self, incident_id: object) -> None:
        super().__init__(incident_id=str(incident_id))


class IncidentOpen(AppError):
    status_code = 409
    code = "incident_open"
    title = "Check in first"
    default_detail = "This can't be changed while a check-in is overdue. Check in first."


class ActivationRequirementsUnmet(AppError):
    status_code = 409
    code = "activation_requirements_unmet"
    title = "Finish your plan first"
    default_detail = "Something is still missing before check-ins can be turned on."

    def __init__(self, requirements: Sequence[str]) -> None:
        super().__init__(requirements=list(requirements))


class StageInUse(AppError):
    status_code = 409
    code = "stage_in_use"
    title = "This stage is in use"
    default_detail = "Move the information shared at this stage before removing it."
    MAX_LISTED: ClassVar[int] = 25

    def __init__(self, instruction_ids: Sequence[object]) -> None:
        super().__init__(instruction_ids=[str(i) for i in instruction_ids[: self.MAX_LISTED]])


class ContactDuplicate(AppError):
    status_code = 409
    code = "contact_duplicate"
    title = "Contact already added"
    default_detail = "One of your contacts already uses this email address."


class CannotBeOwnEmail(AppError):
    status_code = 422
    code = "cannot_be_own_email"
    title = "Use a different email"
    default_detail = "A trusted contact needs their own email address, not yours."

    def __init__(self) -> None:
        super().__init__(
            errors=[
                {
                    "field": "email",
                    "code": self.code,
                    "message": "Use the contact's own email address, not yours.",
                }
            ]
        )


class PreconditionFailed(AppError):
    status_code = 412
    code = "precondition_failed"
    title = "Out of date"
    default_detail = "This was changed somewhere else. Reload it and try again."


class PreconditionRequired(AppError):
    status_code = 428
    code = "precondition_required"
    title = "Version required"
    default_detail = "Send the version you are changing in the If-Match header."


class PayloadTooLarge(AppError):
    status_code = 413
    code = "payload_too_large"
    title = "Request body too large"


class ValidationFailed(AppError):
    status_code = 422
    code = "validation_failed"
    title = "Some fields are invalid"
    default_detail = "Check the highlighted fields and try again."

    def __init__(self, errors: Sequence[Mapping[str, str]], detail: str | None = None) -> None:
        super().__init__(detail, errors=[dict(e) for e in errors])


class UpgradeRequired(AppError):
    status_code = 426
    code = "upgrade_required"
    title = "Update required"
    default_detail = "Please update AfterMe to keep your plan running."


class RateLimited(AppError):
    status_code = 429
    code = "rate_limited"
    title = "Too many attempts"
    default_detail = "Too many attempts. Try again later."

    def __init__(
        self, *, retry_after: int, headers: Mapping[str, str] | None = None, **extras: Any
    ) -> None:
        merged = {"Retry-After": str(max(1, retry_after)), **(headers or {})}
        super().__init__(None, headers=merged, **extras)
        self.retry_after = max(1, retry_after)


class InternalError(AppError):
    status_code = 500
    code = "internal_error"
    title = "Something went wrong"
    default_detail = "Something went wrong on our side. Your data is safe. Try again in a moment."


class ServiceUnavailable(AppError):
    status_code = 503
    code = "service_unavailable"
    title = "Service unavailable"
    default_detail = "The service is temporarily unavailable. Try again in a moment."


_GENERIC_BY_STATUS: dict[int, type[AppError]] = {
    400: BadRequest,
    401: Unauthenticated,
    403: Forbidden,
    404: NotFound,
    405: MethodNotAllowed,
    409: InvalidState,
    412: PreconditionFailed,
    413: PayloadTooLarge,
    426: UpgradeRequired,
    428: PreconditionRequired,
    500: InternalError,
    503: ServiceUnavailable,
}


def error_for_status(status_code: int) -> type[AppError]:
    """Return the generic error class for an HTTP status raised by the framework."""
    return _GENERIC_BY_STATUS.get(status_code, BadRequest if status_code < 500 else InternalError)  # noqa: PLR2004


def problem_type(public_base_url: str, code: str) -> str:
    return f"{public_base_url}/problems/{code.replace('_', '-')}"


def problem_body(
    error: AppError | type[AppError],
    *,
    public_base_url: str,
    request_id: str | None,
    status_code: int | None = None,
) -> dict[str, Any]:
    detail = error.detail if isinstance(error, AppError) else error.default_detail
    extras = error.extras if isinstance(error, AppError) else {}
    body: dict[str, Any] = {
        "type": problem_type(public_base_url, error.code),
        "title": error.title,
        "status": status_code or error.status_code,
        "code": error.code,
        "detail": detail,
        "request_id": request_id,
    }
    for key, value in extras.items():
        body.setdefault(key, value)
    return body


def problem_response(
    error: AppError | type[AppError],
    *,
    public_base_url: str,
    request_id: str | None,
    status_code: int | None = None,
    headers: Mapping[str, str] | None = None,
) -> JSONResponse:
    merged_headers = dict(error.headers) if isinstance(error, AppError) else {}
    merged_headers.update(headers or {})
    return JSONResponse(
        problem_body(
            error,
            public_base_url=public_base_url,
            request_id=request_id,
            status_code=status_code,
        ),
        status_code=status_code or error.status_code,
        headers=merged_headers,
        media_type=PROBLEM_JSON,
    )
