"""Trusted contacts: CRUD, validation, tier limits, duplicates, isolation (TEST_PLAN CON-01..20)."""

from __future__ import annotations

import asyncio
import uuid
from datetime import timedelta
from typing import Any

import psycopg
import pytest

from app.security.rate_limit import (
    CONTACT_CREATE_PER_USER,
    INVITATION_PER_USER,
)
from tests.support import Harness, bearer, make_premium, problem, rows, seed_contacts

Conn = psycopg.Connection[dict[str, Any]]
OWNER = "owner@example.com"

CONTACT_KEYS = {
    "id",
    "display_name",
    "relationship",
    "relationship_label",
    "email",
    "phone_e164",
    "priority",
    "verification_status",
    "verified_at",
    "is_active",
    "invitation_sent_at",
    "invitation_send_count",
    "notified_at_stages",
    "receives_instructions",
    "created_at",
    "updated_at",
}


async def _premium_owner(h: Harness, owner_db: Conn, email: str = OWNER) -> dict[str, Any]:
    tokens = await h.signup(email)
    make_premium(owner_db, email)
    return tokens


def _user_id(tokens: dict[str, Any]) -> str:
    return str(tokens["user"]["id"])


# --- create and read ---------------------------------------------------------------------------


async def test_create_returns_the_contact_object(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    response = await h.add_contact(
        tokens, "  Mom@Example.COM ", name="Mom", phone_e164="+919876543210"
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert set(body) == CONTACT_KEYS
    assert body["email"] == "mom@example.com"  # trimmed and lower-cased
    assert body["display_name"] == "Mom"
    assert body["relationship"] == "mother"
    assert body["relationship_label"] is None
    assert body["phone_e164"] == "+919876543210"
    assert body["priority"] == 1
    assert body["verification_status"] == "pending"
    assert body["verified_at"] is None
    assert body["is_active"] is True
    assert body["invitation_sent_at"] == "2026-10-08T09:00:00Z"
    assert body["invitation_send_count"] == 1
    assert body["notified_at_stages"] == []
    assert body["receives_instructions"] == 0
    assert body["created_at"] == body["updated_at"] == "2026-10-08T09:00:00Z"
    uuid.UUID(body["id"])
    assert response.headers["cache-control"] == "no-store"


async def test_get_and_list_return_the_same_object(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    created = (await h.add_contact(tokens, "mom@example.com")).json()
    fetched = await h.client.get(f"/v1/contacts/{created['id']}", headers=bearer(tokens))
    assert fetched.status_code == 200
    assert fetched.json() == created
    listing = await h.client.get("/v1/contacts", headers=bearer(tokens))
    assert listing.status_code == 200
    assert listing.json() == {"items": [created]}


async def test_empty_list(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    response = await h.client.get("/v1/contacts", headers=bearer(tokens))
    assert response.status_code == 200
    assert response.json() == {"items": []}


async def test_list_is_ordered_by_priority_then_creation_and_capped(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await _premium_owner(h, owner_db)
    first = (await h.add_contact(tokens, "c1@example.com", name="C1", priority=5)).json()
    h.clock.advance(seconds=10)
    second = (await h.add_contact(tokens, "c2@example.com", name="C2", priority=2)).json()
    h.clock.advance(seconds=10)
    third = (await h.add_contact(tokens, "c3@example.com", name="C3", priority=5)).json()
    h.clock.advance(seconds=10)
    fourth = (await h.add_contact(tokens, "c4@example.com", name="C4", priority=1)).json()
    listing = (await h.client.get("/v1/contacts", headers=bearer(tokens))).json()["items"]
    assert [c["id"] for c in listing] == [fourth["id"], second["id"], first["id"], third["id"]]

    seed_contacts(owner_db, _user_id(tokens), 21)  # 25 in total: the premium maximum
    full = (await h.client.get("/v1/contacts", headers=bearer(tokens))).json()["items"]
    assert len(full) == 25


async def test_default_priority_is_last_plus_one_and_stays_in_range(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await _premium_owner(h, owner_db)
    one = (await h.add_contact(tokens, "p1@example.com")).json()
    two = (await h.add_contact(tokens, "p2@example.com")).json()
    high = (await h.add_contact(tokens, "p3@example.com", priority=999)).json()
    after_high = (await h.add_contact(tokens, "p4@example.com")).json()
    assert [one["priority"], two["priority"], high["priority"], after_high["priority"]] == [
        1,
        2,
        999,
        999,
    ]


async def test_relationship_label_only_with_other(h: Harness, owner_db: Conn) -> None:
    tokens = await _premium_owner(h, owner_db)
    ok = await h.add_contact(
        tokens, "g@example.com", relationship="other", relationship_label="Godmother"
    )
    assert ok.status_code == 201
    assert ok.json()["relationship_label"] == "Godmother"
    bare = await h.add_contact(tokens, "o@example.com", relationship="other")
    assert bare.json()["relationship_label"] is None
    rejected = await h.add_contact(
        tokens, "f@example.com", relationship="friend", relationship_label="Godmother"
    )
    assert rejected.status_code == 422
    errors = problem(rejected)["errors"]
    assert errors == [
        {
            "field": "relationship_label",
            "code": "label_not_allowed",
            "message": "A description is only allowed when the relationship is Other.",
        }
    ]


# --- validation --------------------------------------------------------------------------------


def _field_codes(response: Any) -> dict[str, str]:
    assert response.status_code == 422, response.text
    body = problem(response)
    assert body["code"] == "validation_failed"
    return {e["field"]: e["code"] for e in body["errors"]}


@pytest.mark.parametrize(
    ("name", "code"),
    [
        ("", "too_short"),
        ("   ", "too_short"),
        ("x" * 81, "too_long"),
        ("see https://evil.example/now", "display_name_link"),
        ("evil.example", "display_name_link"),
        ("mail me@evil", "display_name_link"),
        ("AfterMe Support", "display_name_reserved"),
        ("AftеrMe", "display_name_reserved"),  # Cyrillic look-alike
        ("bad\x00name", "invalid_characters"),
        ("bad" + chr(0x202E) + "name", "invalid_characters"),
    ],
)
async def test_display_name_rules(h: Harness, name: str, code: str) -> None:
    tokens = await h.signup(OWNER)
    response = await h.add_contact(tokens, "mom@example.com", name=name)
    assert _field_codes(response) == {"display_name": code}
    assert (await h.client.get("/v1/contacts", headers=bearer(tokens))).json() == {"items": []}


async def test_display_name_is_nfc_normalised_and_trimmed(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    response = await h.add_contact(tokens, "mom@example.com", name="  Café Mum  ")
    assert response.status_code == 201
    assert response.json()["display_name"] == "Café Mum"


@pytest.mark.parametrize(
    ("field", "value", "code"),
    [
        ("relationship", "boss", "invalid_choice"),
        ("relationship", None, "invalid_choice"),
        ("email", "not-an-email", "invalid_email"),
        ("email", "a@b", "invalid_email"),
        ("email", "x" * 250 + "@example.com", "invalid_email"),
        ("email", 5, "invalid_email"),
        ("phone_e164", "12345", "invalid_phone"),
        ("phone_e164", "+0123456789", "invalid_phone"),
        ("priority", 0, "too_small"),
        ("priority", 1000, "too_large"),
        ("priority", "1", "invalid_type"),
        ("priority", True, "invalid_type"),
        ("priority", 1.5, "invalid_type"),
        ("relationship_label", "x" * 41, "too_long"),
    ],
)
async def test_field_validation(h: Harness, field: str, value: Any, code: str) -> None:
    tokens = await h.signup(OWNER)
    body: dict[str, Any] = {
        "display_name": "Mom",
        "relationship": "other",
        "email": "mom@example.com",
        field: value,
    }
    response = await h.client.post("/v1/contacts", json=body, headers=bearer(tokens))
    assert _field_codes(response) == {field: code}


async def test_label_rules_follow_display_name_rules(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    for label, code in [("", "too_short"), ("see www.evil.com", "contains_link")]:
        response = await h.add_contact(
            tokens, "mom@example.com", relationship="other", relationship_label=label
        )
        assert _field_codes(response) == {"relationship_label": code}


@pytest.mark.parametrize(
    "extra", ["user_id", "verification_status", "tier", "deleted_at", "status"]
)
async def test_unknown_fields_are_rejected(h: Harness, extra: str) -> None:
    tokens = await h.signup(OWNER)
    response = await h.client.post(
        "/v1/contacts",
        json={
            "display_name": "Mom",
            "relationship": "mother",
            "email": "mom@example.com",
            extra: "x",
        },
        headers=bearer(tokens),
    )
    assert _field_codes(response) == {extra: "unknown_field"}


async def test_missing_required_fields(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    response = await h.client.post("/v1/contacts", json={}, headers=bearer(tokens))
    assert _field_codes(response) == {
        "display_name": "required",
        "relationship": "required",
        "email": "required",
    }


@pytest.mark.parametrize("variant", ["owner@example.com", "  OWNER@Example.COM  "])
async def test_own_email_is_rejected(h: Harness, owner_db: Conn, variant: str) -> None:
    tokens = await h.signup(OWNER)
    response = await h.add_contact(tokens, variant)
    assert response.status_code == 422
    body = problem(response)
    assert body["code"] == "cannot_be_own_email"
    assert body["errors"][0]["field"] == "email"
    assert body["errors"][0]["code"] == "cannot_be_own_email"
    assert rows(owner_db, "SELECT 1 FROM trusted_contacts") == []
    assert h.mail.to(OWNER, "contact_invitation") == []


# --- duplicates --------------------------------------------------------------------------------


async def test_duplicates_are_detected_case_and_whitespace_insensitively(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await _premium_owner(h, owner_db)
    assert (await h.add_contact(tokens, "mom@example.com")).status_code == 201
    for variant in ("MOM@example.com", "  mom@example.com  ", "Mom@Example.Com"):
        response = await h.add_contact(tokens, variant, name="Other")
        assert response.status_code == 409, variant
        assert problem(response)["code"] == "contact_duplicate"
    assert len(rows(owner_db, "SELECT 1 FROM trusted_contacts")) == 1
    assert len(h.mail.to("mom@example.com", "contact_invitation")) == 1


async def test_two_users_may_list_the_same_address(h: Harness) -> None:
    alice = await h.signup("alice@example.com")
    bob = await h.signup("bob@example.com")
    assert (await h.add_contact(alice, "shared@example.com")).status_code == 201
    assert (await h.add_contact(bob, "shared@example.com")).status_code == 201


async def test_a_deleted_contacts_address_can_be_added_again(h: Harness, owner_db: Conn) -> None:
    tokens = await h.signup(OWNER)  # free: one contact only, deleted ones must not count
    first = (await h.add_contact(tokens, "mom@example.com")).json()
    deleted = await h.client.delete(f"/v1/contacts/{first['id']}", headers=bearer(tokens))
    assert deleted.status_code == 204
    again = await h.add_contact(tokens, "MOM@example.com")
    assert again.status_code == 201
    assert again.json()["id"] != first["id"]
    assert len(rows(owner_db, "SELECT 1 FROM trusted_contacts WHERE deleted_at IS NULL")) == 1


async def test_simultaneous_creates_of_one_address_make_exactly_one(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await _premium_owner(h, owner_db)
    results = await asyncio.gather(
        *(h.add_contact(tokens, "same@example.com", name=f"Same {n}") for n in range(3))
    )
    assert sorted(r.status_code for r in results) == [201, 409, 409]
    assert len(rows(owner_db, "SELECT 1 FROM trusted_contacts")) == 1
    assert len(h.mail.to("same@example.com", "contact_invitation")) == 1


# --- tier limits -------------------------------------------------------------------------------


async def test_free_tier_allows_one_contact(h: Harness, owner_db: Conn) -> None:
    tokens = await h.signup(OWNER)
    assert (await h.add_contact(tokens, "one@example.com")).status_code == 201
    response = await h.add_contact(tokens, "two@example.com")
    assert response.status_code == 403
    body = problem(response)
    assert body["code"] == "plan_limit_reached"
    assert (body["limit"], body["current"], body["resource"]) == (1, 1, "contacts")
    assert len(rows(owner_db, "SELECT 1 FROM trusted_contacts")) == 1
    assert h.mail.to("two@example.com") == []


async def test_premium_tier_boundary_is_25(h: Harness, owner_db: Conn) -> None:
    tokens = await _premium_owner(h, owner_db)
    seed_contacts(owner_db, _user_id(tokens), 24)
    last = await h.add_contact(tokens, "number25@example.com")
    assert last.status_code == 201
    over = await h.add_contact(tokens, "number26@example.com")
    assert over.status_code == 403
    body = problem(over)
    assert (body["limit"], body["current"], body["resource"]) == (25, 25, "contacts")
    assert len(rows(owner_db, "SELECT 1 FROM trusted_contacts")) == 25


async def test_deleted_contacts_do_not_count_towards_the_limit(h: Harness, owner_db: Conn) -> None:
    tokens = await _premium_owner(h, owner_db)
    seed_contacts(owner_db, _user_id(tokens), 25)
    assert (await h.add_contact(tokens, "over@example.com")).status_code == 403
    first_id = rows(owner_db, "SELECT id FROM trusted_contacts ORDER BY priority LIMIT 1")[0]["id"]
    assert (
        await h.client.delete(f"/v1/contacts/{first_id}", headers=bearer(tokens))
    ).status_code == 204
    assert (await h.add_contact(tokens, "fits@example.com")).status_code == 201


async def test_a_downgraded_account_keeps_its_contacts_but_cannot_add(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await _premium_owner(h, owner_db)
    seed_contacts(owner_db, _user_id(tokens), 3)
    owner_db.execute("UPDATE users SET tier = 'free' WHERE email_normalized = %s", (OWNER,))
    listing = (await h.client.get("/v1/contacts", headers=bearer(tokens))).json()["items"]
    assert len(listing) == 3
    response = await h.add_contact(tokens, "more@example.com")
    assert response.status_code == 403
    assert (problem(response)["limit"], problem(response)["current"]) == (1, 3)


async def test_simultaneous_creates_cannot_exceed_the_free_limit(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await h.signup(OWNER)
    results = await asyncio.gather(
        h.add_contact(tokens, "first@example.com", name="First"),
        h.add_contact(tokens, "second@example.com", name="Second"),
    )
    assert sorted(r.status_code for r in results) == [201, 403]
    loser = next(r for r in results if r.status_code == 403)
    assert problem(loser)["code"] == "plan_limit_reached"
    assert len(rows(owner_db, "SELECT 1 FROM trusted_contacts WHERE deleted_at IS NULL")) == 1


async def test_simultaneous_creates_cannot_exceed_the_premium_limit(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await _premium_owner(h, owner_db)
    seed_contacts(owner_db, _user_id(tokens), 23)
    results = await asyncio.gather(
        *(h.add_contact(tokens, f"race{n}@example.com", name=f"Race {n}") for n in range(4))
    )
    assert sorted(r.status_code for r in results) == [201, 201, 403, 403]
    assert len(rows(owner_db, "SELECT 1 FROM trusted_contacts WHERE deleted_at IS NULL")) == 25


# --- rate limits -------------------------------------------------------------------------------


async def test_the_invitation_budget_is_ten_per_day(h: Harness, owner_db: Conn) -> None:
    tokens = await _premium_owner(h, owner_db)
    for n in range(10):
        assert (await h.add_contact(tokens, f"day{n}@example.com")).status_code == 201
    blocked = await h.add_contact(tokens, "day10@example.com")
    assert blocked.status_code == 429
    assert problem(blocked)["code"] == "rate_limited"
    assert int(blocked.headers["retry-after"]) >= 1
    assert len(rows(owner_db, "SELECT 1 FROM trusted_contacts")) == 10  # nothing created
    assert h.mail.to("day10@example.com") == []

    h.clock.advance(timedelta(days=1))  # the next window
    fresh = (await h.login(OWNER)).json()
    assert (await h.add_contact(fresh, "day10@example.com")).status_code == 201


async def test_the_creation_budget_is_twenty_per_day(h: Harness, owner_db: Conn) -> None:
    tokens = await _premium_owner(h, owner_db)
    limiter = h.app.state.services.limiter
    now = h.clock.current
    for _ in range(20):  # twenty creations already counted today
        await limiter.hit([(CONTACT_CREATE_PER_USER, _user_id(tokens))], now=now)
    blocked = await h.add_contact(tokens, "late@example.com")
    assert blocked.status_code == 429
    assert problem(blocked)["code"] == "rate_limited"
    assert rows(owner_db, "SELECT 1 FROM trusted_contacts") == []


async def test_rejected_requests_do_not_use_up_the_budgets(h: Harness, owner_db: Conn) -> None:
    tokens = await _premium_owner(h, owner_db)
    for _ in range(12):  # duplicates and own-email attempts are validation failures
        await h.add_contact(tokens, OWNER)
    assert (await h.add_contact(tokens, "ok@example.com")).status_code == 201
    for _ in range(12):
        assert (await h.add_contact(tokens, "ok@example.com")).status_code == 409
    limiter = h.app.state.services.limiter
    counted = await limiter.hit([(INVITATION_PER_USER, _user_id(tokens))], now=h.clock.current)
    assert counted[0].count == 2  # one real invitation plus this probe


# --- update ------------------------------------------------------------------------------------


async def test_patch_changes_only_the_given_fields(h: Harness, owner_db: Conn) -> None:
    tokens = await h.signup(OWNER)
    created = (await h.add_contact(tokens, "mom@example.com", phone_e164="+919876543210")).json()
    h.clock.advance(minutes=1)
    response = await h.client.patch(
        f"/v1/contacts/{created['id']}",
        json={"display_name": "Mum", "priority": 7, "is_active": False, "relationship": "parent"},
        headers=bearer(tokens),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["display_name"] == "Mum"
    assert body["priority"] == 7
    assert body["is_active"] is False
    assert body["relationship"] == "parent"
    assert body["email"] == "mom@example.com"
    assert body["phone_e164"] == "+919876543210"
    assert body["verification_status"] == "pending"
    assert body["updated_at"] == "2026-10-08T09:01:00Z"
    assert body["created_at"] == created["created_at"]
    assert len(h.mail.to("mom@example.com", "contact_invitation")) == 1  # no new invitation


async def test_patch_null_clears_the_phone_and_the_label_only(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    created = (
        await h.add_contact(
            tokens,
            "mom@example.com",
            relationship="other",
            relationship_label="Godmother",
            phone_e164="+919876543210",
        )
    ).json()
    cleared = await h.client.patch(
        f"/v1/contacts/{created['id']}",
        json={"phone_e164": None, "relationship_label": None},
        headers=bearer(tokens),
    )
    assert cleared.status_code == 200
    assert cleared.json()["phone_e164"] is None
    assert cleared.json()["relationship_label"] is None
    for field in ("display_name", "relationship", "email", "priority", "is_active"):
        response = await h.client.patch(
            f"/v1/contacts/{created['id']}", json={field: None}, headers=bearer(tokens)
        )
        assert _field_codes(response) == {field: "null_not_allowed"}


async def test_patch_rejects_empty_and_unknown_bodies(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    created = (await h.add_contact(tokens, "mom@example.com")).json()
    url = f"/v1/contacts/{created['id']}"
    empty = await h.client.patch(url, json={}, headers=bearer(tokens))
    assert _field_codes(empty) == {"body": "empty_update"}
    for field in ("user_id", "verification_status", "verified_at", "deleted_at", "id"):
        response = await h.client.patch(url, json={field: "x"}, headers=bearer(tokens))
        assert _field_codes(response) == {field: "unknown_field"}


async def test_patch_validates_like_create(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    created = (await h.add_contact(tokens, "mom@example.com")).json()
    response = await h.client.patch(
        f"/v1/contacts/{created['id']}",
        json={"display_name": "AfterMe", "phone_e164": "123", "priority": 0, "email": "bad"},
        headers=bearer(tokens),
    )
    assert _field_codes(response) == {
        "display_name": "display_name_reserved",
        "phone_e164": "invalid_phone",
        "priority": "too_small",
        "email": "invalid_email",
    }


async def test_label_follows_the_relationship_on_patch(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    created = (
        await h.add_contact(
            tokens, "g@example.com", relationship="other", relationship_label="Godmother"
        )
    ).json()
    url = f"/v1/contacts/{created['id']}"
    refused = await h.client.patch(
        url, json={"relationship": "friend", "relationship_label": "Pal"}, headers=bearer(tokens)
    )
    assert _field_codes(refused) == {"relationship_label": "label_not_allowed"}
    moved = await h.client.patch(url, json={"relationship": "friend"}, headers=bearer(tokens))
    assert moved.status_code == 200
    assert moved.json()["relationship"] == "friend"
    assert moved.json()["relationship_label"] is None  # a description belongs to Other only
    late = await h.client.patch(url, json={"relationship_label": "Pal"}, headers=bearer(tokens))
    assert _field_codes(late) == {"relationship_label": "label_not_allowed"}


async def test_a_patch_that_changes_nothing_writes_nothing(h: Harness, owner_db: Conn) -> None:
    tokens = await h.signup(OWNER)
    created = (await h.add_contact(tokens, "mom@example.com", name="Mom")).json()
    before = rows(owner_db, "SELECT * FROM trusted_contacts")
    audits = rows(owner_db, "SELECT id FROM audit_logs WHERE action = 'contact.updated'")
    h.clock.advance(minutes=5)
    response = await h.client.patch(
        f"/v1/contacts/{created['id']}",
        json={"display_name": "Mom", "email": "MOM@example.com", "priority": 1},
        headers=bearer(tokens),
    )
    assert response.status_code == 200
    assert response.json() == created
    assert rows(owner_db, "SELECT * FROM trusted_contacts") == before
    assert rows(owner_db, "SELECT id FROM audit_logs WHERE action = 'contact.updated'") == audits


async def test_patch_of_a_missing_contact_is_404(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    response = await h.client.patch(
        f"/v1/contacts/{uuid.uuid4()}", json={"priority": 3}, headers=bearer(tokens)
    )
    assert response.status_code == 404
    assert problem(response)["code"] == "not_found"


@pytest.mark.parametrize("bad_id", ["not-a-uuid", "123"])
async def test_malformed_ids_are_validation_errors(h: Harness, bad_id: str) -> None:
    tokens = await h.signup(OWNER)
    response = await h.client.get(f"/v1/contacts/{bad_id}", headers=bearer(tokens))
    assert response.status_code == 422
    assert problem(response)["errors"][0]["code"] == "invalid_uuid"


# --- delete ------------------------------------------------------------------------------------


async def test_delete_scrubs_personal_data_and_keeps_ids(h: Harness, owner_db: Conn) -> None:
    tokens = await h.signup(OWNER)
    created = (
        await h.add_contact(
            tokens,
            "mom@example.com",
            name="Mom",
            relationship="other",
            relationship_label="Godmother",
            phone_e164="+919876543210",
        )
    ).json()
    h.clock.advance(minutes=1)
    deleted = await h.client.delete(f"/v1/contacts/{created['id']}", headers=bearer(tokens))
    assert deleted.status_code == 204
    assert deleted.content == b""

    row = rows(owner_db, "SELECT * FROM trusted_contacts")[0]
    assert str(row["id"]) == created["id"]
    assert str(row["user_id"]) == _user_id(tokens)
    assert row["deleted_at"] is not None
    for scrubbed in ("email", "email_normalized", "phone_e164", "relationship_label"):
        assert row[scrubbed] is None, scrubbed
    assert row["display_name"] == "Mom"  # kept for the owner's own history
    # The unanswered invitation no longer works.
    invitation = rows(owner_db, "SELECT expires_at, responded_at FROM contact_verifications")[0]
    assert invitation["expires_at"] <= h.clock.current
    assert invitation["responded_at"] is None

    assert (await h.client.get("/v1/contacts", headers=bearer(tokens))).json() == {"items": []}
    gone = await h.client.get(f"/v1/contacts/{created['id']}", headers=bearer(tokens))
    assert gone.status_code == 404
    again = await h.client.delete(f"/v1/contacts/{created['id']}", headers=bearer(tokens))
    assert again.status_code == 404
    token = h.invitation_token_for("mom@example.com")
    page = await h.portal_post("/c/session", token)
    assert page.status_code == 400  # the old invitation link is dead


# --- isolation ---------------------------------------------------------------------------------


async def test_other_users_cannot_see_or_change_a_contact(h: Harness, owner_db: Conn) -> None:
    alice = await h.signup("alice@example.com")
    bob = await h.signup("bob@example.com")
    created = (await h.add_contact(alice, "alices.mom@example.com")).json()
    url = f"/v1/contacts/{created['id']}"
    before = rows(owner_db, "SELECT * FROM trusted_contacts")
    mails = len(h.mail.messages)

    for method, kwargs in [
        ("GET", {}),
        ("PATCH", {"json": {"display_name": "Hijack", "email": "evil@example.com"}}),
        ("DELETE", {}),
        ("POST", {}),
    ]:
        target = f"{url}/invitation" if method == "POST" else url
        response = await h.client.request(method, target, headers=bearer(bob), **kwargs)
        assert response.status_code == 404, method
        assert problem(response)["code"] == "not_found"
        assert "alices.mom" not in response.text
    assert rows(owner_db, "SELECT * FROM trusted_contacts") == before
    assert len(h.mail.messages) == mails
    assert (await h.client.get("/v1/contacts", headers=bearer(bob))).json() == {"items": []}
    assert (await h.client.get(url, headers=bearer(alice))).json() == created


# --- entitlements ------------------------------------------------------------------------------


async def test_entitlements_follow_the_tier_and_usage(h: Harness, owner_db: Conn) -> None:
    tokens = await h.signup(OWNER)
    free = await h.client.get("/v1/me/entitlements", headers=bearer(tokens))
    assert free.status_code == 200
    assert free.json() == {
        "tier": "free",
        "limits": {"contacts": 1, "instructions": 3, "stages": 2, "custom_offsets": False},
        "usage": {"contacts": 0, "instructions": 0, "stages": 0},
    }
    created = (await h.add_contact(tokens, "mom@example.com")).json()
    used = (await h.client.get("/v1/me/entitlements", headers=bearer(tokens))).json()
    assert used["usage"]["contacts"] == 1

    make_premium(owner_db, OWNER)
    premium = (await h.client.get("/v1/me/entitlements", headers=bearer(tokens))).json()
    assert premium == {
        "tier": "premium",
        "limits": {"contacts": 25, "instructions": 200, "stages": 10, "custom_offsets": True},
        "usage": {"contacts": 1, "instructions": 0, "stages": 0},
    }
    await h.client.delete(f"/v1/contacts/{created['id']}", headers=bearer(tokens))
    after = (await h.client.get("/v1/me/entitlements", headers=bearer(tokens))).json()
    assert after["usage"]["contacts"] == 0  # deleted contacts do not count


async def test_entitlements_are_per_user(h: Harness) -> None:
    alice = await h.signup("alice@example.com")
    bob = await h.signup("bob@example.com")
    await h.add_contact(alice, "mom@example.com")
    usage = (await h.client.get("/v1/me/entitlements", headers=bearer(bob))).json()["usage"]
    assert usage["contacts"] == 0
