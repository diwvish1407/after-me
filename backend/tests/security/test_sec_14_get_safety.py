"""SEC-14: a GET changes no state (TEST_PLAN §5.2; ARCHITECTURE §6 "GET never changes state").

A GET can be sent by anything that can make a browser load a URL (an image, a link preview, a
prefetch, an email scanner that follows every link), so it must be safe whoever's cookie rides
with it. The matrix's own GET test sends no cookie and snapshots nine tables. These tests send
each GET

* as a signed-in owner (web session cookie), as a contact in the middle of a release (portal
  session past its code step), with both cookies, and with none, and with the link's secret
  pasted into the query string, and
* for the API, as the owner after a released incident,

and compare **every** table before and after.
"""

from __future__ import annotations

import re
from datetime import timedelta

import httpx
import pytest

from app.releases.portal_service import SESSION_COOKIE as PORTAL_COOKIE
from app.web.account_session import WEB_COOKIE
from tests.engine.test_release import _link_token, _released
from tests.engine.test_web_checkin import _sign_in
from tests.security.sec_support import changed_tables, snapshot
from tests.security.test_authorization_matrix import ROUTE_POLICY, Public, Web
from tests.security.test_sec_12_cross_incident_portal import Browser
from tests.support import CLIENT_IP
from tests.world import World

WEB_GETS = sorted(
    path
    for (method, path), policy in ROUTE_POLICY.items()
    if method == "GET" and isinstance(policy, Web)
)


def _client(world: World, cookies: dict[str, str]) -> httpx.AsyncClient:
    jar = httpx.Cookies()
    for name, value in cookies.items():
        jar.set(name, value, domain="api.afterme.test", path="/")
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(app=world.h.app, client=(CLIENT_IP, 51000)),
        base_url="https://api.afterme.test",
        cookies=jar,
    )


def test_every_registered_web_get_is_in_the_sweep() -> None:
    assert "/a/checkin" in WEB_GETS
    assert "/c/release" in WEB_GETS
    assert "/a/assets/web.css" in WEB_GETS
    assert len(WEB_GETS) >= 9


async def test_a_get_of_any_web_page_changes_nothing_for_any_cookie(world: World) -> None:
    person = await _released(world)
    link = _link_token(world, person)

    # a contact who has the link, the code and the content open ...
    visitor = Browser(world)
    try:
        shown = await visitor.enter(link, person)
        assert shown.status_code == 200
        portal_cookie = visitor.client.cookies.get(PORTAL_COOKIE)
        assert portal_cookie
    finally:
        await visitor.close()
    # ... and the owner, signed in on the web
    assert (await _sign_in(world, person)).status_code == 303
    web_cookie = world.h.client.cookies.get(WEB_COOKIE)
    assert web_cookie

    cookie_sets = {
        "nobody": {},
        "owner (web session)": {WEB_COOKIE: web_cookie},
        "contact (portal session)": {PORTAL_COOKIE: portal_cookie},
        "both": {WEB_COOKIE: web_cookie, PORTAL_COOKIE: portal_cookie},
    }
    # the secrets of the links, where a naive handler might look for them
    query = f"?token={link}&csrf={'A' * 43}&code=123456&key=web-{'b' * 24}&incident_id=x"
    for who, cookies in cookie_sets.items():
        async with _client(world, cookies) as browser:
            for path in WEB_GETS:
                for suffix in ("", query):
                    before = snapshot(world.db)
                    for _ in range(2):  # twice: a retried or prefetched GET is no different
                        response = await browser.get(path + suffix)
                        assert response.status_code == 200, (who, path, response.status_code)
                    changed = changed_tables(before, snapshot(world.db))
                    assert not changed, f"GET {path}{suffix[:6]} as {who} changed {changed}"
    # what each page showed to whom is not the question here, but a cookie must not have been
    # *spent*: the portal session and the web session both still work
    async with _client(world, {PORTAL_COOKIE: portal_cookie}) as visitor_again:
        assert (await visitor_again.get("/c/release")).status_code == 200
    page = await world.h.client.get("/a/checkin")
    assert "I'M" in page.text


async def test_the_pages_that_read_state_show_it_without_touching_it(world: World) -> None:
    """``GET /a/checkin`` reads the account's schedule and open incident to draw itself. With an
    incident open and a release made, that is the most it could touch."""
    person = await _released(world)
    assert (await _sign_in(world, person)).status_code == 303
    before = snapshot(world.db)
    page = await world.h.client.get("/a/checkin")
    assert page.status_code == 200
    assert re.search(r'action="/a/safe"', page.text)  # it knows the incident is open
    world.clock.advance(minutes=3)  # time passing is not a write either
    assert (await world.h.client.get("/a/checkin")).status_code == 200
    assert not changed_tables(before, snapshot(world.db))


# --- the API ---------------------------------------------------------------------------------

# Reading an instruction decrypts it and is audited by design (``instruction.viewed``): the one
# write a GET is allowed to make, and only that.
AUDITED_READS = {"/v1/instructions", "/v1/instructions/{instruction_id}"}


def _api_gets() -> list[str]:
    return sorted(
        path
        for (method, path), policy in ROUTE_POLICY.items()
        if method == "GET" and not isinstance(policy, Web)
    )


@pytest.mark.no_rate_limit
async def test_a_get_of_any_api_route_changes_nothing_after_a_released_incident(
    world: World,
) -> None:
    person = await _released(world)
    incident = world.open_incident(person)
    assert incident is not None
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204  # for the step-up GETs
    instruction = person.contacts["_instruction"]
    sessions = (await world.h.client.get("/v1/auth/sessions", headers=person.headers)).json()
    params = {
        "contact_id": person.contacts["Brother"],
        "incident_id": str(incident["id"]),
        "instruction_id": instruction,
        "session_id": sessions["items"][0]["id"],
    }
    covered = 0
    for template in _api_gets():
        path = template
        for name, value in params.items():
            path = path.replace("{" + name + "}", value)
        assert "{" not in path, f"no value for the path parameters of {template}"
        policy = next(p for (m, t), p in ROUTE_POLICY.items() if m == "GET" and t == template)
        headers = {} if isinstance(policy, Public) else person.headers
        before = snapshot(world.db)
        response = await world.h.client.get(path, headers=headers)
        assert response.status_code == 200, (path, response.status_code, response.text[:200])
        after = snapshot(world.db)
        changed = changed_tables(before, after)
        if template in AUDITED_READS:
            assert [c.split(" ")[0] for c in changed] == ["audit_logs"], (path, changed)
            added = set(after["audit_logs"]) - set(before["audit_logs"])
            assert len(added) == 1
            assert '"action": "instruction.viewed"' in next(iter(added))
        else:
            assert not changed, f"GET {path} changed {changed}"
        covered += 1
    assert covered >= 15  # the registry's GET routes were really walked
    # time passing changes no answer's side effects either
    world.clock.advance(timedelta(minutes=10))
    before = snapshot(world.db)
    assert (await world.h.client.get("/v1/home", headers=person.headers)).status_code == 200
    assert not changed_tables(before, snapshot(world.db))
