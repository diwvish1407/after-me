"""Races the application checks cannot see on their own: the database is the final arbiter, and a
lost race ends in the same answer as the sequential case."""

from __future__ import annotations

import asyncio
from typing import Any

import psycopg
import pytest

from app.contacts.repository import ContactRepository, PortalRepository, SuppressionRepository
from app.users.entitlements import TierLimits
from tests.support import Harness, bearer, problem, rows

OWNER = "owner@example.com"


async def _never_in_use(*args: object, **kwargs: object) -> bool:
    return False


@pytest.fixture
def roomy_free_tier(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("app.users.entitlements.TIER_LIMITS", {"free": TierLimits(5, 3, 2, False)})


@pytest.mark.usefixtures("roomy_free_tier")
async def test_a_duplicate_that_slips_past_the_check_is_stopped_by_the_database(
    h: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    tokens = await h.signup(OWNER)
    assert (await h.add_contact(tokens, "mom@example.com")).status_code == 201
    monkeypatch.setattr(ContactRepository, "email_in_use", _never_in_use)
    response = await h.add_contact(tokens, "MOM@example.com", name="Again")
    assert response.status_code == 409
    assert problem(response)["code"] == "contact_duplicate"


@pytest.mark.usefixtures("roomy_free_tier")
async def test_an_email_change_to_a_taken_address_is_stopped_by_the_database(
    h: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    tokens = await h.signup(OWNER)
    await h.add_contact(tokens, "first@example.com")
    second = (await h.add_contact(tokens, "second@example.com", name="Second")).json()
    monkeypatch.setattr(ContactRepository, "email_in_use", _never_in_use)
    response = await h.client.patch(
        f"/v1/contacts/{second['id']}", json={"email": "first@example.com"}, headers=bearer(tokens)
    )
    assert response.status_code == 409
    assert problem(response)["code"] == "contact_duplicate"
    after = await h.client.get(f"/v1/contacts/{second['id']}", headers=bearer(tokens))
    assert after.json()["email"] == "second@example.com"


@pytest.mark.parametrize("path", ["/c/invite/accept", "/c/invite/decline"])
async def test_an_answer_that_loses_the_race_for_the_invitation_changes_nothing(
    h: Harness,
    monkeypatch: pytest.MonkeyPatch,
    owner_db: psycopg.Connection[dict[str, Any]],
    path: str,
) -> None:
    tokens = await h.signup(OWNER)
    contact = (await h.add_contact(tokens, "mom@example.com")).json()
    token = h.invitation_token_for("mom@example.com")

    async def lost(*args: object, **kwargs: object) -> bool:
        return False  # another request answered between our check and our update

    monkeypatch.setattr(PortalRepository, "answer_invitation", lost)
    h.mail.clear()
    response = await h.portal_post(path, token)
    assert response.status_code == 400
    assert "This link doesn't work" in response.text
    state = await h.client.get(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))
    assert state.json()["verification_status"] == "pending"
    assert h.mail.messages == []
    answered = rows(
        owner_db,
        "SELECT 1 FROM audit_logs WHERE action IN ('contact.accepted', 'contact.declined')",
    )
    assert answered == []


# --- cross-user opt-outs must not deadlock -----------------------------------------------------


@pytest.mark.no_rate_limit
@pytest.mark.parametrize(
    "paths",
    [
        ("/c/optout", "/c/optout"),
        ("/c/invite/decline", "/c/invite/decline"),
        ("/c/optout", "/c/invite/decline"),
    ],
)
async def test_simultaneous_opt_outs_of_one_address_from_two_accounts_do_not_deadlock(
    h: Harness, owner_db: psycopg.Connection[dict[str, Any]], paths: tuple[str, str]
) -> None:
    """Two account holders list the same person, who answers both invitations at once with
    "never contact me": each request locks its own contact and then reaches for the other's
    (the PostgreSQL deadlock this once ended in came back as a 503)."""
    alice = await h.signup("alice@example.com")
    bob = await h.signup("bob@example.com")
    for round_number in range(6):
        address = f"shared{round_number}@example.com"
        contacts = [
            (await h.add_contact(tokens, address, name=f"Person {round_number}")).json()
            for tokens in (alice, bob)
        ]
        csrf = await h.portal_csrf()
        calls = []
        for index, path in enumerate(paths):
            if path == "/c/optout":
                token = h.optout_token_for(address, index)
                data = {"token": token, "csrf": csrf, "scope": "everyone"}
            else:
                token = h.invitation_token_for(address, index)
                data = {"token": token, "csrf": csrf, "never_contact": "1"}
            calls.append(h.client.post(path, data=data))
        responses = await asyncio.gather(*calls)
        # One answer wins; the other either also succeeds or finds its invitation already ended
        # by the winner's block (400). It must never be a server error, which is what a lock
        # cycle ends in.
        codes = [r.status_code for r in responses]
        assert set(codes) <= {200, 400}, (round_number, codes)
        assert 200 in codes, (round_number, codes)
        statuses = rows(
            owner_db,
            "SELECT verification_status FROM trusted_contacts WHERE email_normalized = %s",
            address,
        )
        assert len(statuses) == 2
        assert all(s["verification_status"] in {"opted_out", "declined"} for s in statuses)
        assert len(rows(owner_db, "SELECT 1 FROM email_suppressions")) == round_number + 1
        # Free accounts hold one contact: make room for the next round.
        for tokens, contact in zip((alice, bob), contacts, strict=True):
            deleted = await h.client.delete(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))
            assert deleted.status_code == 204


@pytest.mark.parametrize("path", ["/c/optout", "/c/invite/decline"])
async def test_an_address_changed_while_waiting_for_the_address_lock_is_not_blocked(
    h: Harness,
    monkeypatch: pytest.MonkeyPatch,
    owner_db: psycopg.Connection[dict[str, Any]],
    path: str,
) -> None:
    """The contact's address is read, then the address lock is awaited, then the row is locked.
    If the account holder changed the address in between, the answer was meant for the old
    address: nothing may be blocked or recorded for the new one."""
    tokens = await h.signup(OWNER)
    contact = (await h.add_contact(tokens, "mom@example.com")).json()
    if path == "/c/optout":
        token = h.optout_token_for("mom@example.com")
        fields = {"scope": "everyone"}
    else:
        token = h.invitation_token_for("mom@example.com")
        fields = {"never_contact": "1"}
    original = SuppressionRepository.lock_address

    async def lock_after_the_owner_edits(self: SuppressionRepository, email_hash: bytes) -> None:
        owner_db.execute(
            "UPDATE trusted_contacts SET email = 'fixed@example.com', "
            "email_normalized = 'fixed@example.com' WHERE id = %s",
            (contact["id"],),
        )
        await original(self, email_hash)

    monkeypatch.setattr(SuppressionRepository, "lock_address", lock_after_the_owner_edits)
    h.mail.clear()
    response = await h.portal_post(path, token, **fields)
    assert response.status_code == 400
    assert "This link doesn't work" in response.text
    assert rows(owner_db, "SELECT 1 FROM email_suppressions") == []
    state = await h.client.get(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))
    assert state.json()["verification_status"] == "pending"
    assert h.mail.messages == []
