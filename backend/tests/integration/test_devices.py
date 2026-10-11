"""``PUT /v1/devices/current`` and ``DELETE /v1/devices/current/push-token`` (API_SPEC §4)."""

from __future__ import annotations

from typing import Any

import psycopg

from tests.support import DEVICE, Harness, bearer

Conn = psycopg.Connection[dict[str, Any]]
TOKEN_A = "fcm-token-aaaaaaaaaaaaaaaaaaaaaaaa"
TOKEN_B = "fcm-token-bbbbbbbbbbbbbbbbbbbbbbbb"


def _token(db: Conn, device_id: str) -> str | None:
    row = db.execute("SELECT push_token FROM devices WHERE id = %s", (device_id,)).fetchone()
    assert row is not None
    return row["push_token"]  # type: ignore[no-any-return]


async def _put(h: Harness, tokens: dict[str, Any], **extra: Any) -> Any:
    return await h.client.put(
        "/v1/devices/current", json={**DEVICE, **extra}, headers=bearer(tokens)
    )


async def test_a_phone_registers_keeps_changes_and_removes_its_token(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await h.signup("push@example.com")
    device = tokens["device_id"]

    created = await _put(h, tokens, push_token=TOKEN_A)
    assert created.status_code == 200, created.text
    assert created.json() == {"device_id": device, "push_registered": True}
    assert _token(owner_db, device) == TOKEN_A
    assert TOKEN_A not in created.text  # never echoed

    kept = await _put(h, tokens)  # the field is absent: the token stays
    assert kept.json()["push_registered"] is True
    assert _token(owner_db, device) == TOKEN_A

    changed = await _put(h, tokens, push_token=TOKEN_B)
    assert changed.json()["push_registered"] is True
    assert _token(owner_db, device) == TOKEN_B

    removed = await _put(h, tokens, push_token=None)  # null: the person turned notifications off
    assert removed.json() == {"device_id": device, "push_registered": False}
    assert _token(owner_db, device) is None

    await _put(h, tokens, push_token=TOKEN_A)
    gone = await h.client.delete("/v1/devices/current/push-token", headers=bearer(tokens))
    assert gone.status_code == 204
    assert _token(owner_db, device) is None


async def test_the_phone_updates_what_it_says_about_itself(h: Harness, owner_db: Conn) -> None:
    tokens = await h.signup("info@example.com")
    response = await _put(h, tokens, app_version="1.2.3+45", os_version="16", locale="en-IN")
    assert response.status_code == 200
    row = owner_db.execute(
        "SELECT app_version, os_version, locale FROM devices WHERE id = %s", (tokens["device_id"],)
    ).fetchone()
    assert row == {"app_version": "1.2.3+45", "os_version": "16", "locale": "en-IN"}


async def test_a_token_has_one_holder_a_new_owner_takes_it_from_the_old(
    h: Harness, owner_db: Conn
) -> None:
    """A phone that changed hands: pushes for the previous owner must stop at once."""
    first = await h.signup("first@example.com")
    second = await h.signup("second@example.com")
    assert (await _put(h, first, push_token=TOKEN_A)).json()["push_registered"] is True
    assert _token(owner_db, first["device_id"]) == TOKEN_A

    assert (await _put(h, second, push_token=TOKEN_A)).json()["push_registered"] is True
    assert _token(owner_db, second["device_id"]) == TOKEN_A
    assert _token(owner_db, first["device_id"]) is None


async def test_bad_tokens_and_unknown_fields_are_refused(h: Harness) -> None:
    tokens = await h.signup("bad@example.com")
    for token in ("short", "has spaces in it - not a token", "x" * 5000, "tab\tinside" + "x" * 20):
        response = await _put(h, tokens, push_token=token)
        assert response.status_code == 422, token
    extra = await _put(h, tokens, push_token=TOKEN_A, user_id="someone-else")
    assert extra.status_code == 422
    wrong_platform = await h.client.put(
        "/v1/devices/current",
        json={**DEVICE, "platform": "ios"},
        headers=bearer(tokens),
    )
    assert wrong_platform.status_code == 422


async def test_logout_clears_the_phones_token(h: Harness, owner_db: Conn) -> None:
    tokens = await h.signup("logout@example.com")
    await _put(h, tokens, push_token=TOKEN_A)
    assert (await h.client.post("/v1/auth/logout", headers=bearer(tokens))).status_code == 204
    assert _token(owner_db, tokens["device_id"]) is None
