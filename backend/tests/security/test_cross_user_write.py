"""The one deliberate cross-user write (``SuppressionRepository.opt_out_all_contacts_with_email``).

Everything else in the application is owner-scoped; this function changes every live contact row
that holds one address, whoever owns it, because the person behind the address said *never contact
me about AfterMe again*. Its callers are covered in ``test_contact_optout.py``; this file tests the
function itself.
"""

from __future__ import annotations

import uuid
from typing import Any

import psycopg
from fastapi import FastAPI

from app.contacts.repository import SuppressionRepository
from tests.support import Harness, rows

Conn = psycopg.Connection[dict[str, Any]]
ADDRESS = "shared@example.com"


def _user(owner_db: Conn, email: str) -> str:
    return str(
        owner_db.execute(
            "INSERT INTO users (email, email_normalized, password_hash, email_verified_at) "
            "VALUES (%s, %s, 'x', now()) RETURNING id",
            (email, email),
        ).fetchone()["id"]  # type: ignore[index]
    )


def _contact(owner_db: Conn, user: str, email: str | None, **extra: Any) -> str:
    values = {
        "user_id": user,
        "display_name": f"Contact of {user[:4]}",
        "relationship": "friend",
        "email": email,
        "email_normalized": email,
        **extra,
    }
    return str(
        owner_db.execute(
            f"INSERT INTO trusted_contacts ({', '.join(values)}) "  # noqa: S608
            f"VALUES ({', '.join(['%s'] * len(values))}) RETURNING id",
            tuple(values.values()),
        ).fetchone()["id"]  # type: ignore[index]
    )


def _invitation(owner_db: Conn, contact: str, token: bytes, expires: str = "14 days") -> None:
    owner_db.execute(
        "INSERT INTO contact_verifications (contact_id, token_hash, expires_at, "
        "consent_text_version) VALUES (%s, %s, now() + %s::interval, 'v')",
        (contact, token, expires),
    )


async def _run(app: FastAPI, **kwargs: Any) -> Any:
    services = app.state.services
    async with services.db.sessionmaker() as session:
        result = await SuppressionRepository(session).opt_out_all_contacts_with_email(
            now=services.clock.current, **kwargs
        )
        await session.commit()
        return result


async def test_it_changes_every_live_row_with_the_address_across_owners(
    h: Harness, owner_db: Conn
) -> None:
    alice, bob, carol = (_user(owner_db, f"{n}@example.com") for n in ("alice", "bob", "carol"))
    a = _contact(owner_db, alice, ADDRESS, verification_status="verified", verified_at="now()")
    b = _contact(owner_db, bob, ADDRESS)
    declined = _contact(owner_db, carol, ADDRESS, verification_status="declined")
    elsewhere = _contact(owner_db, alice, "other@example.com")
    scrubbed = _contact(owner_db, bob, None, deleted_at="2026-01-01T00:00:00Z")
    _invitation(owner_db, a, b"inv-a")
    _invitation(owner_db, b, b"inv-b")
    _invitation(owner_db, elsewhere, b"inv-else")

    affected = await _run(h.app, email_normalized=ADDRESS)

    assert {str(x.contact_id) for x in affected} == {a, b, declined}
    assert {str(x.owner_id) for x in affected} == {alice, bob, carol}
    assert {x.owner_email for x in affected} == {
        "alice@example.com",
        "bob@example.com",
        "carol@example.com",
    }
    statuses = {
        str(r["id"]): (r["verification_status"], r["verified_at"])
        for r in rows(owner_db, "SELECT id, verification_status, verified_at FROM trusted_contacts")
    }
    for contact in (a, b, declined):
        assert statuses[contact] == ("opted_out", None)
    assert statuses[elsewhere][0] == "pending"  # a different address is untouched
    assert statuses[scrubbed][0] == "pending"  # scrubbed rows hold no address
    live = {
        bytes(r["token_hash"])
        for r in rows(
            owner_db, "SELECT token_hash FROM contact_verifications WHERE expires_at > now()"
        )
    }
    assert live == {b"inv-else"}  # the opted-out contacts' invitations are cancelled


async def test_it_can_leave_one_row_out_and_is_idempotent(h: Harness, owner_db: Conn) -> None:
    alice, bob = _user(owner_db, "alice@example.com"), _user(owner_db, "bob@example.com")
    a = _contact(owner_db, alice, ADDRESS)
    b = _contact(owner_db, bob, ADDRESS)
    first = await _run(h.app, email_normalized=ADDRESS, except_contact_id=uuid.UUID(a))
    assert [str(x.contact_id) for x in first] == [b]
    again = await _run(h.app, email_normalized=ADDRESS, except_contact_id=uuid.UUID(a))
    assert again == []
    row = rows(owner_db, "SELECT verification_status FROM trusted_contacts WHERE id = %s", a)[0]
    assert row["verification_status"] == "pending"


async def test_an_address_nobody_lists_changes_nothing(h: Harness, owner_db: Conn) -> None:
    alice = _user(owner_db, "alice@example.com")
    _contact(owner_db, alice, "someone@example.com")
    before = rows(owner_db, "SELECT * FROM trusted_contacts")
    assert await _run(h.app, email_normalized=ADDRESS) == []
    assert rows(owner_db, "SELECT * FROM trusted_contacts") == before
