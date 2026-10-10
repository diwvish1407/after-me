"""Opt-out links: stateless tokens, this person / everyone, forgery and rotation (CON-*, SEC-*)."""

from __future__ import annotations

import re
import uuid
from datetime import timedelta
from typing import Any

import psycopg
import pytest

from app.contacts.tokens import new_optout_token, suppression_hash
from app.security.hashing import Pepper
from tests.support import TEST_PEPPER, Harness, bearer, rows

Conn = psycopg.Connection[dict[str, Any]]
OWNER = "owner@example.com"
MOM = "mom@example.com"
ROTATED = "a-brand-new-pepper-value-of-at-least-32-bytes!!"


async def _invited(h: Harness, owner: str = OWNER, address: str = MOM) -> tuple[Any, Any, str]:
    tokens = await h.signup(owner)
    contact = (await h.add_contact(tokens, address)).json()
    return tokens, contact, h.optout_token_for(address)


async def _status(h: Harness, tokens: Any, contact: Any) -> str:
    response = await h.client.get(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))
    return str(response.json()["verification_status"])


# --- the landing and choice pages --------------------------------------------------------------


async def test_optout_landing_reads_the_oo_fragment(h: Harness) -> None:
    response = await h.client.get("/c/optout")
    assert response.status_code == 200
    assert 'action="/c/optout/confirm"' in response.text
    assert 'data-prefix="oo_"' in response.text
    assert "replaceState" in response.text
    assert response.headers["set-cookie"].startswith("__Host-afterme_csrf=")


async def test_confirm_shows_the_two_choices_without_changing_anything(
    h: Harness, owner_db: Conn
) -> None:
    _, _, token = await _invited(h)
    before = rows(owner_db, "SELECT * FROM trusted_contacts")
    audits = rows(owner_db, "SELECT id FROM audit_logs")
    response = await h.portal_post("/c/optout/confirm", token)
    assert response.status_code == 200
    html = response.text
    assert "Stop emails from Test User's AfterMe" in html
    assert "Never contact me about AfterMe again" in html
    assert 'name="scope" value="this_person"' in html
    assert 'name="scope" value="everyone"' in html
    assert html.count(f'value="{token}"') == 2
    assert rows(owner_db, "SELECT * FROM trusted_contacts") == before
    assert rows(owner_db, "SELECT id FROM audit_logs") == audits


# --- this person -------------------------------------------------------------------------------


async def test_opt_out_of_one_sender_leaves_other_accounts_alone(
    h: Harness, owner_db: Conn
) -> None:
    alice, a_contact, token = await _invited(h, "alice@example.com")
    bob = await h.signup("bob@example.com")
    b_contact = (await h.add_contact(bob, MOM)).json()
    invitation = h.invitation_token_for(MOM, 0)
    bobs_invitation = h.invitation_token_for(MOM, 1)
    h.mail.clear()

    response = await h.portal_post("/c/optout", token, scope="this_person")
    assert response.status_code == 200
    assert "Opted out" in response.text
    assert "Other people who list this address are not affected" in response.text

    assert await _status(h, alice, a_contact) == "opted_out"
    assert await _status(h, bob, b_contact) == "pending"
    assert rows(owner_db, "SELECT * FROM email_suppressions") == []
    notices = h.mail.to("alice@example.com", "contact_opted_out")
    assert len(notices) == 1
    assert h.mail.to("bob@example.com") == []
    # Alice's outstanding invitation is cancelled; Bob's is not.
    assert (await h.portal_post("/c/session", invitation)).status_code == 400
    assert (await h.portal_post("/c/session", bobs_invitation)).status_code == 200


async def test_opt_out_overrides_a_verified_contact(h: Harness) -> None:
    tokens, contact, token = await _invited(h)
    assert (await h.portal_post("/c/invite/accept", h.invitation_token_for(MOM))).status_code == 200
    assert (await h.portal_post("/c/optout", token, scope="this_person")).status_code == 200
    state = (await h.client.get(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))).json()
    assert state["verification_status"] == "opted_out"
    assert state["verified_at"] is None
    resend = await h.client.post(f"/v1/contacts/{contact['id']}/invitation", headers=bearer(tokens))
    assert resend.status_code == 409


async def test_opting_out_twice_is_harmless_and_quiet(h: Harness, owner_db: Conn) -> None:
    _, _, token = await _invited(h)
    assert (await h.portal_post("/c/optout", token, scope="this_person")).status_code == 200
    again = await h.portal_post("/c/optout", token, scope="this_person")
    assert again.status_code == 200
    assert len(h.mail.to(OWNER, "contact_opted_out")) == 1
    assert len(rows(owner_db, "SELECT 1 FROM audit_logs WHERE action = 'contact.opted_out'")) == 1


async def test_the_opt_out_link_never_expires(h: Harness) -> None:
    _, contact, token = await _invited(h)
    h.clock.advance(timedelta(days=3650))
    assert (await h.portal_post("/c/optout/confirm", token)).status_code == 200
    assert (await h.portal_post("/c/optout", token, scope="this_person")).status_code == 200
    h.clock.advance(minutes=1)
    fresh = (await h.login(OWNER)).json()
    assert await _status(h, fresh, contact) == "opted_out"


# --- everyone ----------------------------------------------------------------------------------


async def test_opting_out_everywhere_suppresses_the_address_and_reaches_other_accounts(
    h: Harness, owner_db: Conn
) -> None:
    alice, a_contact, token = await _invited(h, "alice@example.com")
    bob = await h.signup("bob@example.com")
    b_contact = (await h.add_contact(bob, "  MOM@example.com ", name="Mum")).json()
    carol = await h.signup("carol@example.com")
    other = (await h.add_contact(carol, "someone.else@example.com")).json()
    dave = await h.signup("dave@example.com")
    deleted = (await h.add_contact(dave, MOM)).json()
    await h.client.delete(f"/v1/contacts/{deleted['id']}", headers=bearer(dave))
    h.mail.clear()

    response = await h.portal_post("/c/optout", token, scope="everyone")
    assert response.status_code == 200
    assert "We won't contact you about AfterMe again" in response.text

    assert await _status(h, alice, a_contact) == "opted_out"
    assert await _status(h, bob, b_contact) == "opted_out"
    assert await _status(h, carol, other) == "pending"  # a different address
    assert (
        rows(owner_db, "SELECT deleted_at FROM trusted_contacts WHERE id = %s", deleted["id"])[0][
            "deleted_at"
        ]
        is not None
    )
    suppression = rows(owner_db, "SELECT * FROM email_suppressions")
    assert len(suppression) == 1
    assert bytes(suppression[0]["email_hash"]) == suppression_hash(h.app.state.services.pepper, MOM)
    assert suppression[0]["reason"] == "contact_block_all"
    assert str(suppression[0]["source_contact_id"]) == a_contact["id"]

    # Every affected owner is told and has an audit record; nobody else is.
    assert len(h.mail.to("alice@example.com", "contact_opted_out")) == 1
    assert len(h.mail.to("bob@example.com", "contact_opted_out")) == 1
    assert h.mail.to("carol@example.com") == []
    assert h.mail.to("dave@example.com") == []
    events = rows(
        owner_db,
        "SELECT subject_user_id, actor_type, user_visible, metadata FROM audit_logs "
        "WHERE action = 'contact.opted_out'",
    )
    assert len(events) == 2
    assert {str(e["subject_user_id"]) for e in events} == {
        alice["user"]["id"],
        bob["user"]["id"],
    }
    assert all(e["actor_type"] == "contact" and e["user_visible"] for e in events)
    assert all(e["metadata"] == {"scope": "everyone"} for e in events)
    # The unanswered invitations of both accounts are cancelled.
    open_ones = rows(
        owner_db, "SELECT 1 FROM contact_verifications WHERE expires_at > %s", h.clock.current
    )
    assert len(open_ones) == 1  # only carol's remains
    # New contacts with the address are created quietly, without an email.
    h.mail.clear()
    created = await h.add_contact(dave, "mom@example.com", name="Again")
    assert created.status_code == 201
    assert created.json()["invitation_send_count"] == 0
    assert h.mail.messages == []


async def test_opting_out_everywhere_twice_keeps_one_suppression(
    h: Harness, owner_db: Conn
) -> None:
    _, _, token = await _invited(h)
    for _ in range(2):
        assert (await h.portal_post("/c/optout", token, scope="everyone")).status_code == 200
    assert len(rows(owner_db, "SELECT 1 FROM email_suppressions")) == 1
    assert len(h.mail.to(OWNER, "contact_opted_out")) == 1


async def test_everyone_after_this_person_still_suppresses(h: Harness, owner_db: Conn) -> None:
    _, _, token = await _invited(h)
    assert (await h.portal_post("/c/optout", token, scope="this_person")).status_code == 200
    assert rows(owner_db, "SELECT 1 FROM email_suppressions") == []
    assert (await h.portal_post("/c/optout", token, scope="everyone")).status_code == 200
    assert len(rows(owner_db, "SELECT 1 FROM email_suppressions")) == 1


# --- a corrected address ----------------------------------------------------------------------


async def test_a_link_for_a_corrected_address_cannot_act_on_the_new_address(
    h: Harness, owner_db: Conn
) -> None:
    """The invitation went to a mistyped address and reached a stranger. The account holder then
    fixes the address. The stranger's links must not decline, opt out or suppress the real
    contact's address."""
    tokens, contact, strangers_link = await _invited(h, address="mom@exmaple.com")
    strangers_invitation = h.invitation_token_for("mom@exmaple.com")
    fixed = await h.client.patch(
        f"/v1/contacts/{contact['id']}", json={"email": MOM}, headers=bearer(tokens)
    )
    assert fixed.status_code == 200
    for path, extra in (
        ("/c/optout/confirm", {}),
        ("/c/optout", {"scope": "everyone"}),
        ("/c/optout", {"scope": "this_person"}),
    ):
        response = await h.portal_post(path, strangers_link, **extra)
        assert response.status_code == 400, path
    for path in ("/c/session", "/c/invite/decline"):
        response = await h.portal_post(path, strangers_invitation, never_contact="1")
        assert response.status_code == 400, path
    assert await _status(h, tokens, contact) == "pending"
    assert rows(owner_db, "SELECT * FROM email_suppressions") == []
    # The real contact's own links work.
    assert (await h.portal_post("/c/optout/confirm", h.optout_token_for(MOM))).status_code == 200


# --- forged and unusable tokens ----------------------------------------------------------------


@pytest.mark.no_rate_limit
async def test_forged_tokens_render_one_generic_page_and_change_nothing(
    h: Harness, owner_db: Conn
) -> None:
    alice, a_contact, good = await _invited(h, "alice@example.com", "mom@example.com")
    bob = await h.signup("bob@example.com")
    b_contact = (await h.add_contact(bob, "dad@example.com", name="Dad")).json()
    bobs_good = h.optout_token_for("dad@example.com")
    pepper = h.app.state.services.pepper
    other_server = Pepper("x" * 48)

    contact_id = a_contact["id"]
    mac = good.split(".")[1]
    forged = {
        "garbage": "oo_nonsense",
        "no_mac": f"oo_{contact_id}",
        "wrong_mac": f"oo_{contact_id}.{'A' * 43}",
        "other_servers_mac": new_optout_token(
            other_server, uuid.UUID(contact_id), "mom@example.com"
        ),
        "bobs_mac_on_alices_id": f"oo_{contact_id}.{bobs_good.split('.')[1]}",
        "alices_mac_on_bobs_id": f"oo_{b_contact['id']}.{mac}",
        "uppercase_id": f"oo_{contact_id.upper()}.{mac}",
        "extra_suffix": good + "x",
        "truncated_mac": good[:-1],
        "unknown_contact": new_optout_token(pepper, uuid.uuid4(), "mom@example.com"),
        "invitation_token": h.invitation_token_for("mom@example.com"),
        "empty": "",
    }
    pages: dict[str, tuple[int, str]] = {}
    for name, value in forged.items():
        for path, extra in (("/c/optout/confirm", {}), ("/c/optout", {"scope": "everyone"})):
            response = await h.portal_post(path, value, **extra)
            pages[f"{name}:{path}"] = (response.status_code, response.text)
    assert {status for status, _ in pages.values()} == {400}
    assert len({body for _, body in pages.values()}) == 1, "forgeries must be indistinguishable"
    assert rows(owner_db, "SELECT * FROM email_suppressions") == []
    assert await _status(h, alice, a_contact) == "pending"
    assert await _status(h, bob, b_contact) == "pending"
    assert h.mail.to("alice@example.com", "contact_opted_out") == []


async def test_a_deleted_contacts_link_does_nothing(h: Harness, owner_db: Conn) -> None:
    tokens, contact, token = await _invited(h)
    await h.client.delete(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))
    generic = await h.portal_post("/c/optout/confirm", "oo_" + "x")
    page = await h.portal_post("/c/optout", token, scope="everyone")
    assert page.status_code == 400
    assert page.text == generic.text
    assert rows(owner_db, "SELECT * FROM email_suppressions") == []


@pytest.mark.parametrize("scope", ["", "nobody", "EVERYONE", "this_person,everyone"])
async def test_an_unknown_scope_is_refused(h: Harness, owner_db: Conn, scope: str) -> None:
    tokens, contact, token = await _invited(h)
    response = await h.portal_post("/c/optout", token, scope=scope)
    assert response.status_code == 400
    assert await _status(h, tokens, contact) == "pending"
    assert rows(owner_db, "SELECT * FROM email_suppressions") == []


async def test_optout_posts_need_csrf(h: Harness, owner_db: Conn) -> None:
    tokens, contact, token = await _invited(h)
    for path in ("/c/optout/confirm", "/c/optout"):
        response = await h.client.post(
            path, data={"token": token, "scope": "everyone", "csrf": "z" * 43}
        )
        assert response.status_code == 403
    assert await _status(h, tokens, contact) == "pending"
    assert rows(owner_db, "SELECT * FROM email_suppressions") == []


# --- pepper rotation ---------------------------------------------------------------------------


@pytest.mark.settings(hmac_pepper=ROTATED, hmac_pepper_previous=TEST_PEPPER)
async def test_links_issued_before_a_pepper_rotation_keep_working(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    contact = (await h.add_contact(tokens, MOM)).json()
    old_link = new_optout_token(Pepper(TEST_PEPPER), uuid.UUID(contact["id"]), MOM)
    new_link = h.optout_token_for(MOM)
    assert old_link != new_link  # the app now signs with the new pepper
    assert (await h.portal_post("/c/optout/confirm", old_link)).status_code == 200
    assert (await h.portal_post("/c/optout/confirm", new_link)).status_code == 200
    unknown = new_optout_token(Pepper("y" * 48), uuid.UUID(contact["id"]), MOM)
    assert (await h.portal_post("/c/optout/confirm", unknown)).status_code == 400


@pytest.mark.settings(hmac_pepper=ROTATED)
async def test_links_signed_with_a_retired_pepper_stop_working(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    contact = (await h.add_contact(tokens, MOM)).json()
    retired = new_optout_token(Pepper(TEST_PEPPER), uuid.UUID(contact["id"]), MOM)
    assert (await h.portal_post("/c/optout/confirm", retired)).status_code == 400
    assert re.fullmatch(r"oo_[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}", h.optout_token_for(MOM))
