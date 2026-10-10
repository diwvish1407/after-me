"""Exception handlers: everything becomes ``application/problem+json`` (RFC 9457)."""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any, Final

import psycopg.errors
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from sqlalchemy.exc import DBAPIError, OperationalError
from sqlalchemy.exc import TimeoutError as PoolTimeoutError
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.responses import Response

from app.core.config import Settings
from app.core.errors import (
    AppError,
    InternalError,
    ServiceUnavailable,
    ValidationFailed,
    error_for_status,
    problem_response,
)
from app.core.logging import get_logger, safe_traceback
from app.core.middleware import get_request_id

_log = get_logger("afterme.error")

_LOCATION_ROOTS: Final = frozenset({"body", "query", "path", "header", "cookie"})
_PYDANTIC_CODES: Final[dict[str, str]] = {
    "missing": "required",
    "extra_forbidden": "unknown_field",
    "string_too_short": "too_short",
    "string_too_long": "too_long",
    "too_short": "too_short",
    "too_long": "too_long",
    "string_pattern_mismatch": "invalid_format",
    "literal_error": "invalid_choice",
    "enum": "invalid_choice",
    "uuid_parsing": "invalid_uuid",
    "uuid_type": "invalid_uuid",
    "json_invalid": "invalid_json",
    "json_type": "invalid_json",
    "string_type": "invalid_type",
    "int_type": "invalid_type",
    "int_parsing": "invalid_type",
    "bool_type": "invalid_type",
    "bool_parsing": "invalid_type",
    "dict_type": "invalid_type",
    "model_type": "invalid_type",
    "model_attributes_type": "invalid_type",
    "list_type": "invalid_type",
    "datetime_type": "invalid_type",
    "datetime_parsing": "invalid_type",
    "less_than_equal": "too_large",
    "less_than": "too_large",
    "greater_than_equal": "too_small",
    "greater_than": "too_small",
    "value_error": "invalid",
}
_RETRYABLE_DB_ERRORS: Final = (
    psycopg.errors.LockNotAvailable,
    psycopg.errors.QueryCanceled,
    psycopg.errors.DeadlockDetected,
    psycopg.errors.SerializationFailure,
)


def _field_path(loc: Sequence[Any]) -> str:
    parts = list(loc)
    if parts and parts[0] in _LOCATION_ROOTS:
        parts = parts[1:]
    path = ""
    for part in parts:
        if isinstance(part, int):
            path += f"[{part}]"
        else:
            path += f".{part}" if path else str(part)
    return path or "body"


def validation_errors(errors: Sequence[Any]) -> list[dict[str, str]]:
    """Convert pydantic errors. Never includes the offending input values."""
    result: list[dict[str, str]] = []
    for error in errors:
        error_type = str(error.get("type", "invalid"))
        code = _PYDANTIC_CODES.get(
            error_type, error_type if error_type.isidentifier() else "invalid"
        )
        result.append(
            {
                "field": _field_path(error.get("loc", ())),
                "code": code,
                "message": str(error.get("msg", "Invalid value.")),
            }
        )
    return result


def register_exception_handlers(app: FastAPI, settings: Settings) -> None:
    base_url = settings.public_base_url

    def respond(request: Request, error: AppError | type[AppError], **kwargs: Any) -> Response:
        return problem_response(
            error, public_base_url=base_url, request_id=get_request_id(request.scope), **kwargs
        )

    async def app_error(request: Request, exc: Exception) -> Response:
        assert isinstance(exc, AppError)  # noqa: S101 - registered for AppError only
        return respond(request, exc)

    async def request_validation(request: Request, exc: Exception) -> Response:
        assert isinstance(exc, RequestValidationError)  # noqa: S101
        return respond(request, ValidationFailed(validation_errors(exc.errors())))

    async def http_exception(request: Request, exc: Exception) -> Response:
        assert isinstance(exc, StarletteHTTPException)  # noqa: S101
        error_cls = error_for_status(exc.status_code)
        headers: dict[str, str] = {}
        if exc.status_code == 405 and exc.headers and "Allow" in exc.headers:  # noqa: PLR2004
            headers["Allow"] = exc.headers["Allow"]
        return respond(request, error_cls, status_code=exc.status_code, headers=headers)

    async def database_error(request: Request, exc: Exception) -> Response:
        assert isinstance(exc, (DBAPIError, PoolTimeoutError))  # noqa: S101
        orig = getattr(exc, "orig", None)
        retryable = isinstance(exc, (OperationalError, PoolTimeoutError)) or isinstance(
            orig, _RETRYABLE_DB_ERRORS
        )
        _log.error(
            "db.error",
            error_class=type(exc).__name__,
            driver_error_class=type(orig).__name__ if orig is not None else None,
            sqlstate=getattr(orig, "sqlstate", None),
            frames=safe_traceback(exc),
        )
        if retryable:
            return respond(request, ServiceUnavailable(headers={"Retry-After": "1"}))
        return respond(request, InternalError)

    app.add_exception_handler(AppError, app_error)
    app.add_exception_handler(RequestValidationError, request_validation)
    app.add_exception_handler(StarletteHTTPException, http_exception)
    app.add_exception_handler(DBAPIError, database_error)
    app.add_exception_handler(PoolTimeoutError, database_error)
