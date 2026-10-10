"""``PATCH /v1/me/profile`` (API_SPEC §3)."""

from __future__ import annotations

from typing import Any

import httpx
import psycopg
import pytest

from tests.support import Harness, bearer, problem

Db = psycopg.Connection[dict[str, Any]]


async def _patch(h: Harness, tokens: dict[str, Any], body: Any) -> httpx.Response:
    return await h.client.patch("/v1/me/profile", json=body, headers=bearer(tokens))


async def _me(h: Harness, tokens: dict[str, Any]) -> dict[str, Any]:
    response = await h.client.get("/v1/me", headers=bearer(tokens))
    body: dict[str, Any] = response.json()
    return body


async def test_patch_updates_the_given_fields_only(h: Harness) -> None:
    tokens = await h.signup("patch@example.com")
    before = await _me(h, tokens)
    response = await _patch(
        h, tokens, {"display_name": "  Asha Rao ", "phone_e164": "+919876543210"}
    )
    assert response.status_code == 200
    body = response.json()
    assert body == await _me(h, tokens)  # same body as GET /me
    assert body["profile"] == {
        **before["profile"],
        "display_name": "Asha Rao",
        "phone_e164": "+919876543210",
    }
    assert {k: v for k, v in body.items() if k != "profile"} == {
        k: v for k, v in before.items() if k != "profile"
    }


async def test_patch_every_field_and_normalise_values(h: Harness) -> None:
    tokens = await h.signup("all@example.com")
    response = await _patch(
        h,
        tokens,
        {
            "display_name": "Zoë Müller",
            "phone_e164": "+14155552671",
            "country_code": "in",
            "timezone": "Europe/London",
            "locale": "EN-in",
        },
    )
    assert response.status_code == 200
    assert response.json()["profile"] == {
        "display_name": "Zoë Müller",
        "phone_e164": "+14155552671",
        "country_code": "IN",
        "timezone": "Europe/London",
        "locale": "en-IN",
    }


async def test_null_clears_phone_and_country_only(h: Harness) -> None:
    tokens = await h.signup("clear@example.com")
    await _patch(h, tokens, {"phone_e164": "+14155552671", "country_code": "IN"})
    cleared = await _patch(h, tokens, {"phone_e164": None, "country_code": None})
    assert cleared.status_code == 200
    profile = cleared.json()["profile"]
    assert profile["phone_e164"] is None
    assert profile["country_code"] is None
    assert profile["display_name"] == "Test User"  # untouched
    # Clearing something that is already empty is fine.
    assert (await _patch(h, tokens, {"phone_e164": None})).status_code == 200

    for field in ("display_name", "timezone", "locale"):
        response = await _patch(h, tokens, {field: None})
        assert response.status_code == 422, field
        error = problem(response)["errors"][0]
        assert (error["field"], error["code"]) == (field, "null_not_allowed")


@pytest.mark.parametrize(
    ("field", "value", "code"),
    [
        ("display_name", "", "too_short"),
        ("display_name", "   ", "too_short"),
        ("display_name", "x" * 81, "too_long"),
        ("display_name", "visit www.example.com", "display_name_link"),
        ("display_name", "me@example.com", "display_name_link"),
        ("display_name", "AfterMe Support", "display_name_reserved"),
        ("display_name", "bad\x00name", "invalid_characters"),
        ("display_name", 12, "invalid_display_name"),
        ("phone_e164", "9876543210", "invalid_phone"),
        ("phone_e164", "+0123456789", "invalid_phone"),
        ("phone_e164", "+12345", "invalid_phone"),
        ("phone_e164", "+1234567890123456", "invalid_phone"),
        ("phone_e164", "+91 98765 43210", "invalid_phone"),
        ("phone_e164", "", "invalid_phone"),
        ("country_code", "ZZ", "invalid_country_code"),
        ("country_code", "IND", "invalid_country_code"),
        ("country_code", "", "invalid_country_code"),
        ("timezone", "Mars/Olympus", "invalid_timezone"),
        ("timezone", "", "invalid_timezone"),
        ("timezone", "../../etc/passwd", "invalid_timezone"),
        ("locale", "english", "invalid_locale"),
        ("locale", "e", "invalid_locale"),
        ("locale", "", "invalid_locale"),
    ],
)
async def test_patch_validation_rules(h: Harness, field: str, value: Any, code: str) -> None:
    tokens = await h.signup("rules@example.com")
    before = await _me(h, tokens)
    response = await _patch(h, tokens, {field: value})
    assert response.status_code == 422
    body = problem(response)
    assert body["code"] == "validation_failed"
    assert [(e["field"], e["code"]) for e in body["errors"]] == [(field, code)]
    assert await _me(h, tokens) == before  # nothing was applied


async def test_patch_reports_every_invalid_field_and_applies_none(h: Harness) -> None:
    tokens = await h.signup("multi@example.com")
    before = await _me(h, tokens)
    response = await _patch(
        h, tokens, {"display_name": "Fine Name", "timezone": "Nope/Nope", "locale": "??"}
    )
    assert response.status_code == 422
    assert {e["field"] for e in problem(response)["errors"]} == {"timezone", "locale"}
    assert await _me(h, tokens) == before


@pytest.mark.parametrize(
    "body",
    [
        {"email": "x@example.com"},
        {"tier": "premium"},
        {"id": "x"},
        {"display_name": "Ok", "status": "active"},
    ],
)
async def test_patch_rejects_unknown_fields(h: Harness, body: dict[str, Any]) -> None:
    tokens = await h.signup("extra@example.com")
    before = await _me(h, tokens)
    response = await _patch(h, tokens, body)
    assert response.status_code == 422
    assert any(e["code"] == "unknown_field" for e in problem(response)["errors"])
    assert await _me(h, tokens) == before


@pytest.mark.parametrize("body", [{}, [], "text", None, 5])
async def test_patch_needs_at_least_one_field(h: Harness, body: Any) -> None:
    tokens = await h.signup("empty@example.com")
    response = await _patch(h, tokens, body)
    assert response.status_code == 422
    assert problem(response)["code"] == "validation_failed"
    if body == {}:
        assert problem(response)["errors"][0]["code"] == "empty_update"


async def test_patch_requires_authentication(h: Harness) -> None:
    response = await h.client.patch("/v1/me/profile", json={"display_name": "x"})
    assert response.status_code == 401
    assert problem(response)["code"] == "unauthenticated"


async def test_patch_only_touches_the_callers_profile(h: Harness) -> None:
    alice = await h.signup("alice-p@example.com")
    bob = await h.signup("bob-p@example.com")
    await _patch(h, alice, {"display_name": "Alice Changed"})
    assert (await _me(h, bob))["profile"]["display_name"] == "Test User"


async def test_patch_audit_trail(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("audit-p@example.com")
    owner_db.execute("DELETE FROM audit_logs")

    await _patch(h, tokens, {"display_name": "Renamed Person", "phone_e164": "+14155552671"})
    await _patch(h, tokens, {"display_name": "Renamed Person"})  # no real change: not audited
    await _patch(h, tokens, {"timezone": "Asia/Kolkata"})  # same timezone as signup: not a change
    h.clock.advance(minutes=1)
    await _patch(h, tokens, {"timezone": "America/New_York", "locale": "fr"})

    rows = owner_db.execute(
        "SELECT action, user_visible, metadata, actor_type FROM audit_logs ORDER BY id"
    ).fetchall()
    assert [(r["action"], r["user_visible"]) for r in rows] == [
        ("profile.updated", False),
        ("profile.updated", False),
        ("profile.timezone_changed", True),
    ]
    assert rows[0]["metadata"] == {"fields": "display_name.phone_e164"}
    assert rows[1]["metadata"] == {"fields": "locale.timezone"}
    assert rows[2]["metadata"] == {}
    assert {r["actor_type"] for r in rows} == {"user"}
    text = str(rows)
    for secret in ("Renamed Person", "+14155552671", "New_York", "Kolkata"):
        assert secret not in text


async def test_patch_updates_updated_at(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("stamp@example.com")
    h.clock.advance(hours=2)
    refreshed = (await h.refresh(tokens["refresh_token"])).json()
    assert (await _patch(h, refreshed, {"locale": "hi"})).status_code == 200
    row = owner_db.execute("SELECT updated_at FROM user_profiles").fetchone()
    assert row is not None
    assert row["updated_at"] == h.clock.current
