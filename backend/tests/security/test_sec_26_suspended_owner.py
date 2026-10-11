"""SEC-26: an operator can suspend an account, and a suspended account's contacts hear nothing
more (SECURITY §13: ``users.status = 'suspended'`` "stops all contact-facing actions";
TEST_PLAN §5.2).

``test_incidents.py`` proves no incident opens for a suspended owner and ``test_invariants.py``
that a stage already pending is cancelled without an alert. This covers the other doors a
suspension has to shut, each next to an active account that goes on as before (so a refusal
cannot be an artefact of the scenario):

* a message that is already queued for a contact is cancelled, as ``account_inactive``;
* the person's own pre-deadline reminder is not sent;
* the recipient portal: link, session, one-time code, content and "send me a new link";
* the web check-in page's cookie, and signing in there;
* a bearer token that was valid a minute ago.

Not asserted, on purpose: what happens to an *all-clear* or a *withdrawn* notice for an alert
that went out before the suspension. SECURITY §13 says "all contact-facing actions"; the
dispatcher lets an undoing message through so that a contact is not left with a false alarm
(``dispatcher.py`` ``_recheck_contact_other``). Which of the two is intended is an open question
for the owner of the document, and a test would only be guessing.
"""

from __future__ import annotations

from datetime import timedelta

import pytest

from tests.engine.test_release import TITLE, Portal, _link_token, _released, address
from tests.engine.test_web_checkin import _CSRF_RE, _KEY_RE, _field, _sign_in
from tests.security.sec_support import changed_tables, snapshot
from tests.security.test_sec_12_cross_incident_portal import Browser
from tests.support import PASSWORD, bearer, problem
from tests.world import Person, World, ist

DUE = ist("2026-10-09T20:00")
STAGE_1 = DUE + timedelta(minutes=180)


def _suspend(world: World, person: Person) -> None:
    world.db.execute("UPDATE users SET status = 'suspended' WHERE id = %s", (person.user_id,))


async def test_a_message_already_queued_for_a_contact_is_cancelled_not_sent(
    world: World,
) -> None:
    suspended = await world.ready("suspended@example.com")
    carrying_on = await world.ready("active@example.com")
    await world.advance_to(STAGE_1 + timedelta(seconds=20))
    for person in (suspended, carrying_on):  # both alerts wait out the settle delay
        [alert] = world.notifications(person, template_key="contact_alert")
        assert alert["status"] == "queued"

    _suspend(world, suspended)
    await world.advance(minutes=10)

    [alert] = world.notifications(suspended, template_key="contact_alert")
    assert alert["status"] == "cancelled"
    assert alert["cancelled_reason"] == "account_inactive"
    assert world.mail.to(address(suspended, "Mom"), "contact_alert") == []
    incident = world.incidents(suspended)[0]
    assert incident["contacts_messaged_at"] is None  # nobody was told, so nothing is owed
    # the control: the account next to it carried on and its contact was told
    assert len(world.mail.to(address(carrying_on, "Mom"), "contact_alert")) == 1
    [sent] = world.notifications(carrying_on, template_key="contact_alert")
    assert sent["status"] == "sent"


async def test_a_suspended_owner_gets_no_pre_deadline_reminder(world: World) -> None:
    suspended = await world.ready("suspended@example.com")
    carrying_on = await world.ready("active@example.com")
    _suspend(world, suspended)

    await world.advance_to(DUE - timedelta(minutes=30))  # past the 60-minute reminder lead

    assert world.notifications(suspended, template_key="checkin_pre_reminder") == []
    assert world.mail.to(suspended.email, "checkin_pre_reminder") == []
    # the control: the same schedule, the same minute, an active account was reminded
    assert len(world.mail.to(carrying_on.email, "checkin_pre_reminder")) == 1


async def test_the_recipient_portal_shuts_every_door_for_a_suspended_owner(world: World) -> None:
    person = await _released(world)
    brother = address(person, "Brother")
    link = _link_token(world, person)
    reading = Browser(world)  # somebody who is already in: session, code, content
    arriving = Browser(world)  # somebody who has only the link
    try:
        content = await reading.enter(link, person)
        assert content.status_code == 200
        assert TITLE in content.text  # the control: before the suspension it opens
        code_before = reading.last_code(person)

        _suspend(world, person)
        await world.tick()
        before = snapshot(world.db)
        mail_before = len(world.mail.messages)

        # a session that was open and past its code step shows nothing now ...
        again = await reading.post("/c/release/view")
        assert again.status_code == 400
        assert TITLE not in again.text
        assert "Sharma" not in again.text
        # ... asks for no new code (and so sends none) ...
        asked = await reading.code()
        assert asked.status_code == 400
        # ... and the code it already had does not open anything either
        verified = await reading.verify(code_before)
        assert TITLE not in verified.text
        assert verified.status_code == 400

        # the link itself opens no session
        opened = await arriving.open(link)
        assert opened.status_code == 400
        assert TITLE not in opened.text
        no_session = await arriving.code()
        assert no_session.status_code == 400

        # and a fresh link cannot be asked for: the page answers as always, nothing is queued
        asked_again = await Portal(world).post("/c/release/new-link", token=link)
        assert asked_again.status_code == 200
        await world.tick()
        assert world.mail.to(brother, "contact_release") == []

        assert len(world.mail.messages) == mail_before  # not one email left the system
        # what changed: the refusals are on the account holder's record, and nothing else
        # (no session, no challenge, no view, no notification)
        changed = changed_tables(before, snapshot(world.db))
        assert all(table.startswith("audit_logs") for table in changed), changed
        views = world.db.execute("SELECT sum(view_count) AS n FROM release_events").fetchone()
        assert views is not None
        assert views["n"] == 1  # the one read before the suspension
        challenges = world.db.execute("SELECT count(*) AS n FROM portal_otp_challenges").fetchone()
        assert challenges == {"n": 1}
        sessions = world.db.execute("SELECT count(*) AS n FROM portal_sessions").fetchone()
        assert sessions == {"n": 1}
    finally:
        await reading.close()
        await arriving.close()


async def test_a_suspended_owner_cannot_use_the_web_pages_with_a_cookie_or_a_password(
    world: World,
) -> None:
    person = await world.ready()
    assert (await _sign_in(world, person)).status_code == 303
    client = world.h.client
    page = await client.get("/a/checkin")
    assert "I'M OK" in page.text  # the control: signed in

    csrf, key = _field(_CSRF_RE, page), _field(_KEY_RE, page)

    _suspend(world, person)

    gone = await client.get("/a/checkin")
    assert "I'M OK" not in gone.text
    assert 'action="/a/login"' in gone.text  # the sign-in form, as for no cookie at all
    refused = await client.post("/a/checkin", data={"key": key, "csrf": csrf})
    assert refused.status_code == 401
    events = world.db.execute("SELECT count(*) AS n FROM checkin_events").fetchone()
    assert events == {"n": 0}  # nothing was recorded

    # and the password no longer buys a session: the same answer as a wrong password
    sessions_before = world.db.execute(
        "SELECT count(*) AS n FROM sessions WHERE user_id = %s", (person.user_id,)
    ).fetchone()
    again = await _sign_in(world, person, PASSWORD)
    assert again.status_code == 401
    assert "That email or password" in again.text
    assert "__Host-afterme_web" not in again.headers.get("set-cookie", "")
    sessions_after = world.db.execute(
        "SELECT count(*) AS n FROM sessions WHERE user_id = %s", (person.user_id,)
    ).fetchone()
    assert sessions_after == sessions_before


@pytest.mark.no_rate_limit
async def test_a_bearer_token_from_before_the_suspension_stops_working(world: World) -> None:
    person = await world.ready()
    headers = bearer(person.tokens)
    for method, path in (("GET", "/v1/me"), ("GET", "/v1/home"), ("GET", "/v1/contacts")):
        ok = await world.h.client.request(method, path, headers=headers)
        assert ok.status_code == 200, path  # the control

    _suspend(world, person)

    for method, path in (
        ("GET", "/v1/me"),
        ("GET", "/v1/home"),
        ("GET", "/v1/contacts"),
        ("POST", "/v1/checkins"),
        ("POST", "/v1/auth/reauth"),
    ):
        response = await world.h.client.request(
            method,
            path,
            headers={**headers, "Idempotency-Key": "sec26-suspended-key-0001"},
            json={"password": PASSWORD} if path.endswith("reauth") else None,
        )
        assert response.status_code == 401, (path, response.status_code)
        assert problem(response)["code"] == "session_revoked"
    refreshed = await world.h.refresh(person.tokens["refresh_token"])
    assert refreshed.status_code == 401
    login = await world.h.login(person.email)
    assert login.status_code == 401  # the password is not enough either
    assert world.db.execute("SELECT count(*) AS n FROM checkin_events").fetchone() == {"n": 0}
