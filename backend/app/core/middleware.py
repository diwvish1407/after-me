"""Pure ASGI middleware (ARCHITECTURE §4.4).

Order, outermost first: :class:`RequestContextMiddleware` (request ID, access log, security
headers, last-resort 500) → :class:`BodySizeLimitMiddleware` → :class:`ClientVersionMiddleware`.
"""

from __future__ import annotations

import re
import time
import uuid
from typing import Any, Final

from starlette.datastructures import Headers, MutableHeaders
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.core.config import Settings
from app.core.errors import (
    AppError,
    InternalError,
    PayloadTooLarge,
    UpgradeRequired,
    problem_response,
)
from app.core.logging import (
    bind_request_context,
    clear_request_context,
    get_logger,
    safe_traceback,
)

SCOPE_REQUEST_ID: Final = "afterme.request_id"
SCOPE_RESPONSE_HEADERS: Final = "afterme.response_headers"
REQUEST_ID_HEADER: Final = "X-Request-ID"
CLIENT_HEADER: Final = "X-AfterMe-Client"
MAX_BODY_BYTES: Final = 64 * 1024
# 20,000 characters can be 80,000 bytes of UTF-8 (four bytes for an emoji): only the instruction
# routes may be larger than the general cap.
INSTRUCTION_BODY_BYTES: Final = 96 * 1024
# A provider's bounce event can carry the original message's content and headers.
WEBHOOK_BODY_BYTES: Final = 512 * 1024

_REQUEST_ID_RE: Final = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
_CLIENT_RE: Final = re.compile(r"^android/(\d{1,6})\.(\d{1,6})\.(\d{1,6})(?:\+\d{1,9})?$")

_access_log = get_logger("afterme.access")
_error_log = get_logger("afterme.error")


def get_request_id(scope: Scope) -> str | None:
    value = scope.get(SCOPE_REQUEST_ID)
    return value if isinstance(value, str) else None


def add_response_headers(scope: Scope, headers: dict[str, str]) -> None:
    """Ask the outer middleware to add headers to whatever response this request produces."""
    pending: dict[str, str] = scope.setdefault(SCOPE_RESPONSE_HEADERS, {})
    pending.update(headers)


async def _send_problem(
    scope: Scope, receive: Receive, send: Send, error: AppError | type[AppError], base_url: str
) -> None:
    response = problem_response(error, public_base_url=base_url, request_id=get_request_id(scope))
    await response(scope, receive, send)


class RequestContextMiddleware:
    def __init__(self, app: ASGIApp, *, settings: Settings) -> None:
        self.app = app
        self.settings = settings
        self._docs_paths = {"/v1/docs", "/v1/docs/oauth2-redirect"}

    def _security_headers(self, path: str) -> dict[str, str]:
        headers = {
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
            "X-Frame-Options": "DENY",
            "Cross-Origin-Resource-Policy": "same-origin",
        }
        if path not in self._docs_paths:
            headers["Content-Security-Policy"] = "default-src 'none'; frame-ancestors 'none'"
        if self.settings.hsts_enabled:
            headers["Strict-Transport-Security"] = "max-age=63072000; includeSubDomains"
        return headers

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        incoming = Headers(scope=scope).get(REQUEST_ID_HEADER)
        request_id = incoming if incoming and _REQUEST_ID_RE.match(incoming) else uuid.uuid4().hex
        scope[SCOPE_REQUEST_ID] = request_id
        clear_request_context()
        bind_request_context(request_id=request_id)

        started_at = time.perf_counter()
        state: dict[str, Any] = {"status": 500, "started": False}
        security_headers = self._security_headers(scope.get("path", ""))

        async def send_wrapper(message: Message) -> None:
            if message["type"] == "http.response.start":
                state["started"] = True
                state["status"] = message["status"]
                headers = MutableHeaders(scope=message)
                headers[REQUEST_ID_HEADER] = request_id
                for name, value in security_headers.items():
                    if name not in headers:
                        headers[name] = value
                for name, value in scope.get(SCOPE_RESPONSE_HEADERS, {}).items():
                    if name not in headers:
                        headers[name] = value
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        except Exception as exc:  # last resort: a generic 500 without internals
            state["status"] = 500
            _error_log.error(
                "http.unhandled_exception",
                error_class=type(exc).__name__,
                frames=safe_traceback(exc),
            )
            if state["started"]:
                # Part of the response is already on the wire: let the server abort the
                # connection rather than presenting a truncated body as complete.
                raise
            await _send_problem(
                scope, receive, send_wrapper, InternalError, self.settings.public_base_url
            )
        finally:
            route = scope.get("route")
            _access_log.info(
                "http.request",
                method=scope.get("method"),
                route=getattr(route, "path", None) or "<unmatched>",
                status=state["status"],
                latency_ms=round((time.perf_counter() - started_at) * 1000, 2),
            )
            clear_request_context()


class BodyTooLargeError(StarletteHTTPException):
    """Raised from ``receive`` when a streamed body exceeds the limit.

    It subclasses Starlette's HTTPException so FastAPI's body parsing re-raises it unchanged and the
    HTTP exception handler turns it into ``413 payload_too_large``.
    """

    def __init__(self) -> None:
        super().__init__(status_code=413)


class BodySizeLimitMiddleware:
    def __init__(
        self, app: ASGIApp, *, settings: Settings, max_bytes: int = MAX_BODY_BYTES
    ) -> None:
        self.app = app
        self.settings = settings
        self.max_bytes = max_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        path = scope["path"]
        if path.startswith("/v1/instructions"):
            max_bytes = max(self.max_bytes, INSTRUCTION_BODY_BYTES)
        elif path.startswith("/webhooks/"):
            max_bytes = max(self.max_bytes, WEBHOOK_BODY_BYTES)
        else:
            max_bytes = self.max_bytes
        declared = Headers(scope=scope).get("content-length")
        if declared is not None:
            if not declared.isdigit():
                await _send_problem(
                    scope, receive, send, PayloadTooLarge, self.settings.public_base_url
                )
                return
            if int(declared) > max_bytes:
                await _send_problem(
                    scope, receive, send, PayloadTooLarge, self.settings.public_base_url
                )
                return

        received = 0
        started = False

        async def limited_receive() -> Message:
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > max_bytes:
                    raise BodyTooLargeError
            return message

        async def tracking_send(message: Message) -> None:
            nonlocal started
            if message["type"] == "http.response.start":
                started = True
            await send(message)

        try:
            await self.app(scope, limited_receive, tracking_send)
        except BodyTooLargeError:
            if started:
                raise
            await _send_problem(
                scope, receive, tracking_send, PayloadTooLarge, self.settings.public_base_url
            )


def parse_client_version(value: str | None) -> tuple[int, int, int] | None:
    """Parse ``android/1.2.3+45``. Returns ``None`` for a missing or malformed header."""
    if not value:
        return None
    match = _CLIENT_RE.match(value.strip())
    if match is None:
        return None
    return int(match[1]), int(match[2]), int(match[3])


class ClientVersionMiddleware:
    """``426 upgrade_required`` for app versions below ``MIN_CLIENT_VERSION`` (API routes only).

    A missing or malformed header is allowed: the header is a client claim, not a security control.
    """

    def __init__(self, app: ASGIApp, *, settings: Settings) -> None:
        self.app = app
        self.settings = settings
        self.minimum = settings.min_client_version_tuple

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        path: str = scope.get("path", "")
        if scope["type"] == "http" and (path == "/v1" or path.startswith("/v1/")):
            version = parse_client_version(Headers(scope=scope).get(CLIENT_HEADER))
            if version is not None and version < self.minimum:
                await _send_problem(
                    scope, receive, send, UpgradeRequired, self.settings.public_base_url
                )
                return
        await self.app(scope, receive, send)
