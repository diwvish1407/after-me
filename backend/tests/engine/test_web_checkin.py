"""The lost-phone pages: ``/a/login``, ``/a/checkin``, ``/a/safe`` (PRD FR-CHK-07).

Same logic as the app, reached from a browser: the same lockout, the same refusal to let an
I'M OK settle an incident that has already alarmed someone, the same password for I'M SAFE.
"""

from __future__ import annotations

import re
from datetime import timedelta
from typing import Any

import httpx

from tests.engine.test_release import address
from tests.support import PASSWORD
from tests.world import Person, World, ist

DUE = ist("2026-10-09T20:00")
_CSRF_RE = re.compile(r'name="csrf" value="([^"]+)"')
_KEY_RE = re.compile(r'name="key" value="([^"]+)"')
_INCIDENT_RE = re.compile(r'name="incident_id" value="([^"]+)"')
COOKIE = "__Host-afterme_web"


async def _csrf(client: httpx.AsyncClient, path: str) -> str:
    page = await client.get(path)
    found = _CSRF_RE.search(page.text)
    assert found is not None, page.text
    return found[1]


async def _sign_in(world: World, person: Person, password: str = PASSWORD) -> httpx.Response:
    client = world.h.client
    csrf = await _csrf(client, "/a/login")
    return await client.post(
        "/a/login", data={"email": person.email, "password": password, "csrf": csrf}
    )


async def _signed_in_page(world: World, person: Person) -> httpx.Response:
    assert (await _sign_in(world, person)).status_code == 303
    page = await world.h.client.get("/a/checkin")
    assert page.status_code == 200
    return page


def _field(pattern: re.Pattern[str], page: httpx.Response) -> str:
    found = pattern.search(page.text)
    assert found is not None, page.text
    return found[1]


def _events(world: World, person: Person) -> list[dict[str, Any]]:
    return [
        dict(r)
        for r in world.db.execute(
            "SELECT kind, source, device_id, session_id FROM checkin_events WHERE user_id = %s "
            "ORDER BY received_at",
            (person.user_id,),
        ).fetchall()
    ]


# --- sign in ----------------------------------------------------------------------------------


async def test_sign_in_sets_a_host_cookie_and_tells_the_owner_by_email(world: World) -> None:
    person = await world.ready()
    wrong = await _sign_in(world, person, "not the password")
    assert wrong.status_code == 401
    assert "That email or password" in wrong.text
    assert COOKIE not in wrong.headers.get("set-cookie", "")

    ok = await _sign_in(world, person)
    assert ok.status_code == 303
    assert ok.headers["location"] == "/a/checkin"
    cookie = ok.headers["set-cookie"]
    assert cookie.startswith(f"{COOKIE}=wt_")
    for attribute in ("HttpOnly", "Secure", "SameSite=strict", "Path=/", "Max-Age=3600"):
        assert attribute.lower() in cookie.lower(), attribute

    assert len(world.mail.to(person.email, "web_login_notice")) == 1
    session = world.db.execute(
        "SELECT kind, device_id, reauthenticated_at, idle_expires_at, absolute_expires_at, "
        "web_token_hash FROM sessions WHERE user_id = %s AND kind = 'web'",
        (person.user_id,),
    ).fetchone()
    assert session is not None
    assert session["device_id"] is None
    assert session["reauthenticated_at"] == world.clock.current
    assert session["absolute_expires_at"] == world.clock.current + timedelta(hours=1)
    assert len(bytes(session["web_token_hash"])) == 32  # a hash, never the cookie value
    audit = world.db.execute(
        "SELECT user_visible FROM audit_logs WHERE action = 'auth.web_login_succeeded'"
    ).fetchone()
    assert audit == {"user_visible": True}


async def test_the_pages_need_a_session_and_a_matching_csrf_value(world: World) -> None:
    person = await world.ready()
    client = world.h.client
    for path in ("/a/checkin",):
        gone = await client.get(path)
        assert gone.status_code == 200
        assert 'action="/a/login"' in gone.text  # the sign-in form, in place of the page
    csrf = await _csrf(client, "/a/login")
    for path, data in (
        ("/a/checkin", {"key": "web-" + "a" * 20, "csrf": csrf}),
        ("/a/safe", {"key": "web-" + "a" * 20, "csrf": csrf, "password": PASSWORD}),
    ):
        no_session = await client.post(path, data=data)
        assert no_session.status_code == 401, path
        assert 'action="/a/login"' in no_session.text
    no_csrf = await client.post("/a/login", data={"email": person.email, "password": PASSWORD})
    assert no_csrf.status_code == 403
    assert (await client.post("/a/login", data={"csrf": "x" * 40})).status_code == 403
    assert _events(world, person) == []


async def test_a_session_ends_after_an_hour_and_on_sign_out(world: World) -> None:
    person = await world.ready()
    client = world.h.client
    page = await _signed_in_page(world, person)
    assert "I'M OK" in page.text

    out = await client.post("/a/logout", data={"csrf": _field(_CSRF_RE, page)})
    assert out.status_code == 200
    assert "signed out" in out.text
    assert 'action="/a/login"' in (await client.get("/a/checkin")).text
    revoked = world.db.execute(
        "SELECT revoke_reason FROM sessions WHERE user_id = %s AND kind = 'web'",
        (person.user_id,),
    ).fetchone()
    assert revoked == {"revoke_reason": "logout"}

    await _signed_in_page(world, person)
    world.clock.advance(minutes=61)
    expired = await client.get("/a/checkin")
    assert 'action="/a/login"' in expired.text
    assert "I'M OK" not in expired.text


async def test_sign_in_is_rate_limited_per_address(world: World) -> None:
    person = await world.ready()
    client = world.h.client
    statuses = []
    for _ in range(12):
        csrf = await _csrf(client, "/a/login")
        response = await client.post(
            "/a/login", data={"email": person.email, "password": "nope " * 3, "csrf": csrf}
        )
        statuses.append(response.status_code)
    assert 429 in statuses
    assert statuses[0] == 401


# --- I'M OK -----------------------------------------------------------------------------------


async def test_im_ok_from_the_web_is_one_check_in_however_often_the_form_is_sent(
    world: World,
) -> None:
    person = await world.ready()
    client = world.h.client
    page = await _signed_in_page(world, person)
    assert "Your next check-in is due" in page.text
    key = _field(_KEY_RE, page)
    csrf = _field(_CSRF_RE, page)

    first = await client.post("/a/checkin", data={"key": key, "csrf": csrf})
    assert first.status_code == 200
    assert "You're checked in" in first.text
    again = await client.post("/a/checkin", data={"key": key, "csrf": csrf})
    assert again.status_code == 200
    events = _events(world, person)
    assert len(events) == 1
    assert events[0]["kind"] == "ok"
    assert events[0]["source"] == "web"
    assert events[0]["device_id"] is None


async def test_a_missed_check_in_nobody_heard_about_is_settled_by_im_ok(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=5))
    incident = world.open_incident(person)
    assert incident is not None
    assert incident["contacts_messaged_at"] is None

    world.clock.set(world.clock.current)  # same instant; the session is created below
    page = await _signed_in_page(world, person)
    assert "You missed your check-in" in page.text
    assert "I'M SAFE" not in page.text
    done = await world.h.client.post(
        "/a/checkin", data={"key": _field(_KEY_RE, page), "csrf": _field(_CSRF_RE, page)}
    )
    assert "The missed check-in was settled" in done.text
    assert world.open_incident(person) is None
    assert world.incidents(person)[0]["closed_by"] == "user_checkin"


# --- I'M SAFE ---------------------------------------------------------------------------------


async def test_once_contacts_are_told_the_page_asks_for_im_safe_and_the_password(
    world: World,
) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=190))
    assert len(world.mail.to(address(person, "Mom"), "contact_alert")) == 1
    client = world.h.client

    page = await _signed_in_page(world, person)
    assert "Mom has been told" in page.text
    assert 'action="/a/safe"' in page.text
    assert 'action="/a/checkin"' not in page.text
    incident_id = _field(_INCIDENT_RE, page)
    key, csrf = _field(_KEY_RE, page), _field(_CSRF_RE, page)

    # an I'M OK is refused by the same rule as in the app: it is sent back to I'M SAFE
    refused = await client.post("/a/checkin", data={"key": "web-" + "b" * 24, "csrf": csrf})
    assert refused.status_code == 303
    assert world.open_incident(person) is not None

    wrong = await client.post(
        "/a/safe",
        data={"key": key, "csrf": csrf, "incident_id": incident_id, "password": "nope nope nope"},
    )
    assert wrong.status_code == 401
    assert "Nobody has been told you are safe yet" in wrong.text  # no apostrophe: not escaped
    assert world.open_incident(person) is not None

    done = await client.post(
        "/a/safe",
        data={"key": key, "csrf": csrf, "incident_id": incident_id, "password": PASSWORD},
    )
    assert done.status_code == 200, done.text
    assert "You're marked safe" in done.text
    assert "Mom" in done.text
    assert world.open_incident(person) is None
    assert world.incidents(person)[0]["closed_by"] == "user_safe"
    await world.advance(minutes=10)
    assert len(world.mail.to(address(person, "Mom"), "contact_all_clear")) == 1
    events = _events(world, person)
    assert [(e["kind"], e["source"]) for e in events] == [("safe", "web")]

    # the same form sent again is the same answer, not a second event
    again = await client.post(
        "/a/safe",
        data={"key": key, "csrf": csrf, "incident_id": incident_id, "password": PASSWORD},
    )
    assert again.status_code == 200
    assert len(_events(world, person)) == 1


async def test_im_safe_is_not_possible_for_someone_elses_incident(world: World) -> None:
    person = await world.ready()
    other = await world.ready(
        "someone.else@example.com", contacts=("Dad",), stages=((180, ("Dad",)),)
    )
    await world.advance_to(DUE + timedelta(minutes=190))
    assert world.open_incident(other) is not None
    theirs = str(world.open_incident(other)["id"])  # type: ignore[index]

    page = await _signed_in_page(world, person)
    csrf = _field(_CSRF_RE, page)
    response = await world.h.client.post(
        "/a/safe",
        data={
            "key": "web-" + "c" * 24,
            "csrf": csrf,
            "incident_id": theirs,
            "password": PASSWORD,
        },
    )
    assert response.status_code == 200  # the page, with a calm message
    assert world.open_incident(other) is not None
    assert world.open_incident(person) is not None
