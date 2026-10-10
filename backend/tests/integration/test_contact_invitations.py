"""Invitation lifecycle, resends, email changes and the suppression list (CON-*)."""

from __future__ import annotations

import hashlib
import re
from datetime import timedelta
from typing import Any

import psycopg
import pytest

from app.contacts.tokens import CONSENT_TEXT_VERSION, suppression_hash
from app.security.hashing import Pepper
from app.security.rate_limit import INVITATION_RESEND_PER_CONTACT
from tests.support import TEST_PEPPER, Harness, bearer, make_premium, problem, rows

Conn = psycopg.Connection[dict[str, Any]]
OWNER = "owner@example.com"
MOM = "mom@example.com"
GENDERED = re.compile(r"\b(he|she|his|hers|him|himself|herself)\b|\bher\b", re.IGNORECASE)


async def _owner_and_contact(h: Harness, **extra: Any) -> tuple[dict[str, Any], dict[str, Any]]:
    tokens = await h.signup(OWNER)
    response = await h.add_contact(tokens, MOM, **extra)
    assert response.status_code == 201, response.text
    return tokens, response.json()


def _suppress(owner_db: Conn, address: str, pepper: str = TEST_PEPPER) -> None:
    owner_db.execute(
        "INSERT INTO email_suppressions (email_hash, reason) VALUES (%s, 'contact_block_all')",
        (suppression_hash(Pepper(pepper), address),),
    )


# --- the invitation ----------------------------------------------------------------------------


async def test_creating_a_contact_sends_one_invitation(h: Harness, owner_db: Conn) -> None:
    _, contact = await _owner_and_contact(h)
    sent = h.mail.to(MOM, "contact_invitation")
    assert len(sent) == 1
    message = sent[0]
    token = h.invitation_token_for(MOM)
    optout = h.optout_token_for(MOM)
    assert f"https://afterme.test/c/open#{token}" in message.text
    assert f"https://afterme.test/c/optout#{optout}" in message.text
    assert message.subject == "Test User added you as a trusted contact on AfterMe"
    assert "Test User" in message.text
    assert OWNER in message.text  # who invited you
    assert "Hi Mom," in message.text

    invitation = rows(owner_db, "SELECT * FROM contact_verifications")[0]
    assert str(invitation["contact_id"]) == contact["id"]
    assert bytes(invitation["token_hash"]) == hashlib.sha256(token.encode()).digest()
    assert token.encode() not in bytes(invitation["token_hash"])
    assert invitation["expires_at"] == h.clock.current + timedelta(days=14)
    assert invitation["sent_at"] == h.clock.current
    assert invitation["responded_at"] is None
    assert invitation["response"] is None
    assert invitation["channel"] == "email"
    assert invitation["consent_text_version"] == CONSENT_TEXT_VERSION == "2026-10-v1"
    assert token not in str(rows(owner_db, "SELECT * FROM trusted_contacts"))


async def test_the_invitation_is_calm_neutral_and_not_an_emergency_service(h: Harness) -> None:
    await _owner_and_contact(h)
    text = h.mail.to(MOM, "contact_invitation")[0].text
    assert "AfterMe is not an emergency service." in text
    assert "You don't need to install anything" in text
    assert "may email you" in text
    assert "Don't want these emails?" in text
    assert "!" not in text  # calm tone
    assert not GENDERED.search(text)
    assert "they" in text.lower()


async def test_no_invitation_is_sent_when_the_request_fails(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    await h.add_contact(tokens, "one@example.com")
    h.mail.clear()
    assert (await h.add_contact(tokens, "two@example.com")).status_code == 403  # plan limit
    assert (await h.add_contact(tokens, "bad-address")).status_code == 422
    assert h.mail.messages == []


async def test_a_failing_email_provider_does_not_fail_the_request(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    h.mail.fail_next = True
    response = await h.add_contact(tokens, MOM)
    assert response.status_code == 201
    assert response.json()["invitation_send_count"] == 1  # queued; delivery is best effort


# --- resend ------------------------------------------------------------------------------------


async def test_resend_issues_a_new_invitation_and_invalidates_the_old_one(
    h: Harness, owner_db: Conn
) -> None:
    tokens, contact = await _owner_and_contact(h)
    old = h.invitation_token_for(MOM)
    h.clock.advance(hours=1)
    tokens = await h.relogin(OWNER)
    response = await h.client.post(
        f"/v1/contacts/{contact['id']}/invitation", headers=bearer(tokens)
    )
    assert response.status_code == 202
    assert response.json() == {"status": "queued"}
    new = h.invitation_token_for(MOM)
    assert new != old
    assert len(h.mail.to(MOM, "contact_invitation")) == 2

    stale = await h.portal_post("/c/session", old)
    assert stale.status_code == 400
    fresh = await h.portal_post("/c/session", new)
    assert fresh.status_code == 200

    updated = (await h.client.get(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))).json()
    assert updated["invitation_send_count"] == 2
    assert updated["invitation_sent_at"] == "2026-10-08T10:00:00Z"
    live = rows(
        owner_db, "SELECT 1 FROM contact_verifications WHERE expires_at > %s", h.clock.current
    )
    assert len(live) == 1


async def test_resend_is_limited_to_three_per_week_per_contact(h: Harness) -> None:
    tokens, contact = await _owner_and_contact(h)
    url = f"/v1/contacts/{contact['id']}/invitation"
    for _ in range(3):
        assert (await h.client.post(url, headers=bearer(tokens))).status_code == 202
    sent = len(h.mail.messages)
    blocked = await h.client.post(url, headers=bearer(tokens))
    assert blocked.status_code == 429
    assert problem(blocked)["code"] == "rate_limited"
    assert int(blocked.headers["retry-after"]) >= 1
    assert len(h.mail.messages) == sent

    _, window_end = INVITATION_RESEND_PER_CONTACT.window_bounds(h.clock.current)
    h.clock.set(window_end)  # the next 7-day window opens
    fresh = (await h.login(OWNER)).json()
    assert (await h.client.post(url, headers=bearer(fresh))).status_code == 202


async def test_resend_shares_the_ten_per_day_invitation_budget(h: Harness, owner_db: Conn) -> None:
    tokens = await h.signup(OWNER)
    make_premium(owner_db, OWNER)
    ids = []
    for n in range(4):
        ids.append((await h.add_contact(tokens, f"c{n}@example.com")).json()["id"])
    for contact_id in ids[:3]:  # 4 creations + 3 resends = 7 invitations
        assert (
            await h.client.post(f"/v1/contacts/{contact_id}/invitation", headers=bearer(tokens))
        ).status_code == 202
    for contact_id in ids[:3]:  # three more resends reach 10
        assert (
            await h.client.post(f"/v1/contacts/{contact_id}/invitation", headers=bearer(tokens))
        ).status_code == 202
    over = await h.client.post(f"/v1/contacts/{ids[3]}/invitation", headers=bearer(tokens))
    assert over.status_code == 429
    assert "retry-after" in over.headers


@pytest.mark.parametrize("status", ["verified", "declined", "opted_out"])
async def test_only_pending_or_bounced_contacts_are_reinvited(
    h: Harness, owner_db: Conn, status: str
) -> None:
    tokens, contact = await _owner_and_contact(h)
    owner_db.execute("UPDATE trusted_contacts SET verification_status = %s", (status,))
    sent = len(h.mail.messages)
    response = await h.client.post(
        f"/v1/contacts/{contact['id']}/invitation", headers=bearer(tokens)
    )
    assert response.status_code == 409
    assert problem(response)["code"] == "invalid_state"
    assert len(h.mail.messages) == sent
    after = rows(owner_db, "SELECT invitation_send_count FROM trusted_contacts")[0]
    assert after["invitation_send_count"] == 1


async def test_a_bounced_contact_can_be_reinvited(h: Harness, owner_db: Conn) -> None:
    tokens, contact = await _owner_and_contact(h)
    owner_db.execute("UPDATE trusted_contacts SET verification_status = 'bounced'")
    response = await h.client.post(
        f"/v1/contacts/{contact['id']}/invitation", headers=bearer(tokens)
    )
    assert response.status_code == 202
    assert len(h.mail.to(MOM, "contact_invitation")) == 2


# --- expiry ------------------------------------------------------------------------------------


async def test_an_invitation_is_valid_for_fourteen_days(h: Harness) -> None:
    await _owner_and_contact(h)
    token = h.invitation_token_for(MOM)
    h.clock.advance(timedelta(days=14) - timedelta(seconds=1))
    assert (await h.portal_post("/c/session", token)).status_code == 200
    h.clock.advance(seconds=1)
    expired = await h.portal_post("/c/session", token)
    assert expired.status_code == 400
    accept = await h.portal_post("/c/invite/accept", token)
    assert accept.status_code == 400


# --- changing the address ----------------------------------------------------------------------


async def test_changing_the_email_resets_verification_and_reinvites(
    h: Harness, owner_db: Conn
) -> None:
    tokens, contact = await _owner_and_contact(h)
    old_token = h.invitation_token_for(MOM)
    accepted = await h.portal_post("/c/invite/accept", old_token)
    assert accepted.status_code == 200
    verified = (await h.client.get(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))).json()
    assert verified["verification_status"] == "verified"
    assert verified["verified_at"] is not None

    h.clock.advance(hours=2)
    tokens = await h.relogin(OWNER)
    response = await h.client.patch(
        f"/v1/contacts/{contact['id']}",
        json={"email": "  New.Mom@Example.com "},
        headers=bearer(tokens),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["email"] == "new.mom@example.com"
    assert body["verification_status"] == "pending"
    assert body["verified_at"] is None
    assert body["invitation_send_count"] == 1
    assert body["invitation_sent_at"] == "2026-10-08T11:00:00Z"
    assert len(h.mail.to("new.mom@example.com", "contact_invitation")) == 1
    assert len(h.mail.to(MOM, "contact_invitation")) == 1  # nothing more to the old address
    row = rows(owner_db, "SELECT email_normalized FROM trusted_contacts")[0]
    assert row["email_normalized"] == "new.mom@example.com"


async def test_an_answered_invitation_does_not_carry_over_to_a_new_address(
    h: Harness, owner_db: Conn
) -> None:
    tokens, contact = await _owner_and_contact(h)
    old_token = h.invitation_token_for(MOM)
    declined = await h.portal_post("/c/invite/decline", old_token)
    assert declined.status_code == 200
    changed = await h.client.patch(
        f"/v1/contacts/{contact['id']}", json={"email": "other@example.com"}, headers=bearer(tokens)
    )
    assert changed.json()["verification_status"] == "pending"
    assert len(h.mail.to("other@example.com", "contact_invitation")) == 1
    new_token = h.invitation_token_for("other@example.com")
    assert (await h.portal_post("/c/invite/accept", new_token)).status_code == 200
    final = (await h.client.get(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))).json()
    assert final["verification_status"] == "verified"


async def test_an_email_change_invalidates_unanswered_invitations(h: Harness) -> None:
    tokens, contact = await _owner_and_contact(h)
    old_token = h.invitation_token_for(MOM)
    await h.client.patch(
        f"/v1/contacts/{contact['id']}", json={"email": "other@example.com"}, headers=bearer(tokens)
    )
    assert (await h.portal_post("/c/session", old_token)).status_code == 400
    assert (
        await h.portal_post("/c/session", h.invitation_token_for("other@example.com"))
    ).status_code == 200


async def test_email_change_obeys_the_address_rules(h: Harness, owner_db: Conn) -> None:
    tokens = await h.signup(OWNER)
    make_premium(owner_db, OWNER)
    first = (await h.add_contact(tokens, "first@example.com")).json()
    second = (await h.add_contact(tokens, "second@example.com", name="Second")).json()
    duplicate = await h.client.patch(
        f"/v1/contacts/{second['id']}", json={"email": "FIRST@example.com"}, headers=bearer(tokens)
    )
    assert duplicate.status_code == 409
    assert problem(duplicate)["code"] == "contact_duplicate"
    own = await h.client.patch(
        f"/v1/contacts/{second['id']}", json={"email": OWNER.upper()}, headers=bearer(tokens)
    )
    assert own.status_code == 422
    assert problem(own)["code"] == "cannot_be_own_email"
    unchanged = (await h.client.get(f"/v1/contacts/{second['id']}", headers=bearer(tokens))).json()
    assert unchanged == second
    assert first["id"] != second["id"]


async def test_email_change_counts_towards_the_invitation_budget(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await h.signup(OWNER)
    make_premium(owner_db, OWNER)
    contact = (await h.add_contact(tokens, "start@example.com")).json()
    for n in range(9):  # 1 creation + 9 changes = 10 invitations
        response = await h.client.patch(
            f"/v1/contacts/{contact['id']}",
            json={"email": f"change{n}@example.com"},
            headers=bearer(tokens),
        )
        assert response.status_code == 200
    blocked = await h.client.patch(
        f"/v1/contacts/{contact['id']}", json={"email": "late@example.com"}, headers=bearer(tokens)
    )
    assert blocked.status_code == 429
    current = (await h.client.get(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))).json()
    assert current["email"] == "change8@example.com"  # nothing changed on the refused request
    assert h.mail.to("late@example.com") == []


# --- suppression -------------------------------------------------------------------------------


async def test_a_suppressed_address_gets_no_email_and_the_response_reveals_nothing(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await h.signup(OWNER)
    make_premium(owner_db, OWNER)
    _suppress(owner_db, "blocked@example.com")
    normal = await h.add_contact(tokens, "normal@example.com", name="Same")
    h.mail.clear()
    blocked = await h.add_contact(tokens, "  BLOCKED@example.com ", name="Same")

    assert blocked.status_code == normal.status_code == 201
    assert h.mail.messages == []
    body = blocked.json()
    assert set(body) == set(normal.json())
    assert body["verification_status"] == "pending"
    assert body["invitation_send_count"] == 0
    assert body["invitation_sent_at"] is None
    assert "suppress" not in blocked.text.lower()
    assert "block" not in blocked.text.lower().replace("blocked@example.com", "")
    # The same budgets were spent, so the limit does not tell the two apart either.
    for header in ("ratelimit-limit", "ratelimit-remaining"):
        assert header in blocked.headers
    assert (
        rows(owner_db, "SELECT 1 FROM contact_verifications WHERE contact_id = %s", body["id"])
        == []
    )
    kinds = [r["action"] for r in rows(owner_db, "SELECT action FROM audit_logs ORDER BY id")]
    assert kinds.count("contact.created") == 2
    assert kinds.count("contact.invitation_sent") == 1  # only the normal contact


async def test_a_suppressed_address_counts_like_any_other_towards_limits(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await h.signup(OWNER)
    make_premium(owner_db, OWNER)
    for n in range(10):
        _suppress(owner_db, f"blocked{n}@example.com")
        assert (await h.add_contact(tokens, f"blocked{n}@example.com")).status_code == 201
    over = await h.add_contact(tokens, "blocked-too-many@example.com")
    assert over.status_code == 429


async def test_suppressed_contacts_still_count_towards_the_tier_limit(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await h.signup(OWNER)
    _suppress(owner_db, "blocked@example.com")
    assert (await h.add_contact(tokens, "blocked@example.com")).status_code == 201
    over = await h.add_contact(tokens, "other@example.com")
    assert over.status_code == 403
    assert problem(over)["current"] == 1


async def test_resend_to_a_suppressed_address_answers_the_same_and_sends_nothing(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await h.signup(OWNER)
    _suppress(owner_db, "blocked@example.com")
    contact = (await h.add_contact(tokens, "blocked@example.com")).json()
    h.mail.clear()
    response = await h.client.post(
        f"/v1/contacts/{contact['id']}/invitation", headers=bearer(tokens)
    )
    assert response.status_code == 202
    assert response.json() == {"status": "queued"}
    assert h.mail.messages == []
    after = (await h.client.get(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))).json()
    assert after["invitation_send_count"] == 0
    assert rows(owner_db, "SELECT 1 FROM contact_verifications") == []


async def test_changing_to_a_suppressed_address_sends_nothing(h: Harness, owner_db: Conn) -> None:
    tokens, contact = await _owner_and_contact(h)
    _suppress(owner_db, "blocked@example.com")
    h.mail.clear()
    response = await h.client.patch(
        f"/v1/contacts/{contact['id']}",
        json={"email": "blocked@example.com"},
        headers=bearer(tokens),
    )
    assert response.status_code == 200
    assert response.json()["verification_status"] == "pending"
    assert response.json()["invitation_send_count"] == 0
    assert h.mail.messages == []


@pytest.mark.settings(
    hmac_pepper="a-brand-new-pepper-value-of-at-least-32-bytes!!", hmac_pepper_previous=TEST_PEPPER
)
async def test_suppression_survives_pepper_rotation(h: Harness, owner_db: Conn) -> None:
    _suppress(owner_db, "blocked@example.com", pepper=TEST_PEPPER)  # written before the rotation
    tokens = await h.signup(OWNER)
    response = await h.add_contact(tokens, "blocked@example.com")
    assert response.status_code == 201
    assert response.json()["invitation_send_count"] == 0
    assert h.mail.to("blocked@example.com") == []
