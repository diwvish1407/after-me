"""Account deletion (DATABASE §4, SECURITY §10): ``DELETE /v1/me``, the public ``/a/delete`` page
and the retention job that finishes it.

The safety question is always the same: deleting an account must never leave a contact alarmed,
and must never let anything reach a contact afterwards.
"""

from __future__ import annotations

import re
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import timedelta
from typing import Any

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import Database
from app.maintenance.accounts import purge_due_accounts, scrub_settled_contacts
from tests.engine.test_release import TITLE, Portal, _link_token, _released, _setup, address
from tests.support import OWNER_URL, PASSWORD
from tests.world import Person, World, ist

DUE = ist("2026-10-09T20:00")
_LINK_RE = re.compile(r"https://afterme\.test/a/delete/confirm#(ad_[A-Za-z0-9_-]+)")
_CSRF_RE = re.compile(r'name="csrf" value="([^"]+)"')


_DEFAULT: Any = object()


async def _delete(
    world: World, person: Person, *, reauth: bool = True, body: Any = _DEFAULT
) -> Any:
    await world.login(person)
    if reauth:
        assert (await world.h.reauth(person.tokens)).status_code == 204
    return await world.h.client.request(
        "DELETE",
        "/v1/me",
        json={"confirm": "DELETE"} if body is _DEFAULT else body,
        headers=person.headers,
    )


@asynccontextmanager
async def _as_owner(world: World) -> AsyncIterator[AsyncSession]:
    """The retention job's functions, run as the real ``afterme_maintenance`` role (``SET LOCAL
    ROLE``), so its column grants and the guard triggers are exercised, not only inspected. The
    test database's owner is made a member by ``scripts/dev_db_setup.sh``; without that, the
    tests that need it are skipped with the command to run."""
    db = Database.from_settings(
        world.h.settings, application_name="test-maintenance", url=OWNER_URL
    )
    try:
        async with db.independent_session() as session:
            try:
                await session.execute(text("SET LOCAL ROLE afterme_maintenance"))
            except DBAPIError:
                pytest.skip("run backend/scripts/dev_db_setup.sh to let the owner SET ROLE")
            yield session
    finally:
        await db.dispose()


def _user(world: World, person: Person) -> dict[str, Any]:
    row = world.db.execute("SELECT * FROM users WHERE id = %s", (person.user_id,)).fetchone()
    assert row is not None
    return dict(row)


# --- the request ------------------------------------------------------------------------------


async def test_deletion_needs_a_fresh_password_and_the_word_delete(world: World) -> None:
    person = await world.ready()
    refused = await _delete(world, person, reauth=False)
    assert refused.status_code == 403
    assert refused.json()["code"] == "reauth_required"

    for bad in ({"confirm": "delete"}, {"confirm": "yes"}, {}, {"confirm": "DELETE", "x": 1}):
        response = await _delete(world, person, body=bad)
        assert response.status_code == 422, bad
    assert _user(world, person)["status"] == "active"
    assert world.config(person)["status"] == "active"


async def test_a_deleted_account_is_closed_everywhere_at_once(world: World) -> None:
    person = await _setup(world)  # contacts, plan, an instruction routed to Brother
    other = await world.ready(
        "someone.else@example.com", contacts=("Dad",), stages=((180, ("Dad",)),)
    )
    keys_before = world.db.execute("SELECT count(*) AS n FROM user_keys").fetchone()
    assert keys_before is not None
    assert keys_before["n"] == 1

    response = await _delete(world, person)
    assert response.status_code == 202, response.text
    body = response.json()
    assert body["status"] == "pending_deletion"
    assert body["purge_after"] == (world.clock.current + timedelta(days=30)).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )

    user = _user(world, person)
    assert user["status"] == "pending_deletion"
    assert user["deletion_requested_at"] == world.clock.current
    assert user["email"].startswith("deleted-")
    assert person.email not in str(user)
    assert user["password_hash"] == "!"
    assert world.config(person)["status"] == "inactive"

    # sessions end; nothing signs in again, not even with the right password
    assert (await world.h.client.get("/v1/me", headers=person.headers)).status_code == 401
    login = await world.h.login(person.email, PASSWORD)
    assert login.status_code == 401
    refresh = await world.h.refresh(person.tokens["refresh_token"])
    assert refresh.status_code == 401

    # content and key are gone, contacts scrubbed
    instruction = world.db.execute(
        "SELECT content_ciphertext, deleted_at FROM instructions WHERE user_id = %s",
        (person.user_id,),
    ).fetchone()
    assert instruction is not None
    assert instruction["content_ciphertext"] is None
    assert instruction["deleted_at"] is not None
    assert world.db.execute("SELECT 1 FROM instruction_recipients").fetchall() == []
    assert (
        world.db.execute("SELECT 1 FROM user_keys WHERE user_id = %s", (person.user_id,)).fetchall()
        == []
    )
    contacts = world.db.execute(
        "SELECT display_name, email, phone_e164, deleted_at FROM trusted_contacts "
        "WHERE user_id = %s",
        (person.user_id,),
    ).fetchall()
    assert contacts
    assert all(
        c["email"] is None
        and c["deleted_at"] is not None
        and c["display_name"] == "Deleted contact"
        for c in contacts
    )

    # the confirmation goes to the address that was on file, not to a tombstone
    notices = world.mail.to(person.email, "account_deletion_requested")
    assert len(notices) == 1
    assert "scheduled for permanent deletion" in notices[0].text

    audit = world.db.execute(
        "SELECT user_visible, actor_type, metadata FROM audit_logs "
        "WHERE action = 'account.deletion_requested'"
    ).fetchall()
    assert len(audit) == 1
    assert audit[0]["user_visible"] is False
    assert audit[0]["metadata"]["source"] == "app"

    # another account is untouched
    assert _user(world, other)["status"] == "active"
    assert world.config(other)["status"] == "active"
    assert (await world.call(other, "GET", "/v1/me")).status_code == 200


async def test_a_second_request_is_refused_like_any_signed_out_call(world: World) -> None:
    person = await world.ready()
    assert (await _delete(world, person)).status_code == 202
    again = await world.h.client.request(
        "DELETE", "/v1/me", json={"confirm": "DELETE"}, headers=person.headers
    )
    assert again.status_code == 401
    assert world.db.execute(
        "SELECT count(*) AS n FROM audit_logs WHERE action = 'account.deletion_requested'"
    ).fetchone() == {"n": 1}


# --- during an incident ----------------------------------------------------------------------


async def test_deleting_while_contacts_are_alarmed_sends_the_all_clear_and_nothing_else(
    world: World,
) -> None:
    person = await world.ready(
        contacts=("Mom", "Brother"),
        stages=((180, ("Mom",)), (1440, ("Brother",))),
    )
    await world.advance_to(DUE + timedelta(minutes=190))  # stage 1 ran: Mom was told
    assert len(world.mail.to(address(person, "Mom"), "contact_alert")) == 1
    incident = world.open_incident(person)
    assert incident is not None
    assert incident["contacts_messaged_at"] is not None

    assert (await _delete(world, person)).status_code == 202
    [closed] = world.incidents(person)
    assert closed["status"] == "voided"
    assert closed["closed_by"] == "account_deleted"
    assert world.config(person)["status"] == "inactive"

    await world.advance_to(DUE + timedelta(days=3))  # stage 2 would have been due long ago
    # Mom is told the alert is withdrawn. Nobody checked in, so the message must not say so, and
    # it must say whose alert it withdraws (the name is kept until it has left).
    assert world.mail.to(address(person, "Mom"), "contact_all_clear") == []
    [withdrawn] = world.mail.to(address(person, "Mom"), "contact_alert_withdrawn")
    assert "Deleted user" not in withdrawn.subject + withdrawn.text
    assert "Owner" in withdrawn.subject or "Test User" in withdrawn.subject
    assert "closed their AfterMe account" in withdrawn.text
    assert "not a confirmation that they are safe" in withdrawn.text
    assert "checked in" not in withdrawn.subject
    assert "confirmed they're safe" not in withdrawn.text
    assert world.mail.to(address(person, "Brother"), "contact_alert") == []
    assert world.mail.to(address(person, "Brother"), "contact_alert_withdrawn") == []
    sent = world.db.execute(
        "SELECT template_key FROM notifications WHERE user_id = %s AND status = 'sent' "
        "AND audience = 'contact'",
        (person.user_id,),
    ).fetchall()
    assert sorted(r["template_key"] for r in sent) == ["contact_alert", "contact_alert_withdrawn"]
    # no user-facing message is sent to a closed account, apart from the confirmation email
    assert world.mail.to(person.email, "incident_midpoint") == []

    # the maintenance job scrubs Mom now that nothing is waiting for her
    async with _as_owner(world) as session:
        scrubbed = await scrub_settled_contacts(session, now=world.clock.current)
    assert scrubbed == 1
    mom = world.db.execute(
        "SELECT email, deleted_at FROM trusted_contacts WHERE id = %s", (person.contacts["Mom"],)
    ).fetchone()
    assert mom is not None
    assert mom["email"] is None
    assert mom["deleted_at"] is not None


async def test_what_was_released_cannot_be_read_after_deletion(world: World) -> None:
    person = await _released(world)
    portal = Portal(world)
    assert TITLE in (await portal.reach_content(person)).text

    assert (await _delete(world, person)).status_code == 202
    revoked = world.db.execute(
        "SELECT revoked_at, revoke_reason FROM release_events WHERE user_id = %s",
        (person.user_id,),
    ).fetchall()
    assert revoked
    assert all(r["revoked_at"] is not None for r in revoked)
    # a contact who holds the link gets the generic page, and nothing of the content
    link = _link_token(world, person)
    again = await Portal(world).open(link)
    assert again.status_code == 400
    assert TITLE not in again.text
    assert "Sharma" not in again.text


# --- the retention job ------------------------------------------------------------------------


async def test_the_account_is_purged_after_thirty_days_and_not_before(world: World) -> None:
    person = await _released(world)
    other = await world.ready(
        "someone.else@example.com", contacts=("Dad",), stages=((180, ("Dad",)),)
    )
    assert (await _delete(world, person)).status_code == 202
    await world.advance(minutes=10)  # the withdrawn-alert message leaves

    async with _as_owner(world) as session:
        early = await purge_due_accounts(
            session,
            world.engine.services.audit,
            now=world.clock.current + timedelta(days=29, hours=23),
            retention_days=30,
        )
    assert early == []
    assert _user(world, person)["status"] == "pending_deletion"

    async with _as_owner(world) as session:
        removed = await purge_due_accounts(
            session,
            world.engine.services.audit,
            now=world.clock.current + timedelta(days=30, minutes=1),
            retention_days=30,
        )
    assert [str(i) for i in removed] == [person.user_id]
    for table in (
        "users",
        "user_profiles",
        "trusted_contacts",
        "instructions",
        "escalation_incidents",
        "incident_actions",
        "release_events",
        "portal_access",
        "checkin_configurations",
    ):
        column = "id" if table == "users" else "user_id"
        left = world.db.execute(
            f"SELECT count(*) AS n FROM {table} WHERE {column} = %s",  # noqa: S608 - fixed names
            (person.user_id,),
        ).fetchone()
        assert left == {"n": 0}, table
    assert _user(world, other)["status"] == "active"
    purged = world.db.execute(
        "SELECT subject_user_id, actor_type FROM audit_logs WHERE action = 'account.purged'"
    ).fetchall()
    assert [str(r["subject_user_id"]) for r in purged] == [person.user_id]
    # the audit history of the closed account stays, pseudonymously
    kept = world.db.execute(
        "SELECT count(*) AS n FROM audit_logs WHERE subject_user_id = %s", (person.user_id,)
    ).fetchone()
    assert kept is not None
    assert kept["n"] > 3


async def test_the_purge_leaves_active_accounts_alone_whatever_their_age(world: World) -> None:
    person = await world.ready()
    async with _as_owner(world) as session:
        removed = await purge_due_accounts(
            session,
            world.engine.services.audit,
            now=world.clock.current + timedelta(days=4000),
            retention_days=30,
        )
    assert removed == []
    assert _user(world, person)["status"] == "active"


# --- the public page --------------------------------------------------------------------------


async def _form_csrf(world: World, path: str) -> str:
    response = await world.h.client.get(path)
    assert response.status_code == 200
    found = _CSRF_RE.search(response.text)
    assert found is not None
    return found[1]


async def test_the_web_page_deletes_with_an_emailed_link_and_the_password(world: World) -> None:
    person = await world.ready()
    client = world.h.client

    csrf = await _form_csrf(world, "/a/delete")
    asked = await client.post("/a/delete", data={"email": person.email, "csrf": csrf})
    assert asked.status_code == 200
    assert "If that address belongs to an AfterMe account" in asked.text
    [mail] = world.mail.to(person.email, "account_deletion_link")
    found = _LINK_RE.search(mail.text)
    assert found is not None
    token = found[1]
    assert _user(world, person)["status"] == "active"  # a link alone deletes nothing

    csrf = await _form_csrf(world, "/a/delete/confirm")
    wrong = await client.post(
        "/a/delete/confirm", data={"token": token, "password": "not it", "csrf": csrf}
    )
    assert wrong.status_code == 401
    assert _user(world, person)["status"] == "active"

    right = await client.post(
        "/a/delete/confirm", data={"token": token, "password": PASSWORD, "csrf": csrf}
    )
    assert right.status_code == 200, right.text
    assert "Your account has been closed" in right.text
    assert _user(world, person)["status"] == "pending_deletion"
    assert world.config(person)["status"] == "inactive"
    row = world.db.execute(
        "SELECT metadata FROM audit_logs WHERE action = 'account.deletion_requested'"
    ).fetchone()
    assert row is not None
    assert row["metadata"]["source"] == "web"

    # the link works once
    csrf = await _form_csrf(world, "/a/delete/confirm")
    reused = await client.post(
        "/a/delete/confirm", data={"token": token, "password": PASSWORD, "csrf": csrf}
    )
    assert reused.status_code == 400


async def test_the_web_page_answers_the_same_for_every_address(world: World) -> None:
    person = await world.ready()
    client = world.h.client
    csrf = await _form_csrf(world, "/a/delete")
    known = await client.post("/a/delete", data={"email": person.email, "csrf": csrf})
    csrf = await _form_csrf(world, "/a/delete")
    unknown = await client.post("/a/delete", data={"email": "nobody@example.com", "csrf": csrf})
    assert known.status_code == unknown.status_code == 200
    assert known.text.replace(csrf, "") == unknown.text.replace(csrf, "")
    assert world.mail.to("nobody@example.com", "account_deletion_link") == []


async def test_the_web_page_refuses_a_missing_csrf_and_a_bad_token(world: World) -> None:
    person = await world.ready()
    client = world.h.client
    no_csrf = await client.post("/a/delete", data={"email": person.email})
    assert no_csrf.status_code == 403
    assert world.mail.to(person.email, "account_deletion_link") == []

    csrf = await _form_csrf(world, "/a/delete/confirm")
    for token in ("", "ad_short", "pr_" + "A" * 43, "ad_" + "A" * 43):
        bad = await client.post(
            "/a/delete/confirm", data={"token": token, "password": PASSWORD, "csrf": csrf}
        )
        assert bad.status_code == 400, token
    assert _user(world, person)["status"] == "active"


async def test_an_account_is_not_purged_while_its_alert_withdrawal_is_still_waiting(
    world: World,
) -> None:
    person = await _released(world)  # Brother was alerted
    assert (await _delete(world, person)).status_code == 202
    waiting = world.db.execute(
        "SELECT template_key, status FROM notifications WHERE user_id = %s AND status = 'queued' "
        "AND audience = 'contact'",
        (person.user_id,),
    ).fetchall()
    # Mom (stage 1) and Brother (stage 2, with the release) were both told: both are withdrawn
    assert [r["template_key"] for r in waiting] == ["contact_alert_withdrawn"] * 2

    # the dispatcher has been down for longer than the retention: the message is still there
    async with _as_owner(world) as session:
        removed = await purge_due_accounts(
            session,
            world.engine.services.audit,
            now=world.clock.current + timedelta(days=45),
            retention_days=30,
        )
    assert removed == []
    assert _user(world, person)["status"] == "pending_deletion"

    # once it has left, the account goes, and the contact has been told
    await world.advance(minutes=10)
    assert len(world.mail.to(address(person, "Brother"), "contact_alert_withdrawn")) == 1
    async with _as_owner(world) as session:
        removed = await purge_due_accounts(
            session,
            world.engine.services.audit,
            now=world.clock.current + timedelta(days=45),
            retention_days=30,
        )
    assert [str(i) for i in removed] == [person.user_id]


async def test_the_name_is_kept_for_the_message_and_scrubbed_after_it(world: World) -> None:
    person = await _released(world)
    assert (await _delete(world, person)).status_code == 202
    name = world.db.execute(
        "SELECT display_name FROM user_profiles WHERE user_id = %s", (person.user_id,)
    ).fetchone()
    assert name is not None
    assert name["display_name"] != "Deleted user"
    await world.advance(minutes=10)
    async with _as_owner(world) as session:
        await scrub_settled_contacts(session, now=world.clock.current)
    after = world.db.execute(
        "SELECT display_name, phone_e164, country_code FROM user_profiles WHERE user_id = %s",
        (person.user_id,),
    ).fetchone()
    assert after == {"display_name": "Deleted user", "phone_e164": None, "country_code": None}


async def test_a_request_that_was_already_running_cannot_act_on_a_closed_account(
    world: World,
) -> None:
    """The race the other tests cannot reach: a request past authentication, waiting on the
    per-user lock while the deletion commits, then proceeding with its stale view of the
    account (``CurrentUser.status`` says ``active``)."""
    from app.api.deps import CurrentUser
    from app.contacts.schemas import ContactCreateRequest
    from app.contacts.service import ContactService
    from app.core.errors import SessionRevoked
    from app.instructions.schemas import InstructionCreateRequest
    from app.instructions.service import InstructionService

    person = await world.ready()
    await world.login(person)
    stale = CurrentUser(
        user_id=uuid.UUID(person.user_id),
        session_id=uuid.uuid4(),
        device_id=None,
        email=person.email,
        tier="premium",
        status="active",
        reauthenticated_at=world.clock.current,
    )
    assert (await _delete(world, person)).status_code == 202
    sent_before = len(world.mail.messages)

    services = world.h.app.state.services
    async with services.db.sessionmaker() as session:
        contacts = ContactService(session=session, services=services, ctx=_ctx())
        with pytest.raises(SessionRevoked):
            await contacts.create(
                stale,
                ContactCreateRequest(
                    display_name="Late", relationship="friend", email="late@example.com"
                ),
            )
    async with services.db.sessionmaker() as session:
        instructions = InstructionService(session=session, services=services, ctx=_ctx())
        with pytest.raises(SessionRevoked):
            await instructions.create(
                stale, InstructionCreateRequest(category="home", title="Late", body="Late")
            )
    assert len(world.mail.messages) == sent_before
    assert world.db.execute(
        "SELECT count(*) AS n FROM trusted_contacts WHERE email = 'late@example.com'"
    ).fetchone() == {"n": 0}
    assert world.db.execute(
        "SELECT count(*) AS n FROM user_keys WHERE user_id = %s", (person.user_id,)
    ).fetchone() == {"n": 0}


def _ctx() -> Any:
    from app.api.deps import RequestContext

    return RequestContext(
        request_id="test", client_ip="203.0.113.10", ip_hash=b"x", user_agent=None, scope={}
    )


async def test_the_database_refuses_a_new_contact_or_instruction_for_a_closed_account(
    world: World,
) -> None:
    """Defence in depth under the service checks: the API role cannot create anything for an
    account that is not active, whatever the code above it does."""
    person = await world.ready()
    assert (await _delete(world, person)).status_code == 202
    services = world.h.app.state.services
    async with services.db.sessionmaker() as session:
        for statement in (
            "INSERT INTO trusted_contacts (user_id, display_name, relationship, email, "
            "email_normalized) "
            "VALUES (:u, 'Late', 'friend', 'late@example.com', 'late@example.com')",
            "INSERT INTO user_keys (user_id, wrapped_dek, kek_id) VALUES (:u, '\\x00', 'local-x')",
        ):
            with pytest.raises(DBAPIError, match="not active"):
                async with session.begin_nested():
                    await session.execute(text(statement), {"u": person.user_id})


async def test_the_retention_role_cannot_delete_an_account_that_was_not_closed(
    world: World,
) -> None:
    """Defence in depth under :func:`purge_due_accounts`: even a mistaken statement run as the
    retention role removes nothing but a closed account."""
    person = await world.ready()
    async with _as_owner(world) as session:
        with pytest.raises(DBAPIError, match="only a closed account"):
            await session.execute(text("DELETE FROM users WHERE id = :u"), {"u": person.user_id})
    assert _user(world, person)["status"] == "active"


async def test_a_confirmation_older_than_a_minute_does_not_delete_an_account(
    world: World,
) -> None:
    person = await world.ready()
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    world.clock.advance(seconds=61)
    late = await world.h.client.request(
        "DELETE", "/v1/me", json={"confirm": "DELETE"}, headers=person.headers
    )
    assert late.status_code == 403
    assert late.json()["code"] == "reauth_required"
    assert _user(world, person)["status"] == "active"


async def test_nothing_personal_is_left_in_tokens_and_old_links_die_with_a_password_change(
    world: World,
) -> None:
    person = await world.ready()
    client = world.h.client
    # a delete link, then a password change: the link must not outlive the credential
    csrf = await _form_csrf(world, "/a/delete")
    await client.post("/a/delete", data={"email": person.email, "csrf": csrf})
    [mail] = world.mail.to(person.email, "account_deletion_link")
    old_token = _LINK_RE.search(mail.text)[1]  # type: ignore[index]
    await world.login(person)
    changed = await client.post(
        "/v1/auth/password/change",
        json={"current_password": PASSWORD, "new_password": "a brand new passphrase 77"},
        headers=person.headers,
    )
    assert changed.status_code == 204, changed.text
    csrf = await _form_csrf(world, "/a/delete/confirm")
    dead = await client.post(
        "/a/delete/confirm",
        data={"token": old_token, "password": "a brand new passphrase 77", "csrf": csrf},
    )
    assert dead.status_code == 400

    # a pending email change carries the new address: deletion drops it
    person.tokens = await world.h.relogin(person.email, "a brand new passphrase 77")
    assert (await world.h.reauth(person.tokens, "a brand new passphrase 77")).status_code == 204
    started = await client.post(
        "/v1/auth/email/change/start",
        json={"new_email": "someone.new@example.com"},
        headers=person.headers,
    )
    assert started.status_code == 202, started.text
    pending = world.db.execute(
        "SELECT payload FROM auth_tokens WHERE user_id = %s AND purpose = 'email_change'",
        (person.user_id,),
    ).fetchall()
    assert any(p["payload"] for p in pending)
    assert (await world.h.reauth(person.tokens, "a brand new passphrase 77")).status_code == 204
    done = await client.request(
        "DELETE", "/v1/me", json={"confirm": "DELETE"}, headers=person.headers
    )
    assert done.status_code == 202, done.text
    left = world.db.execute(
        "SELECT payload FROM auth_tokens WHERE user_id = %s", (person.user_id,)
    ).fetchall()
    assert all(r["payload"] is None for r in left)
    assert "someone.new@example.com" not in str(
        world.db.execute("SELECT * FROM auth_tokens").fetchall()
    )


async def test_asking_for_another_link_does_not_cancel_the_first(world: World) -> None:
    """A stranger who knows an address must not be able to keep its owner's link from working."""
    person = await world.ready()
    client = world.h.client
    for _ in range(2):
        csrf = await _form_csrf(world, "/a/delete")
        await client.post("/a/delete", data={"email": person.email, "csrf": csrf})
    first, second = world.mail.to(person.email, "account_deletion_link")
    token = _LINK_RE.search(first.text)[1]  # type: ignore[index]
    assert _LINK_RE.search(second.text) is not None
    csrf = await _form_csrf(world, "/a/delete/confirm")
    done = await client.post(
        "/a/delete/confirm", data={"token": token, "password": PASSWORD, "csrf": csrf}
    )
    assert done.status_code == 200
