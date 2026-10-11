"""SEC-13: with a valid session, a POST without the CSRF pair changes nothing (TEST_PLAN §5.2).

The matrix (``test_authorization_matrix.py``) proves every web POST refuses a missing or wrong
CSRF value, but it has no session, so it cannot show that CSRF protects an *authenticated*
action. These tests hold a real web session (``/a/login``) or a real portal session
(``/c/release``) and send each state-changing POST with every way of getting the pair wrong.
Each refusal must be a 403 and leave every table as it was; the same POST with the right pair
then does change state (so the 403 is the CSRF check's doing, not a dead route).
"""

from __future__ import annotations

import re
from datetime import timedelta

import httpx
import pytest

from app.releases.portal_service import SESSION_COOKIE as PORTAL_COOKIE
from app.web.account_session import WEB_COOKIE
from app.web.security import CSRF_COOKIE
from tests.engine.test_release import Portal, _link_token, _released, address
from tests.engine.test_web_checkin import _sign_in
from tests.security.sec_support import assert_unchanged, csrf_of, snapshot
from tests.support import CLIENT_IP, PASSWORD
from tests.world import Person, World, ist

DUE = ist("2026-10-09T20:00")
HOST = "api.afterme.test"
KEY_RE = re.compile(r'name="key" value="([^"]+)"')
INCIDENT_RE = re.compile(r'name="incident_id" value="([^"]+)"')

# Every way a request can fail to carry a matching pair. "valid" is the control.
VARIANTS = ("missing", "empty", "wrong", "query_only", "no_cookie", "other_cookie", "json")


async def _attempt(
    world: World,
    path: str,
    variant: str,
    *,
    cookies: dict[str, str],
    csrf: str,
    data: dict[str, str] | None = None,
) -> httpx.Response:
    """POST ``data`` as a browser holding ``cookies`` (the session) and a CSRF cookie, with the
    form field wrong in the way ``variant`` says. A fresh jar each time, so nothing carries over."""
    jar = httpx.Cookies()
    for name, value in cookies.items():
        jar.set(name, value, domain=HOST, path="/")
    if variant != "no_cookie":
        jar.set(CSRF_COOKIE, "Z" * 43 if variant == "other_cookie" else csrf, domain=HOST, path="/")
    form = dict(data or {})
    params = None
    if variant == "wrong":
        form["csrf"] = "A" * 43
    elif variant == "empty":
        form["csrf"] = ""
    elif variant == "query_only":
        params = {"csrf": csrf}  # in the URL, not in the form
    elif variant != "missing":
        form["csrf"] = csrf  # no_cookie, other_cookie, json, valid
    transport = httpx.ASGITransport(app=world.h.app, client=(CLIENT_IP, 51000))
    async with httpx.AsyncClient(
        transport=transport, base_url=f"https://{HOST}", cookies=jar
    ) as browser:
        if variant == "json":
            return await browser.post(path, json=form)
        return await browser.post(path, data=form, params=params)


async def _refused_every_way(
    world: World,
    path: str,
    *,
    cookies: dict[str, str],
    csrf: str,
    data: dict[str, str] | None = None,
) -> None:
    before = snapshot(world.db)
    mail_before = len(world.mail.messages)
    for variant in VARIANTS:
        response = await _attempt(world, path, variant, cookies=cookies, csrf=csrf, data=data)
        assert response.status_code == 403, (path, variant, response.status_code)
        assert "text/html" in response.headers["content-type"]
        assert_unchanged(before, snapshot(world.db), f"POST {path} ({variant})")
    assert len(world.mail.messages) == mail_before


def _web_cookies(world: World) -> dict[str, str]:
    token = world.h.client.cookies.get(WEB_COOKIE)
    assert token, "not signed in"
    return {WEB_COOKIE: token}


def _events(world: World, person: Person) -> int:
    row = world.db.execute(
        "SELECT count(*) AS n FROM checkin_events WHERE user_id = %s", (person.user_id,)
    ).fetchone()
    assert row is not None
    return int(row["n"])


# --- the lost-phone pages ------------------------------------------------------------------------


async def test_im_ok_from_a_signed_in_browser_needs_the_csrf_pair(world: World) -> None:
    person = await world.ready()
    assert (await _sign_in(world, person)).status_code == 303
    page = await world.h.client.get("/a/checkin")
    csrf, key = csrf_of(page), KEY_RE.search(page.text)
    assert key is not None
    cookies = _web_cookies(world)
    events = _events(world, person)

    await _refused_every_way(world, "/a/checkin", cookies=cookies, csrf=csrf, data={"key": key[1]})
    assert _events(world, person) == events  # no check-in was recorded

    # the same request with the pair does record it
    done = await _attempt(
        world, "/a/checkin", "valid", cookies=cookies, csrf=csrf, data={"key": key[1]}
    )
    assert done.status_code == 200, done.text
    assert _events(world, person) == events + 1


async def test_im_safe_from_a_signed_in_browser_needs_the_csrf_pair(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=190))  # Mom has been told
    assert world.open_incident(person) is not None
    assert (await _sign_in(world, person)).status_code == 303
    page = await world.h.client.get("/a/checkin")
    csrf = csrf_of(page)
    key, incident = KEY_RE.search(page.text), INCIDENT_RE.search(page.text)
    assert key is not None
    assert incident is not None
    cookies = _web_cookies(world)
    form = {"key": key[1], "incident_id": incident[1], "password": PASSWORD}

    await _refused_every_way(world, "/a/safe", cookies=cookies, csrf=csrf, data=form)
    assert world.open_incident(person) is not None  # still open, nobody was told it is safe
    assert world.db.execute("SELECT count(*) AS n FROM checkin_events").fetchone() == {"n": 0}

    done = await _attempt(world, "/a/safe", "valid", cookies=cookies, csrf=csrf, data=form)
    assert done.status_code == 200, done.text
    assert world.open_incident(person) is None
    assert world.db.execute(
        "SELECT count(*) AS n FROM checkin_events WHERE kind = 'safe'"
    ).fetchone() == {"n": 1}


async def test_sign_out_from_a_signed_in_browser_needs_the_csrf_pair(world: World) -> None:
    """Without the pair a cross-site form could sign the person out of the one page they have
    when the phone is gone."""
    person = await world.ready()
    assert (await _sign_in(world, person)).status_code == 303
    csrf = csrf_of(await world.h.client.get("/a/checkin"))
    cookies = _web_cookies(world)

    await _refused_every_way(world, "/a/logout", cookies=cookies, csrf=csrf)
    still = await world.h.client.get("/a/checkin")
    assert "I'M OK" in still.text  # the session is alive
    live = world.db.execute(
        "SELECT count(*) AS n FROM sessions WHERE user_id = %s AND kind = 'web' "
        "AND revoked_at IS NULL",
        (person.user_id,),
    ).fetchone()
    assert live == {"n": 1}

    done = await _attempt(world, "/a/logout", "valid", cookies=cookies, csrf=csrf)
    assert done.status_code == 200
    assert world.db.execute(
        "SELECT count(*) AS n FROM sessions WHERE user_id = %s AND kind = 'web' "
        "AND revoked_at IS NULL",
        (person.user_id,),
    ).fetchone() == {"n": 0}


# --- the recipient portal ------------------------------------------------------------------------


@pytest.mark.no_rate_limit
async def test_every_portal_post_needs_the_csrf_pair_with_a_live_portal_session(
    world: World,
) -> None:
    person = await _released(world)
    token = _link_token(world, person)
    brother = address(person, "Brother")
    portal = Portal(world)
    csrf = await portal.csrf()

    # /c/release/session: the link is exchanged for a session only with the pair
    await _refused_every_way(
        world, "/c/release/session", cookies={}, csrf=csrf, data={"token": token}
    )
    assert world.db.execute("SELECT count(*) AS n FROM portal_sessions").fetchone() == {"n": 0}
    assert (await portal.open(token)).status_code == 200
    cookie = world.h.client.cookies.get(PORTAL_COOKIE)
    assert cookie
    cookies = {PORTAL_COOKIE: cookie}

    # /c/release/code: a one-time code goes out only with the pair
    await _refused_every_way(world, "/c/release/code", cookies=cookies, csrf=csrf)
    assert world.mail.to(brother, "portal_code") == []
    assert world.db.execute("SELECT count(*) AS n FROM portal_otp_challenges").fetchone() == {
        "n": 0
    }
    assert (await portal.code()).status_code == 200
    code = portal.last_code(person)

    # /c/release/verify: even the right code does nothing without the pair
    await _refused_every_way(
        world, "/c/release/verify", cookies=cookies, csrf=csrf, data={"code": code}
    )
    challenge = world.db.execute(
        "SELECT attempts, consumed_at FROM portal_otp_challenges ORDER BY created_at DESC LIMIT 1"
    ).fetchone()
    assert challenge == {"attempts": 0, "consumed_at": None}
    assert (await portal.verify(code)).status_code == 200  # content, with the pair

    # /c/release/view: reading is recorded, so it is a POST that needs the pair
    views = world.db.execute("SELECT view_count FROM release_events").fetchone()
    assert views is not None
    await _refused_every_way(world, "/c/release/view", cookies=cookies, csrf=csrf)
    assert world.db.execute("SELECT view_count FROM release_events").fetchone() == views
    assert (await portal.post("/c/release/view")).status_code == 200
    after = world.db.execute("SELECT view_count FROM release_events").fetchone()
    assert after is not None
    assert after["view_count"] == views["view_count"] + 1

    # /c/release/new-link: nobody can have a link mailed on the strength of a cross-site form
    await _refused_every_way(
        world, "/c/release/new-link", cookies=cookies, csrf=csrf, data={"token": token}
    )
    queued = world.db.execute(
        "SELECT count(*) AS n FROM notifications WHERE template_key = 'contact_release'"
    ).fetchone()
    assert queued == {"n": 0}

    # /c/release/end: the session survives a forged "end"
    await _refused_every_way(world, "/c/release/end", cookies=cookies, csrf=csrf)
    alive = world.db.execute(
        "SELECT count(*) AS n FROM portal_sessions WHERE revoked_at IS NULL"
    ).fetchone()
    assert alive == {"n": 1}
    ended = await portal.post("/c/release/end")
    assert ended.status_code == 200
    gone = world.db.execute(
        "SELECT count(*) AS n FROM portal_sessions WHERE revoked_at IS NULL"
    ).fetchone()
    assert gone == {"n": 0}
