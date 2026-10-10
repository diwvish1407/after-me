"""Structured logging with redaction (SECURITY §10).

* structlog renders JSON in staging/prod/test and a readable console format in dev.
* Every record, including those from third-party libraries routed through ``logging``, passes the
  :func:`redact` processor before rendering: sensitive keys are replaced and email-like or
  token-like values are masked wherever they appear.
* Request and response bodies are never logged. The access log records the route template.
"""

from __future__ import annotations

import logging
import re
import sys
import traceback
from collections.abc import Mapping, MutableMapping
from typing import Any, Final

import structlog
from structlog.typing import EventDict, Processor, WrappedLogger

from app.core.config import AppEnv, Settings

REDACTED: Final = "[REDACTED]"

# Exact key names that always hold sensitive values.
_SENSITIVE_KEYS: Final = frozenset(
    {
        "password",
        "new_password",
        "current_password",
        "token",
        "access_token",
        "refresh_token",
        "authorization",
        "code",
        "otp",
        "pin",
        "cookie",
        "set-cookie",
        "set_cookie",
        "email",
        "phone",
        "phone_e164",
        "title",
        "body",
        "secret",
        "pepper",
        "private_key",
        "display_name",
        "to",
    }
)
# Key fragments: any key containing one of these is sensitive (e.g. ``email_normalized``).
_SENSITIVE_KEY_PARTS: Final = (
    "password",
    "passwd",
    "token",
    "secret",
    "authorization",
    "cookie",
    "email",
    "phone",
    "otp",
    "pepper",
    "api_key",
    "apikey",
    "private_key",
    "credential",
)

_EMAIL_RE: Final = re.compile(
    r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+"
)
_JWT_RE: Final = re.compile(r"eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*")
_REFRESH_RE: Final = re.compile(r"rt_[A-Za-z0-9_-]{16,}")
_BEARER_RE: Final = re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+")
# Long opaque strings (random tokens, hashes, keys). UUIDs (36 chars) stay readable.
_OPAQUE_RE: Final = re.compile(r"[A-Za-z0-9_-]{40,}")


def _is_sensitive_key(key: str) -> bool:
    lowered = key.lower()
    return lowered in _SENSITIVE_KEYS or any(part in lowered for part in _SENSITIVE_KEY_PARTS)


def mask_text(value: str) -> str:
    """Mask email addresses and token-like substrings in free text."""
    value = _BEARER_RE.sub("Bearer [TOKEN]", value)
    value = _JWT_RE.sub("[TOKEN]", value)
    value = _REFRESH_RE.sub("[TOKEN]", value)
    value = _EMAIL_RE.sub("[EMAIL]", value)
    return _OPAQUE_RE.sub("[OPAQUE]", value)


def _redact_value(value: Any, depth: int = 0) -> Any:
    if depth > 6:  # noqa: PLR2004 - pathological nesting: drop rather than recurse forever
        return REDACTED
    if isinstance(value, str):
        return mask_text(value)
    if isinstance(value, bytes):
        return "[BYTES]"
    if isinstance(value, Mapping):
        return {
            str(k): (REDACTED if _is_sensitive_key(str(k)) else _redact_value(v, depth + 1))
            for k, v in value.items()
        }
    if isinstance(value, (list, tuple, set, frozenset)):
        return [_redact_value(v, depth + 1) for v in value]
    return value


def redact(_logger: WrappedLogger, _method: str, event_dict: EventDict) -> EventDict:
    """structlog processor: drop sensitive keys and mask sensitive-looking values."""
    for key in list(event_dict):
        if key.startswith("_"):
            continue
        if _is_sensitive_key(key):
            event_dict[key] = REDACTED
        else:
            event_dict[key] = _redact_value(event_dict[key])
    return event_dict


def _timestamper() -> Processor:
    return structlog.processors.TimeStamper(fmt="iso", utc=True)


def build_formatter(*, json: bool) -> logging.Formatter:
    """The formatter used for every handler: structlog chain + redaction + renderer."""
    renderer: Processor
    if json:
        renderer = structlog.processors.JSONRenderer(sort_keys=True)
    else:
        renderer = structlog.dev.ConsoleRenderer(colors=sys.stdout.isatty())
    return structlog.stdlib.ProcessorFormatter(
        foreign_pre_chain=[
            structlog.contextvars.merge_contextvars,
            structlog.stdlib.add_logger_name,
            structlog.stdlib.add_log_level,
            _timestamper(),
        ],
        processors=[
            structlog.stdlib.ProcessorFormatter.remove_processors_meta,
            structlog.processors.format_exc_info,
            redact,
            renderer,
        ],
    )


_HANDLER_MARK = "_afterme_handler"


def configure_logging(settings: Settings) -> None:
    """Configure structlog and the stdlib root logger. Safe to call more than once."""
    use_json = settings.app_env is not AppEnv.DEV
    level = logging.getLevelName(settings.log_level)

    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.stdlib.filter_by_level,
            structlog.stdlib.add_logger_name,
            structlog.stdlib.add_log_level,
            _timestamper(),
            structlog.stdlib.ProcessorFormatter.wrap_for_formatter,
        ],
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.stdlib.BoundLogger,
        cache_logger_on_first_use=False,
    )

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(build_formatter(json=use_json))
    setattr(handler, _HANDLER_MARK, True)

    root = logging.getLogger()
    for existing in list(root.handlers):
        if getattr(existing, _HANDLER_MARK, False):
            root.removeHandler(existing)
    root.addHandler(handler)
    root.setLevel(level)

    # Uvicorn installs its own handlers; route its records through ours instead.
    for name in ("uvicorn", "uvicorn.error"):
        uv_logger = logging.getLogger(name)
        uv_logger.handlers.clear()
        uv_logger.propagate = True
    # Uvicorn's access log prints raw paths with query strings; ours logs route templates.
    access = logging.getLogger("uvicorn.access")
    access.handlers.clear()
    access.propagate = False
    access.disabled = True
    # SQL statements and parameters are never logged, whatever LOG_LEVEL says.
    logging.getLogger("sqlalchemy.engine").setLevel(logging.WARNING)
    logging.getLogger("sqlalchemy.pool").setLevel(logging.WARNING)


def get_logger(name: str) -> structlog.stdlib.BoundLogger:
    logger: structlog.stdlib.BoundLogger = structlog.stdlib.get_logger(name)
    return logger


def bind_request_context(**values: Any) -> None:
    structlog.contextvars.bind_contextvars(**values)


def clear_request_context() -> None:
    structlog.contextvars.clear_contextvars()


def safe_traceback(exc: BaseException) -> list[str]:
    """Stack frames (file:line in function) without exception messages or locals."""
    frames = traceback.extract_tb(exc.__traceback__)
    return [f"{f.filename.rsplit('/', 1)[-1]}:{f.lineno} in {f.name}" for f in frames][-20:]


def snapshot_event(event: MutableMapping[str, Any]) -> dict[str, Any]:
    """Apply :func:`redact` to a plain dict (used by tests and by callers building log payloads)."""
    return dict(redact(None, "info", dict(event)))
