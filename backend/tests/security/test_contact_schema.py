"""Database-level guarantees for the Phase 3 tables (DATABASE §3.2): the constraints hold even
if the application layer is bypassed."""

from __future__ import annotations

from typing import Any

import psycopg
import pytest

Conn = psycopg.Connection[dict[str, Any]]

COLUMNS = "user_id, display_name, relationship, email, email_normalized"


def _user(owner_db: Conn, email: str = "schema@example.com") -> str:
    return str(
        owner_db.execute(
            "INSERT INTO users (email, email_normalized, password_hash) "
            "VALUES (%s, %s, 'x') RETURNING id",
            (email, email),
        ).fetchone()["id"]  # type: ignore[index]
    )


def _contact(owner_db: Conn, user_id: str, email: str = "mom@example.com", **extra: Any) -> str:
    columns = {
        "user_id": user_id,
        "display_name": "Mom",
        "relationship": "mother",
        "email": email,
        "email_normalized": email,
        **extra,
    }
    names = ", ".join(columns)
    marks = ", ".join(["%s"] * len(columns))
    return str(
        owner_db.execute(
            f"INSERT INTO trusted_contacts ({names}) VALUES ({marks}) RETURNING id",  # noqa: S608
            tuple(columns.values()),
        ).fetchone()["id"]  # type: ignore[index]
    )


def test_defaults(owner_db: Conn) -> None:
    contact = _contact(owner_db, _user(owner_db))
    row = owner_db.execute("SELECT * FROM trusted_contacts WHERE id = %s", (contact,)).fetchone()
    assert row is not None
    assert row["priority"] == 100
    assert row["verification_status"] == "pending"
    assert row["is_active"] is True
    assert row["invitation_send_count"] == 0
    assert row["verified_at"] is None
    assert row["deleted_at"] is None


def test_the_same_address_cannot_be_listed_twice_by_one_user(owner_db: Conn) -> None:
    user = _user(owner_db)
    other = _user(owner_db, "other@example.com")
    first = _contact(owner_db, user)
    _contact(owner_db, other)  # another user may list it
    with pytest.raises(psycopg.errors.UniqueViolation):
        _contact(owner_db, user)
    # A deleted row (address scrubbed) frees the address.
    owner_db.execute(
        "UPDATE trusted_contacts SET deleted_at = now(), email = NULL, email_normalized = NULL "
        "WHERE id = %s",
        (first,),
    )
    _contact(owner_db, user)


def test_composite_unique_allows_same_owner_foreign_keys(owner_db: Conn) -> None:
    user = _user(owner_db)
    contact = _contact(owner_db, user)
    with pytest.raises(psycopg.errors.UniqueViolation):
        owner_db.execute(
            "INSERT INTO trusted_contacts (id, user_id, display_name, relationship, email) "
            "VALUES (%s, %s, 'X', 'friend', 'x@example.com')",
            (contact, user),
        )
    constraint = owner_db.execute(
        "SELECT pg_get_constraintdef(oid) AS d FROM pg_constraint "
        "WHERE conname = 'uq_trusted_contacts_id_user'"
    ).fetchone()
    assert constraint == {"d": "UNIQUE (id, user_id)"}


@pytest.mark.parametrize(
    "extra",
    [
        {"relationship": "boss"},
        {"phone_e164": "12345"},
        {"relationship_label": "x" * 41},
        {"priority": 0},
        {"priority": 1000},
        {"verification_status": "maybe"},
        {"display_name": ""},
        {"display_name": "x" * 81},
        {"email": "x" * 255},
    ],
)
def test_check_constraints(owner_db: Conn, extra: dict[str, Any]) -> None:
    with pytest.raises(psycopg.errors.CheckViolation):
        _contact(owner_db, _user(owner_db), **extra)


def test_a_live_contact_needs_an_address_but_a_deleted_one_does_not(owner_db: Conn) -> None:
    user = _user(owner_db)
    with pytest.raises(psycopg.errors.CheckViolation):
        owner_db.execute(
            "INSERT INTO trusted_contacts (user_id, display_name, relationship) "
            "VALUES (%s, 'No address', 'friend')",
            (user,),
        )
    owner_db.execute(
        "INSERT INTO trusted_contacts (user_id, display_name, relationship, deleted_at) "
        "VALUES (%s, 'Gone', 'friend', now())",
        (user,),
    )


def test_invitations_cascade_with_their_contact_and_tokens_are_unique(owner_db: Conn) -> None:
    contact = _contact(owner_db, _user(owner_db))
    insert = (
        "INSERT INTO contact_verifications (contact_id, token_hash, expires_at, "
        "consent_text_version) VALUES (%s, %s, now() + interval '14 days', '2026-10-v1')"
    )
    owner_db.execute(insert, (contact, b"hash-1"))
    with pytest.raises(psycopg.errors.UniqueViolation):
        owner_db.execute(insert, (contact, b"hash-1"))
    with pytest.raises(psycopg.errors.ForeignKeyViolation):
        owner_db.execute(insert, ("00000000-0000-4000-8000-000000000001", b"hash-2"))
    with pytest.raises(psycopg.errors.CheckViolation):
        owner_db.execute(
            "UPDATE contact_verifications SET response = 'maybe' WHERE token_hash = %s",
            (b"hash-1",),
        )
    owner_db.execute("DELETE FROM trusted_contacts WHERE id = %s", (contact,))
    assert owner_db.execute("SELECT count(*) AS n FROM contact_verifications").fetchone() == {
        "n": 0
    }


def test_deleting_a_user_removes_their_contacts(owner_db: Conn) -> None:
    user = _user(owner_db)
    _contact(owner_db, user)
    owner_db.execute("DELETE FROM users WHERE id = %s", (user,))
    assert owner_db.execute("SELECT count(*) AS n FROM trusted_contacts").fetchone() == {"n": 0}


def test_suppressions_hold_hashes_and_known_reasons_only(owner_db: Conn) -> None:
    owner_db.execute(
        "INSERT INTO email_suppressions (email_hash, reason) VALUES (%s, 'hard_bounce')",
        (b"a" * 32,),
    )
    with pytest.raises(psycopg.errors.UniqueViolation):
        owner_db.execute(
            "INSERT INTO email_suppressions (email_hash, reason) VALUES (%s, 'complaint')",
            (b"a" * 32,),
        )
    with pytest.raises(psycopg.errors.CheckViolation):
        owner_db.execute(
            "INSERT INTO email_suppressions (email_hash, reason) VALUES (%s, 'because')",
            (b"b" * 32,),
        )
    columns = {
        r["column_name"]
        for r in owner_db.execute(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_name = 'email_suppressions'"
        ).fetchall()
    }
    assert columns == {"email_hash", "reason", "source_contact_id", "created_at"}
    foreign_keys = owner_db.execute(
        "SELECT 1 FROM pg_constraint WHERE conrelid = 'email_suppressions'::regclass "
        "AND contype = 'f'"
    ).fetchall()
    assert foreign_keys == []  # the contact ID is informational only
