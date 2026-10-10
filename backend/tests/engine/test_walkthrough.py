"""Writes ``docs/ENGINE_WALKTHROUGH.md`` from a real run of the lifecycle.

Skipped unless ``WALKTHROUGH_OUT`` names a file, so the document is always the output of the
code as it is, never hand-written::

    WALKTHROUGH_OUT=../docs/ENGINE_WALKTHROUGH.md uv run pytest tests/engine/test_walkthrough.py
"""

from __future__ import annotations

import os
import pathlib
from datetime import UTC, datetime, timedelta, timezone

import pytest

from tests.world import Person, World, ist

OUT = os.environ.get("WALKTHROUGH_OUT")
IST = timezone(timedelta(hours=5, minutes=30))

pytestmark = pytest.mark.skipif(not OUT, reason="set WALKTHROUGH_OUT to write the walkthrough")


def at(world: World) -> str:
    local = world.clock.current.astimezone(IST)
    return f"{local:%a %d %b %H:%M:%S} IST"


class Narrator:
    def __init__(self, world: World, person: Person) -> None:
        self.world = world
        self.person = person
        self.rows: list[tuple[str, str, str]] = []

    def state(self) -> str:
        incident = self.world.open_incident(self.person)
        closed = self.world.incidents(self.person)
        if incident is not None:
            status = incident["status"]
            told = "contacts told" if incident["contacts_messaged_at"] else "nobody told"
            return f"incident **{status}**, {told}"
        if closed and closed[-1]["closed_at"] is not None:
            last = closed[-1]
            return f"last incident **{last['status']}** ({last['closed_by']})"
        return f"schedule **{self.world.config(self.person)['status']}**"

    def note(self, what: str, effects: str = "") -> None:
        self.rows.append(
            (at(self.world), what, f"{self.state()}{('; ' + effects) if effects else ''}")
        )


def mails(world: World, person: Person) -> str:
    sent = [
        f"{m.template} → {'the user' if m.to == person.email else m.to.split('.')[0].title()}"
        for m in world.mail.messages
        if m.template
        in (
            "checkin_pre_reminder",
            "incident_missed",
            "incident_last_chance",
            "stage_executed",
            "contact_alert",
            "contact_all_clear",
            "all_clear_confirmation",
        )
    ]
    # the last three, in a fixed order: messages queued together leave in no particular order
    return ", ".join(sorted(sent[-3:])) if sent else ""


async def test_write_the_walkthrough(world: World) -> None:
    assert OUT is not None
    world.clock.set(ist("2026-10-13T19:00"))
    person = await world.ready(
        contacts=("Mom", "Brother"), stages=((180, ("Mom",)), (1440, ("Brother",)))
    )
    n = Narrator(world, person)
    n.note(
        "Account set up: daily check-in by 20:00, grace 3 h, stage 1 notifies Mom, "
        "stage 2 (after 24 h) notifies Brother"
    )

    world.clock.set(ist("2026-10-13T19:30"))
    await world.checkin(person)
    n.note(
        "**I'M OK** at 19:30",
        f"next deadline {world.config(person)['next_due_at'].astimezone(IST):%a %d %b %H:%M}",
    )

    await world.advance_to(ist("2026-10-14T19:00"))
    n.note("one hour before the deadline", "reminder email queued and sent to the user")

    await world.advance_to(ist("2026-10-14T20:00"))
    n.note(
        "**deadline passes**: the worker opens an incident and writes its whole timeline",
        "'You missed your 8:00 PM check-in' to the user",
    )

    await world.advance_to(ist("2026-10-14T22:45"))
    n.note("last-chance reminder (15 minutes before grace ends)")

    await world.advance_to(ist("2026-10-14T23:00"))
    n.note(
        "grace ends: **stage 1 runs**",
        "Mom's message is queued behind the 5-minute settle delay; nothing has left",
    )

    await world.advance_to(ist("2026-10-14T23:05"))
    n.note(
        "settle delay over: Mom is emailed, the incident now counts as 'contacts messaged'",
        mails(world, person),
    )

    await world.advance_to(ist("2026-10-15T20:05"))
    n.note("24 h after the start: **stage 2 runs**, Brother is emailed", mails(world, person))

    world.clock.set(ist("2026-10-15T21:00"))
    refused = await world.checkin(person, expect=409)
    n.note(
        "the user returns and taps I'M OK",
        f"**refused** (`{refused.json()['code']}`): contacts were told, so I'M SAFE is required",
    )

    world.clock.set(ist("2026-10-15T21:01"))
    await world.safe(person, str(world.open_incident(person)["id"]))  # type: ignore[index]
    await world.tick()
    n.note("password, then **I'M SAFE**", mails(world, person))

    before = len(
        [m for m in world.mail.messages if m.template in ("contact_alert", "contact_all_clear")]
    )
    await world.advance_to(ist("2026-10-16T19:00"))
    after = len(
        [m for m in world.mail.messages if m.template in ("contact_alert", "contact_all_clear")]
    )
    n.note(
        "a day of ticks later",
        f"no further contact-facing message for that incident ({after - before} new)",
    )

    lines = [
        "# AfterMe: the escalation engine, walked through",
        "",
        "*Generated from a real run of the test suite "
        f"(`tests/engine/test_walkthrough.py`) on {datetime.now(UTC):%Y-%m-%d}; "
        "the clock is simulated, everything else is the real system: the HTTP API, the worker "
        "process logic, the outbox dispatcher and PostgreSQL.*",
        "",
        "The person lives in Asia/Kolkata and checks in daily by 20:00. Their plan: a 3-hour grace "
        "period, then Mom is notified; 24 hours after the start, Brother is notified as well.",
        "",
        "| When | What happens | State afterwards |",
        "|---|---|---|",
    ]
    lines += [f"| {when} | {what} | {state} |" for when, what, state in n.rows]
    lines += [
        "",
        "## Things to notice",
        "",
        "* **Nobody is contacted before the grace period ends,** and Mom's email waits five more "
        "minutes (the *settle delay*): a check-in in that window cancels it and nobody ever knows.",
        "* **Once a contact has been emailed, I'M OK is no longer enough.** The app is told to use "
        "I'M SAFE (which needs the password and sends an all-clear to everyone who was told).",
        "* **The API cannot start any of this.** Incidents, timeline actions and messages are "
        "created only by the worker; the database refuses the API role the `INSERT`.",
        "* **Fail-safe.** If anything is uncertain (inconsistent data, an outage, a Hold), the "
        "engine does nothing and raises an alert instead of contacting anyone.",
        "",
    ]
    pathlib.Path(OUT).write_text("\n".join(lines) + "\n", encoding="utf-8")  # noqa: ASYNC240
