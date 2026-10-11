"""SEC-12: a portal session is for one incident and one contact, never for the same contact's
other incidents (TEST_PLAN §5.2; the portal has no id parameter to put a 404 on, so the claim is
"not shown").

``test_release.py`` covers two contacts of one incident. This covers the harder neighbour: the
*same* contact released to in two incidents of the same owner, a day or two apart. The first
link and session must meet "taken back" and never the second incident's items; the second must
never list the first's, even when a closing path forgot to revoke (the portal looks at state).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta
from typing import Any

import httpx

from tests.engine.test_release import STAGE_2, Portal, _link_token, _make, address
from tests.security.sec_support import csrf_of
from tests.support import CLIENT_IP
from tests.world import Person, World, ist

ALPHA = "ALPHA keys under the stone"
BETA = "BETA papers in the drawer"


class Browser(Portal):
    """A portal visitor with a cookie jar of their own (two people, or two browsers)."""

    def __init__(self, world: World, app: Any = None) -> None:
        super().__init__(world)
        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app or world.h.app, client=(CLIENT_IP, 51000)),
            base_url="https://api.afterme.test",
        )

    async def csrf(self) -> str:
        return csrf_of(await self.client.get("/c/release"))

    async def enter(self, token: str, person: Person) -> Any:
        """The link, the code, the content: what a contact does."""
        opened = await self.open(token)
        assert opened.status_code == 200, opened.text
        assert (await self.code()).status_code == 200
        return await self.verify(self.last_code(person))

    async def close(self) -> None:
        await self.client.aclose()


@dataclass
class TwoIncidents:
    person: Person
    link_1: str
    link_2: str
    incident_1: str
    incident_2: str
    first: Browser  # opened link 1 while incident 1 was open and has read ALPHA
    second: Browser  # nobody yet: opens link 2


async def _two_incidents(world: World, *, keep_first_instruction: bool) -> TwoIncidents:
    person = await world.ready(
        contacts=("Mom", "Brother"), stages=((180, ("Mom",)), (1440, ("Brother",)))
    )
    assert (await world.h.reauth(person.tokens)).status_code == 204
    alpha = await _make(world, person, "Brother", ALPHA, "Alpha words.")

    # incident 1: released to Brother, read, then taken back by I'M SAFE
    await world.advance_to(STAGE_2 + timedelta(minutes=6))
    link_1 = _link_token(world, person)
    first = Browser(world)
    read = await first.enter(link_1, person)
    assert ALPHA in read.text
    incident_1 = world.open_incident(person)
    assert incident_1 is not None
    await world.safe(person, str(incident_1["id"]))
    await world.tick()

    # the owner changes what is shared, then misses again: incident 2, same contact
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    if not keep_first_instruction:
        off = await world.h.client.patch(
            f"/v1/instructions/{alpha}", json={"status": "inactive"}, headers=person.headers
        )
        assert off.status_code == 200
    await _make(world, person, "Brother", BETA, "Beta words.")
    await world.advance_to(ist("2026-10-12T20:06"))  # the next due is Oct 11 20:00 + a day
    # a session cookie lives an hour, and a second incident is a day away at the soonest: keep
    # the first visitor's session alive (and past its code step) so that what is tested is the
    # session's binding to its incident, not its expiry
    world.db.execute(
        "UPDATE portal_sessions SET expires_at = %s, elevated_until = %s",
        (world.clock.current + timedelta(hours=1), world.clock.current + timedelta(minutes=15)),
    )
    incident_2 = world.open_incident(person)
    assert incident_2 is not None
    assert incident_2["id"] != incident_1["id"]
    link_2 = _link_token(world, person)
    assert link_2 != link_1
    return TwoIncidents(
        person, link_1, link_2, str(incident_1["id"]), str(incident_2["id"]), first, Browser(world)
    )


async def test_the_first_incidents_link_and_session_never_show_the_second_incidents_items(
    world: World,
) -> None:
    two = await _two_incidents(world, keep_first_instruction=False)
    person, brother = two.person, address(two.person, "Brother")
    try:
        # two accesses for the same contact, one per incident, each with its own link
        accesses = world.db.execute(
            "SELECT incident_id, contact_id FROM portal_access ORDER BY created_at"
        ).fetchall()
        assert {str(a["incident_id"]) for a in accesses} == {two.incident_1, two.incident_2}
        assert {str(a["contact_id"]) for a in accesses} == {person.contacts["Brother"]}

        # the session opened in incident 1, still alive and past its code step
        mails_before = len(world.mail.to(brother, "portal_code"))
        stale = await two.first.post("/c/release/view")
        assert BETA not in stale.text
        assert ALPHA not in stale.text
        assert "no longer available" in stale.text  # taken back: they checked in
        asked = await two.first.code()
        assert BETA not in asked.text
        assert len(world.mail.to(brother, "portal_code")) == mails_before  # no code is sent

        # the first link, opened again in a fresh browser, is a taken-back page too
        again = Browser(world)
        try:
            reopened = await again.open(two.link_1)
            assert reopened.status_code == 200
            assert "no longer available" in reopened.text
            assert BETA not in reopened.text
            assert ALPHA not in reopened.text
            via_cookie = await again.post("/c/release/view")
            assert BETA not in via_cookie.text
        finally:
            await again.close()

        # the second incident's session sees the second incident's item, and only that
        shown = await two.second.enter(two.link_2, person)
        assert shown.status_code == 200
        assert BETA in shown.text
        assert ALPHA not in shown.text
        assert shown.text.count("<article") == 1

        # a code issued for the second session does not open the first one
        code_2 = two.second.last_code(person)
        crossed = await two.first.verify(code_2)
        assert BETA not in crossed.text
        assert ALPHA not in crossed.text

        # the views are counted where they happened
        rows = {
            str(r["incident_id"]): r["view_count"]
            for r in world.db.execute("SELECT incident_id, view_count FROM release_events")
        }
        assert rows[two.incident_1] == 1  # read once, in incident 1
        assert rows[two.incident_2] == 1
    finally:
        await two.first.close()
        await two.second.close()


async def test_rows_a_closing_path_forgot_to_revoke_still_stay_in_their_own_incident(
    world: World,
) -> None:
    """Defence in depth. Suppose incident 1's release and access rows were left open (a bug in a
    closing path). The same instruction is released again in incident 2. Neither session may
    see the other incident's rows: not the closed one's, and not twice."""
    two = await _two_incidents(world, keep_first_instruction=True)
    person = two.person
    try:
        world.db.execute(
            "UPDATE release_events SET revoked_at = NULL, revoke_reason = NULL "
            "WHERE incident_id = %s",
            (two.incident_1,),
        )
        world.db.execute(
            "UPDATE portal_access SET revoked_at = NULL WHERE incident_id = %s", (two.incident_1,)
        )
        before = world.db.execute(
            "SELECT view_count, last_viewed_at FROM release_events WHERE incident_id = %s",
            (two.incident_1,),
        ).fetchall()

        shown = await two.second.enter(two.link_2, person)
        assert shown.status_code == 200
        assert BETA in shown.text
        assert shown.text.count(ALPHA) == 1  # released again in incident 2, listed once
        assert shown.text.count("<article") == 2

        # incident 1 is closed: its link and session show nothing, rows open or not
        stale = await two.first.post("/c/release/view")
        assert ALPHA not in stale.text
        assert BETA not in stale.text
        fresh = Browser(world)
        try:
            opened = await fresh.open(two.link_1)
            assert ALPHA not in opened.text
            assert BETA not in opened.text
            assert (await fresh.post("/c/release/view")).status_code == 400  # no session
        finally:
            await fresh.close()

        after = world.db.execute(
            "SELECT view_count, last_viewed_at FROM release_events WHERE incident_id = %s",
            (two.incident_1,),
        ).fetchall()
        assert after == before  # incident 2's reading did not touch incident 1's rows
    finally:
        await two.first.close()
        await two.second.close()
