"""SEC-22: body-size limits and pagination caps (TEST_PLAN §5.2; API_SPEC §1 and §10).

The limits are one number each, in one middleware, and are checked at the byte: a body of exactly
the limit gets through, one byte more is ``413 payload_too_large`` (by ``Content-Length`` and,
when none is sent, as it streams in). The generic 64 KiB route is in ``test_http.py``; this file
covers the three exceptions and the pages of HTML that read forms, and the list routes that were
not covered (``/v1/incidents`` and ``/v1/activity``).

Numbers are written out on purpose (API_SPEC §10: 96 KiB for the instruction routes, §14: 512 KiB
for webhooks, 64 KiB for everything else): a constant changed in the application must fail here.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
from collections.abc import AsyncIterator
from typing import Any
from urllib.parse import urlencode

import psycopg
import pytest

from app.main import create_app
from tests.security.sec_support import csrf_of, snapshot
from tests.support import PASSWORD, Harness, bearer, make_settings, problem

Db = psycopg.Connection[dict[str, Any]]

GENERAL_CAP = 64 * 1024
INSTRUCTION_CAP = 96 * 1024
WEBHOOK_CAP = 512 * 1024
EMAIL = "sizes@example.com"
WHSEC = "whsec_" + base64.b64encode(b"0123456789abcdef0123456789abcdef").decode()


def _padded(document: dict[str, Any], size: int) -> bytes:
    """``document`` as JSON padded with trailing whitespace to exactly ``size`` bytes."""
    raw = json.dumps(document, ensure_ascii=False).encode()
    assert len(raw) <= size
    return raw + b" " * (size - len(raw))


async def _chunked(raw: bytes, step: int = 8192) -> AsyncIterator[bytes]:
    for start in range(0, len(raw), step):
        yield raw[start : start + step]


JSON = {"content-type": "application/json"}
INSTRUCTION = {"category": "home", "title": "House", "body": "Where the key is."}


# --- the instruction routes: 96 KiB -------------------------------------------------------------


async def test_instruction_bodies_may_be_96_kib_and_not_a_byte_more(
    h: Harness, owner_db: Db
) -> None:
    tokens = await h.signup(EMAIL)
    headers = {**bearer(tokens), **JSON}
    assert (await h.reauth(tokens)).status_code == 204

    # a body of 20,000 four-byte characters is 80,000 bytes: the reason the cap is not 64 KiB
    big = {**INSTRUCTION, "body": "\U0001f511" * 20_000}
    raw = json.dumps(big, ensure_ascii=False).encode()
    assert GENERAL_CAP < len(raw) < INSTRUCTION_CAP
    accepted = await h.client.post("/v1/instructions", content=raw, headers=headers)
    assert accepted.status_code == 201, accepted.text

    # exactly the limit passes the size check (trailing whitespace is legal JSON) ...
    at_limit = await h.client.post(
        "/v1/instructions", content=_padded(INSTRUCTION, INSTRUCTION_CAP), headers=headers
    )
    assert at_limit.status_code == 201, at_limit.text

    # ... one byte more does not, however it is sent
    before = snapshot(owner_db)
    over = _padded(INSTRUCTION, INSTRUCTION_CAP + 1)
    declared = await h.client.post("/v1/instructions", content=over, headers=headers)
    assert declared.status_code == 413
    assert problem(declared)["code"] == "payload_too_large"
    streamed = await h.client.post("/v1/instructions", content=_chunked(over), headers=headers)
    assert streamed.status_code == 413
    assert problem(streamed)["code"] == "payload_too_large"
    assert snapshot(owner_db) == before  # nothing was stored or audited

    # a 20,001-character body fits in the bytes and is the validator's 422, not the cap's 413
    long_text = {**INSTRUCTION, "body": "a" * 20_001}
    refused = await h.client.post(
        "/v1/instructions", content=json.dumps(long_text).encode(), headers=headers
    )
    assert refused.status_code == 422


async def test_the_larger_cap_belongs_to_the_instruction_routes_only(
    h: Harness, owner_db: Db
) -> None:
    tokens = await h.signup(EMAIL)
    headers = {**bearer(tokens), **JSON}
    assert (await h.reauth(tokens)).status_code == 204
    made = await h.client.post("/v1/instructions", json=INSTRUCTION, headers=headers)
    assert made.status_code == 201
    path = f"/v1/instructions/{made.json()['id']}"

    # the same 70,000 bytes: fine on the instruction routes (PATCH too) ...
    body = _padded({"title": "Still the house"}, GENERAL_CAP + 1000)
    patched = await h.client.patch(path, content=body, headers=headers)
    assert patched.status_code == 200, patched.text

    # ... and 413 on every other route, authenticated or not
    before = snapshot(owner_db)
    for method, route in (
        ("PATCH", "/v1/me/profile"),
        ("POST", "/v1/contacts"),
        ("PUT", "/v1/plan"),
        ("POST", "/v1/auth/login"),
        ("POST", "/v1/checkins"),
    ):
        response = await h.client.request(method, route, content=body, headers=headers)
        assert response.status_code == 413, (method, route)
        assert problem(response)["code"] == "payload_too_large"
    # and not even the instruction routes take more than their cap
    over = _padded({"title": "x"}, INSTRUCTION_CAP + 1)
    assert (await h.client.patch(path, content=over, headers=headers)).status_code == 413
    assert snapshot(owner_db) == before


# --- webhooks: 512 KiB --------------------------------------------------------------------------


def _signed(raw: bytes, stamp: int) -> dict[str, str]:
    key = base64.b64decode(WHSEC.removeprefix("whsec_"))
    digest = hmac.new(key, f"msg_big.{stamp}.".encode() + raw, hashlib.sha256).digest()
    return {
        **JSON,
        "svix-id": "msg_big",
        "svix-timestamp": str(stamp),
        "svix-signature": "v1," + base64.b64encode(digest).decode(),
    }


@pytest.mark.settings(
    email_provider="resend", email_api_key="re_test_key_00000000", email_webhook_secret=WHSEC
)
async def test_a_webhook_body_may_be_512_kib_and_not_a_byte_more(h: Harness, owner_db: Db) -> None:
    event = {"type": "email.delivered", "data": {"email_id": "not-ours"}}
    stamp = int(h.clock.current.timestamp())

    # a signed event of exactly 512 KiB is read, verified and acknowledged ...
    at_limit = _padded(event, WEBHOOK_CAP)
    accepted = await h.client.post(
        "/webhooks/email/resend", content=at_limit, headers=_signed(at_limit, stamp)
    )
    assert accepted.status_code == 204

    # ... an unsigned one of that size gets as far as the signature check and no further
    unsigned = await h.client.post("/webhooks/email/resend", content=at_limit, headers=JSON)
    assert unsigned.status_code == 401

    # one byte more is refused before anything looks at it (a validly signed body included)
    before = snapshot(owner_db)
    over = _padded(event, WEBHOOK_CAP + 1)
    for headers in (JSON, _signed(over, stamp)):
        declared = await h.client.post("/webhooks/email/resend", content=over, headers=headers)
        assert declared.status_code == 413
        assert problem(declared)["code"] == "payload_too_large"
        streamed = await h.client.post(
            "/webhooks/email/resend", content=_chunked(over), headers=headers
        )
        assert streamed.status_code == 413
    assert snapshot(owner_db) == before


# --- the HTML forms: 64 KiB, and ten fields ------------------------------------------------------

FORM_ROUTES = [
    ("/a/login", "/a/login"),
    ("/a/reset", "/a/reset"),
    ("/a/delete", "/a/delete"),
    ("/a/delete/confirm", "/a/delete/confirm"),
    ("/a/checkin", "/a/login"),
    ("/c/session", "/c/open"),
    ("/c/release/session", "/c/release"),
]


@pytest.mark.no_rate_limit
@pytest.mark.parametrize(("path", "form_page"), FORM_ROUTES)
async def test_an_oversized_form_is_413_and_changes_nothing(
    h: Harness, owner_db: Db, path: str, form_page: str
) -> None:
    await h.signup(EMAIL)
    csrf = csrf_of(await h.client.get(form_page))
    before = snapshot(owner_db)
    mail = len(h.mail.messages)
    form = {"email": EMAIL, "password": PASSWORD, "token": "x", "csrf": csrf}
    form_type = {"content-type": "application/x-www-form-urlencoded"}

    # the filler is a field of its own: a valid CSRF pair is no help
    filler = "a" * (GENERAL_CAP + 1)
    body = urlencode({**form, "note": filler}).encode()
    assert len(body) > GENERAL_CAP
    declared = await h.client.post(path, content=body, headers=form_type)
    assert declared.status_code == 413
    assert problem(declared)["code"] == "payload_too_large"
    streamed = await h.client.post(path, content=_chunked(body), headers=form_type)
    assert streamed.status_code == 413
    assert "set-cookie" not in declared.headers  # no session, no cookie of any kind
    assert snapshot(owner_db) == before
    assert len(h.mail.messages) == mail

    # control: the same form without the filler reaches the route (any answer but 413)
    small = await h.client.post(path, data=form)
    assert small.status_code != 413


@pytest.mark.no_rate_limit
async def test_a_form_with_more_than_ten_fields_is_not_read(h: Harness, owner_db: Db) -> None:
    """``read_form`` caps the field count, so a flood of tiny fields (a parser-time cost, not
    a byte count) is an empty form: the CSRF check fails and the page says it expired."""
    await h.signup(EMAIL)
    csrf = csrf_of(await h.client.get("/a/login"))
    before = snapshot(owner_db)
    base = {"email": EMAIL, "password": "wrong password here", "csrf": csrf}

    ten = {**base, **{f"f{n}": "x" for n in range(7)}}
    assert len(ten) == 10
    read = await h.client.post("/a/login", data=ten)
    assert read.status_code == 401  # parsed: it is a wrong password

    eleven = {**ten, "f7": "x"}
    assert len(eleven) == 11
    refused = await h.client.post("/a/login", data=eleven)
    assert refused.status_code == 403
    assert "expired" in refused.text
    # the wrong password of the first request left its audit trail; the second left nothing
    after_ten = snapshot(owner_db)
    assert after_ten != before
    await h.client.post("/a/login", data=eleven)
    assert snapshot(owner_db) == after_ten


# --- pages: limit 1..100 --------------------------------------------------------------------------

LIST_ROUTES = ["/v1/incidents", "/v1/activity", "/v1/checkins"]


@pytest.mark.parametrize("path", LIST_ROUTES)
async def test_a_page_is_at_most_a_hundred_rows(h: Harness, path: str) -> None:
    tokens = await h.signup(EMAIL)
    headers = bearer(tokens)

    for limit in ("100", "1"):
        ok = await h.client.get(path, params={"limit": limit}, headers=headers)
        assert ok.status_code == 200, (path, limit)
        assert len(ok.json()["items"]) <= int(limit)
    for limit in ("101", "0", "-1", "1000000", "abc", "1.5", ""):
        refused = await h.client.get(path, params={"limit": limit}, headers=headers)
        assert refused.status_code == 422, (path, limit)
        body = problem(refused)
        assert body["code"] == "validation_failed"
        assert body["errors"][0]["field"].endswith("limit")
    # a cursor is bounded too (it is parsed, not trusted)
    long_cursor = await h.client.get(path, params={"cursor": "A" * 257}, headers=headers)
    assert long_cursor.status_code == 422


async def test_every_list_route_that_takes_a_limit_is_listed_above() -> None:
    """A new paginated route must show up here (and so in the 422 test) or the build fails."""
    app = create_app(make_settings())
    try:
        schema = app.openapi()
    finally:
        await app.state.services.db.dispose()
    paged: dict[str, int | None] = {}
    for path, item in schema["paths"].items():
        operation = item.get("get")
        if operation is None:
            continue
        for parameter in operation.get("parameters", []):
            if parameter["name"] == "limit":
                paged[path] = parameter["schema"].get("maximum")
    assert set(paged) == set(LIST_ROUTES), paged
    assert all(maximum == 100 for maximum in paged.values()), paged
