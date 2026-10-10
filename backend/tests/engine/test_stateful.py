"""ENG-PBT-03: a stateful model test of the whole system.

For each seed a deterministic pseudo-random history is played against the real API, the real
engine and the real dispatcher on the frozen clock: ticks, clock jumps of every size, check-ins
(accepted or refused), I'M SAFE, contacts deleted or opting out, an operator Hold, and provider
failures. After **every** step the safety invariants are checked against the database.

(The plan names Hypothesis' ``RuleBasedStateMachine``. The system under test is async and
database-backed, so the same idea is implemented as seeded simulations: each failure is
reproduced exactly by its seed.)
"""

from __future__ import annotations

import random
from datetime import datetime, timedelta
from typing import Any

import pytest

from app.ops import admin
from tests.world import Person, World

STEPS = 60
JUMPS = [
    timedelta(seconds=30),
    timedelta(minutes=3),
    timedelta(minutes=12),
    timedelta(minutes=47),
    timedelta(hours=3),
    timedelta(hours=9),
    timedelta(days=1),
]


class Model:
    """What the simulation knows that the database does not: when a contact stopped being
    eligible, and whether the system was in a Hold at which times."""

    def __init__(self) -> None:
        self.invalid_since: dict[str, datetime] = {}
        self.hold_open_since: datetime | None = None
        self.hold_windows: list[tuple[datetime, datetime | None]] = []


def check_invariants(world: World, people: list[Person], model: Model) -> None:
    db = world.db
    # INV-2: a check-in that settled an incident left no contact-facing message in flight or sent
    leaked = db.execute(
        """
        SELECT i.id FROM escalation_incidents i
        WHERE i.status = 'resolved' AND (
              i.contacts_messaged_at IS NOT NULL
           OR EXISTS (SELECT 1 FROM notifications n
                       WHERE n.incident_id = i.id AND n.category = 'contact_escalation'
                         AND n.status IN ('sending', 'sent')))
        """
    ).fetchall()
    assert leaked == [], "INV-2: a resolved incident reached a contact"

    # a closed incident has nothing pending
    pending = db.execute(
        "SELECT a.id FROM incident_actions a JOIN escalation_incidents i ON i.id = a.incident_id "
        "WHERE i.status IN ('resolved', 'cancelled', 'voided') AND a.status = 'pending'"
    ).fetchall()
    assert pending == [], "a closed incident still has pending actions"

    # INV-8: a stage is never due, and never ran, before the grace period ended
    early = db.execute(
        "SELECT a.id FROM incident_actions a JOIN escalation_incidents i ON i.id = a.incident_id "
        "WHERE a.kind = 'execute_stage' AND (a.scheduled_for < i.grace_ends_at "
        "OR (a.executed_at IS NOT NULL AND a.executed_at < i.grace_ends_at))"
    ).fetchall()
    assert early == [], "INV-8: a stage before the end of grace"

    # F-03: a contact-facing stage never runs when it is found late (the worker was down): it
    # is put back and the person warned again, so it runs within the tolerance of its time.
    tolerance = timedelta(seconds=world.engine.settings.late_tolerance_seconds)
    late = db.execute(
        "SELECT a.id FROM incident_actions a WHERE a.kind = 'execute_stage' "
        "AND a.executed_at IS NOT NULL AND a.executed_at > a.scheduled_for + %s",
        (tolerance,),
    ).fetchall()
    assert late == [], "F-03: a stage ran long after its time, with no further warning"

    # INV-6: nobody was messaged after they stopped being eligible
    for row in db.execute(
        "SELECT contact_id, coalesce(sent_at, updated_at) AS at, status FROM notifications "
        "WHERE category = 'contact_escalation' AND status IN ('sending', 'sent')"
    ).fetchall():
        since = model.invalid_since.get(str(row["contact_id"]))
        assert since is None or row["at"] <= since, "INV-6: a message to an ineligible contact"

    # INV-10: no contact-facing message left during a Hold
    for window_start, window_end in model.hold_windows:
        end = window_end or world.clock.current
        inside = db.execute(
            "SELECT id FROM notifications WHERE category = 'contact_escalation' "
            "AND status IN ('sending', 'sent') AND coalesce(sent_at, updated_at) > %s "
            "AND coalesce(sent_at, updated_at) < %s",
            (window_start, end),
        ).fetchall()
        assert inside == [], "INV-10: a contact-facing message during Hold"

    # "messaged" means a message was handed to a provider at least once (§8.2): ``sent``, in
    # flight, or sent-and-failed-and-requeued. It never appears without an attempt, and a
    # message that reached a provider always implies it.
    for incident in db.execute("SELECT * FROM escalation_incidents").fetchall():
        attempted = db.execute(
            "SELECT 1 FROM notifications WHERE incident_id = %s "
            "AND category = 'contact_escalation' "
            "AND (status IN ('sending', 'sent', 'failed') OR attempt_count > 0) LIMIT 1",
            (incident["id"],),
        ).fetchone()
        delivered = db.execute(
            "SELECT 1 FROM notifications WHERE incident_id = %s "
            "AND category = 'contact_escalation' AND status IN ('sending', 'sent') LIMIT 1",
            (incident["id"],),
        ).fetchone()
        assert (incident["contacts_messaged_at"] is not None) == (attempted is not None), (
            "contacts_messaged_at disagrees with the outbox"
        )
        assert delivered is None or incident["contacts_messaged_at"] is not None, (
            "a message left but the incident does not say contacts were messaged"
        )

    # one open incident per user, and the schedule agrees with it
    for person in people:
        open_incident = world.open_incident(person)
        status = world.config(person)["status"]
        assert (status == "incident_open") == (open_incident is not None), (
            f"schedule is {status!r} but the open incident is {open_incident is not None}"
        )

    # exactly-once: a stage action has at most one executed effect per target
    dupes = db.execute(
        "SELECT action_id, contact_id, scheduled_stamp FROM ("
        "  SELECT action_id, contact_id, split_part(dedupe_key, ':', 3) AS scheduled_stamp, "
        "         count(*) FILTER (WHERE status IN ('queued','sending','sent')) AS live "
        "  FROM notifications WHERE category = 'contact_escalation' "
        "  GROUP BY action_id, contact_id, split_part(dedupe_key, ':', 3)) q WHERE live > 1"
    ).fetchall()
    assert dupes == [], "INV-5: the same message queued twice"


async def operate(  # noqa: PLR0911, PLR0912 - a flat menu of operations
    world: World, people: list[Person], model: Model, rng: random.Random
) -> str:
    person = rng.choice(people)
    roll = rng.random()
    if roll < 0.14:
        await world.advance(seconds=rng.choice(JUMPS).total_seconds())
        return "advance"
    if roll < 0.40:  # walk to the next thing that is due, so late stages are really reached
        horizon = world.clock.current + timedelta(days=3)
        nxt = world._next_instant(world.clock.current, horizon)
        if nxt is None:
            await world.advance(minutes=rng.randint(1, 90))
        else:
            await world.advance_to(nxt + timedelta(seconds=rng.choice((0, 0, 1, 30, 290, 310))))
        return "next-event"
    if roll < 0.46:
        await world.tick()
        return "tick"
    if roll < 0.58:
        await world.login(person)
        response = await world.h.client.post(
            "/v1/checkins",
            headers={**person.headers, "Idempotency-Key": f"sim-{rng.getrandbits(64):016x}"},
        )
        assert response.status_code in (200, 409), response.text
        return f"checkin:{response.status_code}"
    if roll < 0.64:
        incident = world.open_incident(person)
        if incident is not None:
            await world.safe(person, str(incident["id"]))
        return "safe"
    if roll < 0.68 and person.contacts:
        label = rng.choice(sorted(person.contacts))
        contact_id = person.contacts.pop(label)
        # removing someone who would be told needs the password (F-12), as for a real person
        await world.login(person)
        assert (await world.h.reauth(person.tokens)).status_code == 204
        response = await world.h.client.delete(f"/v1/contacts/{contact_id}", headers=person.headers)
        assert response.status_code == 204
        model.invalid_since[contact_id] = world.clock.current
        return "delete-contact"
    if roll < 0.74 and person.contacts:
        label = rng.choice(sorted(person.contacts))
        contact_id = person.contacts[label]
        world.db.execute(
            "UPDATE trusted_contacts SET verification_status = 'opted_out' WHERE id = %s",
            (contact_id,),
        )
        model.invalid_since.setdefault(contact_id, world.clock.current)
        return "opt-out"
    if roll < 0.79:
        if model.hold_open_since is None:
            await admin.hold_enter(world.engine.services, operator="sim", reason="simulation")
            model.hold_open_since = world.clock.current
            model.hold_windows.append((world.clock.current, None))
            return "hold-enter"
        await admin.hold_exit(world.engine.services, operator="sim")
        start = model.hold_windows.pop()[0]
        model.hold_windows.append((start, world.clock.current))
        model.hold_open_since = None
        return "hold-exit"
    if roll < 0.87:
        world.mail.fail_next = True
        return "provider-failure"
    if roll < 0.91:  # an operator voids the incident after a confirmed fault (FS-13)
        incident = world.open_incident(person)
        if incident is not None:
            await admin.void_incident(
                world.engine.services, operator="sim", incident_id=incident["id"]
            )
        return "void"
    if roll < 0.95:  # the worker is down for hours and then comes back (FS-08)
        world.clock.set(world.clock.current + timedelta(hours=rng.choice((1, 3, 8))))
        await world.tick()
        return "outage"
    await world.advance(seconds=1)
    return "nudge"


@pytest.mark.no_rate_limit
@pytest.mark.parametrize("seed", range(20))
async def test_random_histories_keep_every_invariant(world: World, seed: int) -> None:
    rng = random.Random(seed)
    people = [
        await world.ready(
            f"sim{i}@example.com",
            contacts=("Mom", "Dad"),
            stages=((180, ("Mom",)), (1440, ("Dad",))),
        )
        for i in range(3)
    ]
    model = Model()
    trace: list[str] = []
    for step in range(STEPS):
        trace.append(await operate(world, people, model, rng))
        try:
            check_invariants(world, people, model)
        except AssertionError as exc:  # keep the seed and the history in the failure
            msg = f"seed={seed} step={step} history={trace}: {exc}"
            raise AssertionError(msg) from exc

    # leave a Hold if the history ended inside one, then let everything run out
    if model.hold_open_since is not None:
        await admin.hold_exit(world.engine.services, operator="sim")
        start = model.hold_windows.pop()[0]
        model.hold_windows.append((start, world.clock.current))
    await world.advance(days=10)
    check_invariants(world, people, model)
    assert_nothing_left_dangling(world)


def assert_nothing_left_dangling(world: World) -> None:
    stuck: list[Any] = world.db.execute(
        "SELECT id FROM notifications WHERE status = 'sending'"
    ).fetchall()
    assert stuck == []
