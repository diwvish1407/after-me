"""Recipient web pages: landing, invitation, accept, decline (API_SPEC §13.1; SEC-13..15)."""

from __future__ import annotations

import asyncio
import re
from typing import Any

import psycopg
import pytest

from app.contacts.tokens import CONSENT_TEXT_VERSION, suppression_hash
from tests.support import Harness, bearer, make_premium, rows

Conn = psycopg.Connection[dict[str, Any]]
OWNER = "owner@example.com"
MOM = "mom@example.com"
STATE_TABLES = (
    "trusted_contacts",
    "contact_verifications",
    "email_suppressions",
    "audit_logs",
    "users",
    "sessions",
)


async def _invited(h: Harness, name: str = "Mom") -> tuple[dict[str, Any], dict[str, Any], str]:
    tokens = await h.signup(OWNER)
    contact = (await h.add_contact(tokens, MOM, name=name)).json()
    return tokens, contact, h.invitation_token_for(MOM)


def _snapshot(owner_db: Conn) -> dict[str, Any]:
    return {t: rows(owner_db, f"SELECT * FROM {t} ORDER BY 1") for t in STATE_TABLES}  # noqa: S608


async def _contact(h: Harness, tokens: dict[str, Any], contact: dict[str, Any]) -> dict[str, Any]:
    response = await h.client.get(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))
    return dict(response.json())


# --- the landing page --------------------------------------------------------------------------


async def test_landing_page_is_a_static_form_with_a_first_party_script(
    h: Harness, owner_db: Conn
) -> None:
    await _invited(h)
    before = _snapshot(owner_db)
    response = await h.client.get("/c/open", params={"token": "ci_" + "A" * 43})
    assert response.status_code == 200
    assert _snapshot(owner_db) == before  # GET changes no state
    html = response.text
    assert 'action="/c/session"' in html
    assert 'data-prefix="ci_"' in html
    assert 'name="token"' in html
    assert "ci_AAAA" not in html  # a token in the query string is never read or echoed
    nonce = re.search(r'<script nonce="([^"]+)"', html)
    assert nonce is not None
    csp = response.headers["content-security-policy"]
    assert f"script-src 'nonce-{nonce[1]}'" in csp
    assert "unsafe-inline" not in csp
    assert "frame-ancestors 'none'" in csp
    assert "default-src 'none'" in csp
    assert "replaceState" in html  # the fragment is cleared from the address bar
    assert "src=" not in html.replace('nonce="', "")  # no external script, image or frame
    assert response.headers["referrer-policy"] == "no-referrer"
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["x-robots-tag"] == "noindex, nofollow"
    assert response.headers["x-frame-options"] == "DENY"
    cookie = response.headers["set-cookie"]
    assert cookie.startswith("__Host-afterme_csrf=")
    for attribute in ("Secure", "HttpOnly", "SameSite=strict", "Path=/"):
        assert attribute.lower() in cookie.lower()
    assert "Domain" not in cookie


async def test_each_landing_response_has_a_fresh_nonce(h: Harness) -> None:
    first = await h.client.get("/c/open")
    second = await h.client.get("/c/open")
    nonce_a = re.search(r'nonce="([^"]+)"', first.text)
    nonce_b = re.search(r'nonce="([^"]+)"', second.text)
    assert nonce_a is not None
    assert nonce_b is not None
    assert nonce_a[1] != nonce_b[1]


async def test_the_landing_page_reuses_a_valid_csrf_cookie(h: Harness) -> None:
    first = await h.portal_csrf()
    second = await h.portal_csrf()
    assert first == second


# --- the invitation page -----------------------------------------------------------------------


async def test_session_shows_the_invitation_without_changing_anything(
    h: Harness, owner_db: Conn
) -> None:
    _, _, token = await _invited(h)
    before = _snapshot(owner_db)
    response = await h.portal_post("/c/session", token)
    assert response.status_code == 200
    html = response.text
    assert "Test User" in html
    assert OWNER in html
    assert 'action="/c/invite/accept"' in html
    assert 'action="/c/invite/decline"' in html
    assert "Never contact me about AfterMe again" in html
    assert html.count(f'name="token" value="{token}"') == 3  # the token is re-posted in the body
    assert "AfterMe is not an emergency service." in html
    assert "you don't need to install anything" in html.lower()
    assert _snapshot(owner_db) == before
    assert response.headers["cache-control"] == "no-store"
    assert "script-src 'nonce-" in response.headers["content-security-policy"]


async def test_the_inviters_name_is_escaped(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    patched = await h.client.patch(
        "/v1/me/profile",
        json={"display_name": "<img src=x onerror=alert(1)>"},
        headers=bearer(tokens),
    )
    assert patched.status_code == 200
    await h.add_contact(tokens, MOM, name="<b>Mom</b>")
    page = await h.portal_post("/c/session", h.invitation_token_for(MOM))
    assert page.status_code == 200
    assert "<img src=x" not in page.text
    assert "&lt;img src=x onerror=alert(1)&gt;" in page.text
    assert "<b>Mom</b>" not in page.text


async def test_the_session_route_ignores_tokens_outside_the_body(h: Harness) -> None:
    _, _, token = await _invited(h)
    csrf = await h.portal_csrf()
    in_query = await h.client.post(f"/c/session?token={token}", data={"csrf": csrf})
    assert in_query.status_code == 400
    in_header = await h.client.post(
        "/c/session", data={"csrf": csrf}, headers={"X-Token": token, "Authorization": token}
    )
    assert in_header.status_code == 400


# --- CSRF --------------------------------------------------------------------------------------

POST_ROUTES = ["/c/session", "/c/invite/accept", "/c/invite/decline"]


@pytest.mark.parametrize("path", POST_ROUTES)
async def test_posts_without_a_matching_csrf_pair_change_nothing(
    h: Harness, owner_db: Conn, path: str
) -> None:
    tokens, contact, token = await _invited(h)
    before = _snapshot(owner_db)

    missing_cookie = await h.client.post(path, data={"token": token, "csrf": "x" * 43})
    assert missing_cookie.status_code == 403

    csrf = await h.portal_csrf()
    missing_field = await h.client.post(path, data={"token": token})
    assert missing_field.status_code == 403
    wrong = await h.client.post(path, data={"token": token, "csrf": csrf[::-1]})
    assert wrong.status_code == 403
    as_json = await h.client.post(path, json={"token": token, "csrf": csrf})
    assert as_json.status_code == 403
    for refused in (missing_cookie, missing_field, wrong, as_json):
        assert "Test User" not in refused.text  # nothing about the invitation leaks
        assert "script-src 'nonce-" in refused.headers["content-security-policy"]
    assert _snapshot(owner_db) == before
    assert (await _contact(h, tokens, contact))["verification_status"] == "pending"


async def test_the_right_csrf_pair_is_accepted(h: Harness) -> None:
    _, _, token = await _invited(h)
    csrf = await h.portal_csrf()
    assert (
        await h.client.post("/c/session", data={"token": token, "csrf": csrf})
    ).status_code == 200


# --- unusable links ----------------------------------------------------------------------------


async def test_every_unusable_token_renders_the_same_generic_page(
    h: Harness, owner_db: Conn
) -> None:
    tokens, contact, token = await _invited(h)
    # 1. malformed, 2. unknown (well formed), 3. truncated, 4. tampered with
    candidates = {
        "malformed": "hello",
        "empty": "",
        "unknown": "ci_" + "B" * 43,
        "truncated": token[:-1],
        "tampered": token[:-1] + ("A" if token[-1] != "A" else "B"),
        "wrong_prefix": "pr_" + token[3:],
    }
    pages: dict[str, tuple[int, str]] = {}
    for name, value in candidates.items():
        response = await h.portal_post("/c/session", value)
        pages[name] = (response.status_code, response.text)

    # 5. expired
    h.clock.advance(days=15)
    expired = await h.portal_post("/c/session", token)
    pages["expired"] = (expired.status_code, expired.text)
    h.clock.advance(days=-15)
    # 6. answered
    assert (await h.portal_post("/c/invite/accept", token)).status_code == 200
    answered = await h.portal_post("/c/session", token)
    pages["answered"] = (answered.status_code, answered.text)
    # 7. invalidated by deleting the contact
    other = await h.add_contact(tokens, "second@example.com", name="Second")
    assert other.status_code == 403  # free tier; make room first
    await h.client.delete(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))
    deleted = await h.portal_post("/c/session", token)
    pages["deleted_contact"] = (deleted.status_code, deleted.text)

    statuses = {status for status, _ in pages.values()}
    bodies = {body for _, body in pages.values()}
    assert statuses == {400}, pages.keys()
    assert len(bodies) == 1, "unusable links must be indistinguishable"
    body = next(iter(bodies))
    assert "This link doesn't work" in body
    assert "Test User" not in body
    assert OWNER not in body
    assert MOM not in body


async def test_an_opted_out_or_verified_contact_cannot_reopen_an_old_invitation(
    h: Harness, owner_db: Conn
) -> None:
    _, _, token = await _invited(h)
    owner_db.execute("UPDATE trusted_contacts SET verification_status = 'opted_out'")
    response = await h.portal_post("/c/session", token)
    assert response.status_code == 400
    assert "Test User" not in response.text


# --- accept ------------------------------------------------------------------------------------


async def test_accept_verifies_the_contact_and_tells_the_owner(h: Harness, owner_db: Conn) -> None:
    tokens, contact, token = await _invited(h)
    h.clock.advance(hours=3)
    tokens = await h.relogin(OWNER)
    response = await h.portal_post("/c/invite/accept", token)
    assert response.status_code == 200
    assert "Thank you" in response.text
    assert "Test User" in response.text
    assert "__Host-afterme_csrf" in response.headers["set-cookie"]  # the cookie is cleared
    assert "Max-Age=0" in response.headers["set-cookie"]

    state = await _contact(h, tokens, contact)
    assert state["verification_status"] == "verified"
    assert state["verified_at"] == "2026-10-08T12:00:00Z"
    invitation = rows(owner_db, "SELECT * FROM contact_verifications")[0]
    assert invitation["response"] == "accepted"
    assert invitation["responded_at"] == h.clock.current
    assert invitation["consent_text_version"] == CONSENT_TEXT_VERSION
    assert invitation["ip_hash"] is not None
    assert b"203.0.113.10" not in bytes(invitation["ip_hash"])  # a pseudonymous hash only

    notices = h.mail.to(OWNER, "contact_accepted")
    assert len(notices) == 1
    assert notices[0].subject == "Mom accepted your AfterMe invitation"
    assert "AfterMe is not an emergency service." in notices[0].text
    assert MOM not in notices[0].text  # the notice does not repeat the address


async def test_an_invitation_can_be_answered_only_once(h: Harness, owner_db: Conn) -> None:
    tokens, contact, token = await _invited(h)
    assert (await h.portal_post("/c/invite/accept", token)).status_code == 200
    for path in ("/c/invite/accept", "/c/invite/decline", "/c/session"):
        again = await h.portal_post(path, token)
        assert again.status_code == 400, path
    assert (await _contact(h, tokens, contact))["verification_status"] == "verified"
    assert len(h.mail.to(OWNER, "contact_accepted")) == 1
    assert len(rows(owner_db, "SELECT 1 FROM audit_logs WHERE action = 'contact.accepted'")) == 1


async def test_two_simultaneous_accepts_succeed_once(h: Harness, owner_db: Conn) -> None:
    _, _, token = await _invited(h)
    csrf = await h.portal_csrf()
    results = await asyncio.gather(
        *(h.client.post("/c/invite/accept", data={"token": token, "csrf": csrf}) for _ in range(3))
    )
    assert sorted(r.status_code for r in results) == [200, 400, 400]
    assert len(h.mail.to(OWNER, "contact_accepted")) == 1
    assert (
        len(rows(owner_db, "SELECT 1 FROM contact_verifications WHERE response = 'accepted'")) == 1
    )


async def test_accept_and_decline_race_has_one_winner(h: Harness) -> None:
    tokens, contact, token = await _invited(h)
    csrf = await h.portal_csrf()
    accept, decline = await asyncio.gather(
        h.client.post("/c/invite/accept", data={"token": token, "csrf": csrf}),
        h.client.post("/c/invite/decline", data={"token": token, "csrf": csrf}),
    )
    assert sorted([accept.status_code, decline.status_code]) == [200, 400]
    status = (await _contact(h, tokens, contact))["verification_status"]
    assert status == ("verified" if accept.status_code == 200 else "declined")


async def test_the_owner_changing_the_address_during_the_invitation_wins(h: Harness) -> None:
    tokens, contact, token = await _invited(h)
    await h.client.patch(
        f"/v1/contacts/{contact['id']}", json={"email": "new@example.com"}, headers=bearer(tokens)
    )
    assert (await h.portal_post("/c/invite/accept", token)).status_code == 400
    assert (await _contact(h, tokens, contact))["verification_status"] == "pending"


# --- decline -----------------------------------------------------------------------------------


async def test_decline_records_the_answer_and_blocks_new_invitations(
    h: Harness, owner_db: Conn
) -> None:
    tokens, contact, token = await _invited(h)
    response = await h.portal_post("/c/invite/decline", token)
    assert response.status_code == 200
    assert "Thanks for letting us know" in response.text
    assert "won't send this invitation again" in response.text

    state = await _contact(h, tokens, contact)
    assert state["verification_status"] == "declined"
    assert state["verified_at"] is None
    invitation = rows(owner_db, "SELECT * FROM contact_verifications")[0]
    assert invitation["response"] == "declined"
    assert rows(owner_db, "SELECT * FROM email_suppressions") == []  # a plain decline only
    notices = h.mail.to(OWNER, "contact_declined")
    assert len(notices) == 1
    assert notices[0].subject == "Mom declined your AfterMe invitation"

    resend = await h.client.post(f"/v1/contacts/{contact['id']}/invitation", headers=bearer(tokens))
    assert resend.status_code == 409  # a declined contact is never re-invited from here


async def test_never_contact_me_blocks_the_address_for_everyone(h: Harness, owner_db: Conn) -> None:
    alice = await h.signup("alice@example.com")
    bob = await h.signup("bob@example.com")
    carol = await h.signup("carol@example.com")
    a_contact = (await h.add_contact(alice, MOM, name="Mom")).json()
    b_contact = (await h.add_contact(bob, "Mom@Example.com", name="Mother")).json()
    token = h.invitation_token_for(MOM, 0)
    h.mail.clear()

    response = await h.portal_post("/c/invite/decline", token, never_contact="1")
    assert response.status_code == 200
    assert "We won't contact you about AfterMe again" in response.text

    assert (await _contact(h, alice, a_contact))["verification_status"] == "declined"
    assert (await _contact(h, bob, b_contact))["verification_status"] == "opted_out"
    suppressed = rows(owner_db, "SELECT * FROM email_suppressions")
    assert len(suppressed) == 1
    assert suppressed[0]["reason"] == "contact_block_all"
    assert str(suppressed[0]["source_contact_id"]) == a_contact["id"]
    app_pepper = h.app.state.services.pepper
    assert bytes(suppressed[0]["email_hash"]) == suppression_hash(app_pepper, MOM)
    assert MOM.encode() not in bytes(suppressed[0]["email_hash"])

    # Both account holders are told; nothing else leaves the system.
    assert len(h.mail.to("alice@example.com", "contact_declined")) == 1
    assert len(h.mail.to("bob@example.com", "contact_opted_out")) == 1
    assert [m.template for m in h.mail.messages if m.to == MOM] == []
    # A third account listing the same address gets a contact but no invitation.
    h.mail.clear()
    created = await h.add_contact(carol, MOM, name="Mum")
    assert created.status_code == 201
    assert created.json()["verification_status"] == "pending"
    assert created.json()["invitation_send_count"] == 0
    assert h.mail.messages == []


async def test_a_declined_invitation_cannot_be_used_to_accept(h: Harness) -> None:
    tokens, contact, token = await _invited(h)
    assert (await h.portal_post("/c/invite/decline", token)).status_code == 200
    assert (await h.portal_post("/c/invite/accept", token)).status_code == 400
    assert (await _contact(h, tokens, contact))["verification_status"] == "declined"


# --- rate limit --------------------------------------------------------------------------------


async def test_portal_posts_are_limited_to_twenty_an_hour_per_ip(h: Harness) -> None:
    _, _, token = await _invited(h)
    csrf = await h.portal_csrf()
    paths = [
        "/c/session",
        "/c/invite/accept",
        "/c/invite/decline",
        "/c/optout/confirm",
        "/c/optout",
    ]
    statuses = []
    for n in range(20):
        response = await h.client.post(
            paths[n % len(paths)], data={"token": "ci_" + "C" * 43, "csrf": csrf}
        )
        statuses.append(response.status_code)
    assert 429 not in statuses
    limited = await h.client.post("/c/session", data={"token": token, "csrf": csrf})
    assert limited.status_code == 429
    assert int(limited.headers["retry-after"]) >= 1
    assert "Too many attempts" in limited.text
    assert "Test User" not in limited.text
    # The window passes; the real invitation still works.
    h.clock.advance(hours=1)
    assert (await h.portal_post("/c/session", token)).status_code == 200


# --- audit -------------------------------------------------------------------------------------


async def test_answers_are_audited_without_personal_data(h: Harness, owner_db: Conn) -> None:
    _, contact, token = await _invited(h, name="Secret Name")
    await h.portal_post("/c/invite/accept", token)
    events = rows(
        owner_db,
        "SELECT * FROM audit_logs WHERE action IN ('contact.created', 'contact.invitation_sent', "
        "'contact.accepted') ORDER BY id",
    )
    assert [e["action"] for e in events] == [
        "contact.created",
        "contact.invitation_sent",
        "contact.accepted",
    ]
    assert all(e["user_visible"] for e in events)
    accepted = events[-1]
    assert accepted["actor_type"] == "contact"
    assert str(accepted["actor_id"]) == contact["id"]
    assert str(accepted["resource_id"]) == contact["id"]
    assert accepted["resource_type"] == "contact"
    assert accepted["ip_hash"] is not None
    text = str([(e["metadata"], e["request_id"]) for e in events])
    for value in (MOM, "Secret Name", "Test User", token, OWNER):
        assert value not in text
    assert "@" not in text


async def test_premium_accounts_can_have_many_pending_invitations(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await h.signup(OWNER)
    make_premium(owner_db, OWNER)
    first = (await h.add_contact(tokens, "a@example.com", name="A")).json()
    second = (await h.add_contact(tokens, "b@example.com", name="B")).json()
    token_a = h.invitation_token_for("a@example.com")
    token_b = h.invitation_token_for("b@example.com")
    assert (await h.portal_post("/c/invite/accept", token_a)).status_code == 200
    assert (await h.portal_post("/c/invite/decline", token_b)).status_code == 200
    assert (await _contact(h, tokens, first))["verification_status"] == "verified"
    assert (await _contact(h, tokens, second))["verification_status"] == "declined"
