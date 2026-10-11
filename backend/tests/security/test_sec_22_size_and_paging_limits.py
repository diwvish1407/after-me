"""SEC-22: body-size limits and pagination caps (TEST_PLAN §5.2; ARCHITECTURE §4.4).

``test_http.py`` proves the 64 KiB cap on a generic test route and ``test_checkins.py`` the page
size of one list. This proves the limits where they differ per route and per door:

* ``/v1/instructions*`` may carry 96 KiB (20,000 characters can be 80,000 bytes), every other API
  route 64 KiB, the provider webhooks 512 KiB (a bounce event can quote the original message);
* a urlencoded form posted to a web page is held to the 64 KiB too, whether the size is declared
  (``Content-Length``) or only streamed (chunked), and the refusal changes nothing;
* the list routes refuse a page size above 100 (the API answers ``422``, it does not clamp).

A limit is a boundary: each is checked at the limit (accepted by the size check) and at limit + 1
(``413``).
"""

from __future__ import annotations

import base64
import json
from collections.abc import AsyncIterator
from typing import Any

import httpx
import psycopg
import pytest

from tests.security.sec_support import assert_unchanged, csrf_of, snapshot
from tests.support import Harness, bearer, problem

Db = psycopg.Connection[dict[str, Any]]

KIB = 1024
API_LIMIT = 64 * KIB
INSTRUCTION_LIMIT = 96 * KIB
WEBHOOK_LIMIT = 512 * KIB
WHSEC = "whsec_" + base64.b64encode(b"0123456789abcdef0123456789abcdef").decode()


def _json_of_size(total: int, template: dict[str, Any], field: str) -> bytes:
    """A JSON object of exactly ``total`` bytes: ``template`` with ``field`` padded with ``x``."""
    empty = json.dumps({**template, field: ""}, separators=(",", ":")).encode()
    padding = total - len(empty)
    assert padding >= 0
    body = json.dumps({**template, field: "x" * padding}, separators=(",", ":")).encode()
    assert len(body) == total
    return body


async def _streamed(content: bytes, piece: int = 8192) -> AsyncIterator[bytes]:
    for start in range(0, len(content), piece):
        yield content[start : start + piece]


JSON = {"content-type": "application/json"}


async def _post(
    client: httpx.AsyncClient,
    path: str,
    content: bytes,
    headers: dict[str, str],
    *,
    streamed: bool,
    method: str = "POST",
) -> httpx.Response:
    return await client.request(
        method, path, content=_streamed(content) if streamed else content, headers=headers
    )


# --- the API routes -------------------------------------------------------------------------------


@pytest.mark.parametrize("streamed", [False, True], ids=["declared", "streamed"])
async def test_instructions_take_96_kib_and_not_a_byte_more(h: Harness, streamed: bool) -> None:
    tokens = await h.signup("writer@example.com")
    headers = {**bearer(tokens), **JSON}
    template = {"category": "home", "title": "Big", "body": ""}

    at_the_limit = _json_of_size(INSTRUCTION_LIMIT, template, "body")
    accepted = await _post(h.client, "/v1/instructions", at_the_limit, headers, streamed=streamed)
    # past the size check, then refused for what it says (more than 20,000 characters)
    assert accepted.status_code == 422, accepted.text[:200]
    assert problem(accepted)["code"] == "validation_failed"
    assert any(e["field"] == "body" for e in problem(accepted)["errors"])

    over = _json_of_size(INSTRUCTION_LIMIT + 1, template, "body")
    refused = await _post(h.client, "/v1/instructions", over, headers, streamed=streamed)
    assert refused.status_code == 413
    assert problem(refused)["code"] == "payload_too_large"

    # the control: a body that is allowed to be this big, in the largest letters, is stored
    emoji = "\U0001f600" * 20_000  # 80,000 bytes of UTF-8: more than the API's 64 KiB
    payload = json.dumps({**template, "body": emoji}, ensure_ascii=False).encode()
    assert API_LIMIT < len(payload) < INSTRUCTION_LIMIT
    stored = await _post(h.client, "/v1/instructions", payload, headers, streamed=streamed)
    assert stored.status_code == 201, stored.text[:200]


async def test_an_instruction_update_has_the_same_allowance(h: Harness) -> None:
    tokens = await h.signup("editor@example.com")
    headers = {**bearer(tokens), **JSON}
    made = await h.client.post(
        "/v1/instructions",
        json={"category": "home", "title": "Small", "body": "text"},
        headers=bearer(tokens),
    )
    assert made.status_code == 201
    path = f"/v1/instructions/{made.json()['id']}"
    over = _json_of_size(INSTRUCTION_LIMIT + 1, {"title": "T"}, "body")
    refused = await _post(h.client, path, over, headers, streamed=False, method="PATCH")
    assert refused.status_code == 413
    # 70 KB is over the general cap and under this one: accepted by the size check
    payload = json.dumps({"body": "y" * 70_000}).encode()
    assert API_LIMIT < len(payload) < INSTRUCTION_LIMIT
    # ... and then refused only for being more than 20,000 characters
    answered = await _post(h.client, path, payload, headers, streamed=False, method="PATCH")
    assert answered.status_code == 422


@pytest.mark.parametrize("streamed", [False, True], ids=["declared", "streamed"])
async def test_every_other_api_route_takes_64_kib_and_not_a_byte_more(
    h: Harness, streamed: bool
) -> None:
    tokens = await h.signup("small@example.com")
    headers = {**bearer(tokens), **JSON}
    template = {"display_name": "N"}
    for path, method in (("/v1/contacts", "POST"), ("/v1/me/profile", "PATCH")):
        at_the_limit = _json_of_size(API_LIMIT, template, "display_name")
        accepted = await _post(
            h.client, path, at_the_limit, headers, streamed=streamed, method=method
        )
        assert accepted.status_code == 422, (path, accepted.status_code)  # past the size check
        over = _json_of_size(API_LIMIT + 1, template, "display_name")
        refused = await _post(h.client, path, over, headers, streamed=streamed, method=method)
        assert refused.status_code == 413, path
        assert problem(refused)["code"] == "payload_too_large"
    # the instruction allowance is for ``/v1/instructions`` only
    over_for_others = _json_of_size(API_LIMIT + 1, {"confirm": "DELETE"}, "x")
    refused = await _post(
        h.client, "/v1/me", over_for_others, headers, streamed=streamed, method="DELETE"
    )
    assert refused.status_code == 413


# --- the webhooks ---------------------------------------------------------------------------------


@pytest.mark.settings(
    email_provider="resend", email_api_key="re_test_key_00000000", email_webhook_secret=WHSEC
)
@pytest.mark.parametrize("streamed", [False, True], ids=["declared", "streamed"])
async def test_a_webhook_takes_512_kib_and_not_a_byte_more(h: Harness, streamed: bool) -> None:
    headers = {"content-type": "application/json"}
    at_the_limit = _json_of_size(WEBHOOK_LIMIT, {"type": "email.bounced"}, "pad")
    over = _json_of_size(WEBHOOK_LIMIT + 1, {"type": "email.bounced"}, "pad")
    middling = _json_of_size(100 * KIB, {"type": "email.bounced"}, "pad")

    refused = await _post(h.client, "/webhooks/email/resend", over, headers, streamed=streamed)
    assert refused.status_code == 413
    assert problem(refused)["code"] == "payload_too_large"
    # at the limit, and at 100 KiB (over the API's cap): through the size check, to the signature
    for body in (at_the_limit, middling):
        answered = await _post(h.client, "/webhooks/email/resend", body, headers, streamed=streamed)
        assert answered.status_code == 401  # unsigned: refused for that, not for its size


# --- forms posted to the web pages ----------------------------------------------------------------


@pytest.mark.parametrize("streamed", [False, True], ids=["declared", "streamed"])
@pytest.mark.parametrize(
    ("path", "page", "fields"),
    [
        ("/a/login", "/a/login", {"email": "someone@example.com", "password": "x"}),
        ("/c/release/session", "/c/release", {"token": "rt_" + "A" * 43}),
        ("/a/reset", "/a/reset", {"token": "pr_" + "A" * 43}),
    ],
    ids=["a-login", "c-release-session", "a-reset"],
)
async def test_an_oversized_form_is_refused_before_it_is_read_and_changes_nothing(
    h: Harness, owner_db: Db, path: str, page: str, fields: dict[str, str], streamed: bool
) -> None:
    await h.signup("someone@example.com")
    csrf = csrf_of(await h.client.get(page))
    form_headers = {"content-type": "application/x-www-form-urlencoded"}

    def encoded(total: int) -> bytes:
        head = "&".join(f"{k}={v}" for k, v in {**fields, "csrf": csrf}.items()) + "&pad="
        return head.encode() + b"a" * (total - len(head))

    before = snapshot(owner_db)
    over = await _post(h.client, path, encoded(API_LIMIT + 1), form_headers, streamed=streamed)
    assert over.status_code == 413
    assert problem(over)["code"] == "payload_too_large"
    assert_unchanged(before, snapshot(owner_db), f"an oversized form to {path}")

    # at the limit the size check lets it through (the page then judges the form itself)
    at_limit = await _post(h.client, path, encoded(API_LIMIT), form_headers, streamed=streamed)
    assert at_limit.status_code != 413
    # and a form of ordinary size works as it always did
    ordinary = await h.client.post(path, data={**fields, "csrf": csrf})
    assert ordinary.status_code in (200, 303, 400, 401, 422), ordinary.status_code


# --- page sizes -----------------------------------------------------------------------------------


@pytest.mark.parametrize("path", ["/v1/incidents", "/v1/activity", "/v1/checkins"])
async def test_a_page_of_more_than_a_hundred_is_refused_not_clamped(h: Harness, path: str) -> None:
    tokens = await h.signup("pager@example.com")
    headers = bearer(tokens)
    for bad in (101, 1000, 0, -1):
        response = await h.client.get(path, params={"limit": bad}, headers=headers)
        assert response.status_code == 422, (path, bad)
        body = problem(response)
        assert body["code"] == "validation_failed"
        assert [e["field"] for e in body["errors"]] == ["limit"]
    junk = await h.client.get(path, params={"limit": "many"}, headers=headers)
    assert junk.status_code == 422
    for good in (1, 20, 100):
        response = await h.client.get(path, params={"limit": good}, headers=headers)
        assert response.status_code == 200, (path, good)
    assert (await h.client.get(path, headers=headers)).status_code == 200  # the default page
