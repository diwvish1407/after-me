"""Audit records of the contact flows: IDs and reason codes only, correct visibility."""

from __future__ import annotations

from typing import Any

import psycopg

from tests.support import Harness, bearer, make_premium, rows

Conn = psycopg.Connection[dict[str, Any]]
OWNER = "owner@example.com"
SECRET_NAME = "Quentin Secretname"
ADDRESS = "quentin.secret@example.com"


def _events(owner_db: Conn, *, prefix: str = "contact.") -> list[dict[str, Any]]:
    return rows(owner_db, "SELECT * FROM audit_logs WHERE action LIKE %s ORDER BY id", prefix + "%")


async def test_owner_actions_are_audited_with_the_right_visibility(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await h.signup(OWNER)
    user_id = tokens["user"]["id"]
    created = (await h.add_contact(tokens, ADDRESS, name=SECRET_NAME)).json()
    url = f"/v1/contacts/{created['id']}"
    await h.client.patch(
        url, json={"display_name": "Renamed", "priority": 4}, headers=bearer(tokens)
    )
    await h.client.post(f"{url}/invitation", headers=bearer(tokens))
    await h.client.delete(url, headers=bearer(tokens))

    events = _events(owner_db)
    assert [(e["action"], e["user_visible"]) for e in events] == [
        ("contact.created", True),
        ("contact.invitation_sent", True),
        ("contact.updated", False),
        ("contact.invitation_sent", True),
        ("contact.deleted", True),
    ]
    for event in events:
        assert str(event["subject_user_id"]) == user_id
        assert event["actor_type"] == "user"
        assert str(event["actor_id"]) == user_id
        assert event["resource_type"] == "contact"
        assert str(event["resource_id"]) == created["id"]
        assert event["request_id"]
        assert event["ip_hash"] is not None
    assert events[1]["metadata"] == {"send_count": 1}
    assert events[2]["metadata"] == {"fields": "name.priority"}
    assert events[3]["metadata"] == {"send_count": 2}
    assert events[0]["metadata"] == events[4]["metadata"] == {}


async def test_email_change_is_audited_as_update_and_new_invitation(
    h: Harness, owner_db: Conn
) -> None:
    tokens = await h.signup(OWNER)
    created = (await h.add_contact(tokens, ADDRESS)).json()
    await h.client.patch(
        f"/v1/contacts/{created['id']}",
        json={"email": "elsewhere@example.com", "phone_e164": "+919876543210", "is_active": False},
        headers=bearer(tokens),
    )
    events = _events(owner_db)
    assert [e["action"] for e in events] == [
        "contact.created",
        "contact.invitation_sent",
        "contact.updated",
        "contact.invitation_sent",
    ]
    assert events[2]["metadata"] == {"fields": "email.active.phone"}
    assert events[3]["metadata"] == {"send_count": 1}  # the count restarts for the new address


async def test_portal_answers_are_audited_as_the_contact(h: Harness, owner_db: Conn) -> None:
    tokens = await h.signup(OWNER)
    make_premium(owner_db, OWNER)
    accepted = (await h.add_contact(tokens, "a@example.com", name="A")).json()
    declined = (await h.add_contact(tokens, "b@example.com", name="B")).json()
    opted = (await h.add_contact(tokens, "c@example.com", name="C")).json()
    await h.portal_post("/c/invite/accept", h.invitation_token_for("a@example.com"))
    await h.portal_post("/c/invite/decline", h.invitation_token_for("b@example.com"))
    await h.portal_post("/c/optout", h.optout_token_for("c@example.com"), scope="this_person")

    by_action = {
        e["action"]: e
        for e in _events(owner_db)
        if e["action"] in {"contact.accepted", "contact.declined", "contact.opted_out"}
    }
    assert set(by_action) == {"contact.accepted", "contact.declined", "contact.opted_out"}
    expected = {
        "contact.accepted": (accepted, {}),
        "contact.declined": (declined, {"never_contact": False}),
        "contact.opted_out": (opted, {"scope": "this_person"}),
    }
    for action, (contact, metadata) in expected.items():
        event = by_action[action]
        assert event["user_visible"] is True
        assert event["actor_type"] == "contact"
        assert str(event["actor_id"]) == contact["id"]
        assert str(event["subject_user_id"]) == tokens["user"]["id"]
        assert event["metadata"] == metadata


async def test_audit_records_hold_no_names_addresses_or_tokens(h: Harness, owner_db: Conn) -> None:
    tokens = await h.signup(OWNER)
    created = (await h.add_contact(tokens, ADDRESS, name=SECRET_NAME)).json()
    invitation = h.invitation_token_for(ADDRESS)
    optout = h.optout_token_for(ADDRESS)
    await h.client.patch(
        f"/v1/contacts/{created['id']}", json={"display_name": "Other Name"}, headers=bearer(tokens)
    )
    await h.portal_post("/c/invite/decline", invitation, never_contact="1")
    await h.portal_post("/c/optout", optout, scope="everyone")
    await h.client.delete(f"/v1/contacts/{created['id']}", headers=bearer(tokens))

    stored = str(
        rows(owner_db, "SELECT metadata, request_id, resource_type, action FROM audit_logs")
        + rows(owner_db, "SELECT key FROM rate_limit_counters")
    )
    for value in (
        SECRET_NAME,
        "Secretname",
        "Other Name",
        ADDRESS,
        "quentin",
        invitation,
        optout,
        invitation[3:],
        OWNER,
    ):
        assert value not in stored, value
    assert "@" not in stored
    for event in _events(owner_db):
        assert set(event["metadata"]) <= {"fields", "send_count", "never_contact", "scope"}
