from __future__ import annotations

import io
import json
import logging
import uuid
from collections.abc import Iterator

import pytest
import structlog

from app.core.logging import (
    REDACTED,
    build_formatter,
    configure_logging,
    get_logger,
    mask_text,
    redact,
    safe_traceback,
    snapshot_event,
)
from tests.support import make_settings

pytestmark = pytest.mark.no_db

JWT = "eyJhbGciOiJFZERTQSJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXZhbHVlLWhlcmU"
REFRESH = "rt_Q2hhbmdlTWVQbGVhc2VUaGlzSXNBVGVzdFRva2Vu"


@pytest.fixture
def captured() -> Iterator[io.StringIO]:
    configure_logging(make_settings(log_level="DEBUG"))
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(build_formatter(json=True))
    root = logging.getLogger()
    root.addHandler(handler)
    try:
        yield stream
    finally:
        root.removeHandler(handler)
        configure_logging(make_settings())


def _lines(stream: io.StringIO) -> list[dict[str, object]]:
    return [json.loads(line) for line in stream.getvalue().splitlines() if line.strip()]


@pytest.mark.parametrize(
    "key",
    [
        "password",
        "new_password",
        "token",
        "access_token",
        "refresh_token",
        "authorization",
        "Authorization",
        "code",
        "otp",
        "cookie",
        "email",
        "email_normalized",
        "phone",
        "phone_e164",
        "title",
        "body",
        "x_api_key",
        "hmac_pepper",
    ],
)
def test_sensitive_keys_are_redacted(key: str) -> None:
    event = snapshot_event({"event": "something", key: "value-that-must-not-appear"})
    assert event[key] == REDACTED


def test_ordinary_keys_survive() -> None:
    user_id = str(uuid.uuid4())
    event = snapshot_event(
        {"event": "http.request", "status": 401, "error_code": "invalid_code", "user_id": user_id}
    )
    assert event == {
        "event": "http.request",
        "status": 401,
        "error_code": "invalid_code",
        "user_id": user_id,
    }


def test_values_are_masked_anywhere() -> None:
    event = snapshot_event(
        {
            "event": f"login for Someone.Else@Example.org with {JWT}",
            "detail": {"nested": [f"Bearer {REFRESH}", "ok"], "note": "x" * 48},
            "raw": b"bytes",
        }
    )
    text = json.dumps(event)
    assert "Example.org" not in text
    assert JWT not in text
    assert REFRESH not in text
    assert "x" * 48 not in text
    assert event["raw"] == "[BYTES]"
    assert "[EMAIL]" in str(event["event"])


def test_mask_text_keeps_uuids_and_paths() -> None:
    value = f"session {uuid.uuid4()} file /a/b/.dev_mail/20261008T101500123456Z.signup_code.abc.txt"
    assert mask_text(value) == value


def test_deeply_nested_values_are_dropped() -> None:
    nested: dict[str, object] = {"v": "end"}
    for _ in range(10):
        nested = {"n": nested}
    event = snapshot_event({"event": "deep", "data": nested})
    assert REDACTED in json.dumps(event)


def test_redact_skips_private_structlog_keys() -> None:
    event = redact(None, "info", {"_record": "x", "event": "ok"})
    assert event["_record"] == "x"


def test_structlog_and_stdlib_records_are_redacted(captured: io.StringIO) -> None:
    log = get_logger("afterme.test")
    log.info("user.event", email="a@b.example", password="hunter2hunter2", status=200)
    logging.getLogger("thirdparty").warning("contact me at leak@example.com token %s", REFRESH)
    lines = _lines(captured)
    text = captured.getvalue()
    assert "a@b.example" not in text
    assert "hunter2hunter2" not in text
    assert "leak@example.com" not in text
    assert REFRESH not in text
    assert lines[0]["status"] == 200
    assert lines[0]["logger"] == "afterme.test"
    assert lines[1]["logger"] == "thirdparty"


def test_exceptions_are_masked(captured: io.StringIO) -> None:
    try:
        msg = "duplicate key (email)=(dup@example.com)"
        raise ValueError(msg)
    except ValueError:
        logging.getLogger("thirdparty").exception("failed")
    text = captured.getvalue()
    assert "dup@example.com" not in text
    assert "ValueError" in text


def test_contextvars_are_merged(captured: io.StringIO) -> None:
    structlog.contextvars.bind_contextvars(request_id="req-123")
    try:
        get_logger("afterme.test").info("with.context")
    finally:
        structlog.contextvars.clear_contextvars()
    assert _lines(captured)[0]["request_id"] == "req-123"


def test_safe_traceback_has_no_messages() -> None:
    try:
        msg = "secret message user@example.com"
        raise RuntimeError(msg)
    except RuntimeError as exc:
        frames = safe_traceback(exc)
    assert frames
    assert all("secret" not in f for f in frames)
    assert frames[-1].startswith("test_logging.py:")


def test_dev_uses_console_renderer_and_uvicorn_access_log_is_off() -> None:
    configure_logging(
        make_settings(app_env="dev", argon2_time_cost=2, argon2_memory_cost_kib=19456)
    )
    try:
        assert logging.getLogger("uvicorn.access").disabled
        assert logging.getLogger("sqlalchemy.engine").level == logging.WARNING
        ours = [h for h in logging.getLogger().handlers if getattr(h, "_afterme_handler", False)]
        assert len(ours) == 1
    finally:
        configure_logging(make_settings())


@pytest.mark.parametrize(
    ("method", "expected"),
    [
        ("debug", "DEBUG"),
        ("info", "INFO"),
        ("warning", "WARNING"),
        ("error", "ERROR"),
        ("critical", "CRITICAL"),
    ],
)
def test_json_lines_carry_the_severity_cloud_logging_reads(method: str, expected: str) -> None:
    """Cloud Logging takes the severity of a JSON line from ``severity`` (upper case); without
    it every line is DEFAULT and no severity-based alert can see an error (Phase 12)."""
    import io
    import json
    import logging

    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(build_formatter(json=True))
    handler.setLevel(logging.DEBUG)
    logger = logging.getLogger(f"severity-test-{method}")
    logger.addHandler(handler)
    logger.setLevel(logging.DEBUG)
    logger.propagate = False
    try:
        getattr(logger, method)("something happened")
    finally:
        logger.removeHandler(handler)
    line = json.loads(stream.getvalue().splitlines()[-1])
    assert line["severity"] == expected
    assert line["level"] == method
