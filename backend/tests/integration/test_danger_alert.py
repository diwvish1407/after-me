"""The Danger button: ``POST /v1/contacts/alert`` emails accepted contacts at once."""

from __future__ import annotations

from typing import Any

import psycopg

from tests.support import Harness, bearer, problem

Conn = psycopg.Connection[dict[str, Any]]
OWNER = "danger-owner@example.com"
MOM = "danger-mom@example.com"


async def _owner_with_contact(h: Harness) -> tuple[dict[str, Any], dict[str, Any]]:
    tokens = await h.signup(OWNER)
    response = await h.add_contact(tokens, MOM)
    assert response.status_code == 201, response.text
    return tokens, response.json()


async def test_alert_emails_each_accepted_contact(h: Harness, owner_db: Conn) -> None:
    tokens, contact = await _owner_with_contact(h)
    owner_db.execute(
        "UPDATE trusted_contacts SET verification_status = 'verified', verified_at = now() "
        "WHERE id = %s",
        (contact["id"],),
    )
    h.mail.clear()

    response = await h.client.post("/v1/contacts/alert", headers=bearer(tokens))

    assert response.status_code == 202, response.text
    assert response.json() == {"alerted": 1}
    sent = h.mail.to(MOM)
    assert [m.template for m in sent] == ["danger_alert"]
    assert "ask for help" in sent[0].text
    assert OWNER in sent[0].text


async def test_alert_refused_while_nobody_has_accepted(h: Harness) -> None:
    tokens, _ = await _owner_with_contact(h)  # still pending
    h.mail.clear()

    response = await h.client.post("/v1/contacts/alert", headers=bearer(tokens))

    assert response.status_code == 409
    assert problem(response)["code"] == "no_contact_to_alert"
    assert h.mail.to(MOM) == []


async def test_alert_needs_a_session(h: Harness) -> None:
    assert (await h.client.post("/v1/contacts/alert")).status_code == 401


async def test_apk_download_is_404_when_not_configured(h: Harness) -> None:
    assert (await h.client.get("/download/afterme.apk")).status_code == 404
