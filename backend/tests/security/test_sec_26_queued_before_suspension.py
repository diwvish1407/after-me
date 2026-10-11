"""SEC-26, the dispatcher's own re-check: what was *already queued* when the owner was suspended.

``test_sec_26_suspended_owner.py`` shuts the doors one by one (queued alert, reminder never
queued, portal, web cookie, bearer token). Two cases there are not reached by it and are the ones
that depend on the dispatcher looking at the owner a second time, at the moment of sending:

* a release link (``contact_alert_with_release``) queued by stage 2 and cancelled before it is
  sent, so no link exists for anyone to open;
* a pre-deadline reminder that the engine had already queued when the suspension came: it is
  cancelled ``account_inactive`` at dispatch, not merely never queued.

The engine and the dispatcher are stepped by hand where the order matters (``world.engine.tick``
queues, ``world.dispatch`` sends), so that the suspension lands between the two.
"""

from __future__ import annotations

from datetime import timedelta

from tests.engine.test_release import DUE, STAGE_2, _setup, address
from tests.world import Person, World


def _suspend(world: World, person: Person) -> None:
    world.db.execute("UPDATE users SET status = 'suspended' WHERE id = %s", (person.user_id,))


async def test_a_release_link_queued_before_the_suspension_is_cancelled_and_never_sent(
    world: World,
) -> None:
    person = await _setup(world)
    await world.advance_to(STAGE_2 + timedelta(seconds=20))
    queued = world.notifications(person, template_key="contact_alert_with_release")
    assert [n["status"] for n in queued] == ["queued"]  # stage 2 ran; the settle delay is open
    brother = address(person, "Brother")
    assert world.mail.to(brother, "contact_alert_with_release") == []

    _suspend(world, person)
    await world.advance(minutes=10)

    [row] = world.notifications(person, template_key="contact_alert_with_release")
    assert (row["status"], row["cancelled_reason"]) == ("cancelled", "account_inactive")
    for template in ("contact_alert_with_release", "contact_alert", "contact_release"):
        assert world.mail.to(brother, template) == [], template
    # no link was ever sent, so no portal access can have been opened: no view was counted
    views = world.db.execute("SELECT coalesce(sum(view_count), 0) AS n FROM release_events")
    assert views.fetchone() == {"n": 0}
    sessions = world.db.execute("SELECT count(*) AS n FROM portal_sessions").fetchone()
    assert sessions == {"n": 0}


async def test_a_reminder_queued_before_the_suspension_is_cancelled_at_dispatch(
    world: World,
) -> None:
    person = await world.ready()
    control = await world.ready("control@example.com")
    world.clock.set(DUE - timedelta(minutes=59))
    await world.engine.tick()  # the engine queues the reminders; nothing has been dispatched
    for who in (person, control):
        queued = world.notifications(who, template_key="checkin_pre_reminder")
        assert [n["status"] for n in queued] == ["queued"]

    _suspend(world, person)
    await world.dispatch()

    [row] = world.notifications(person, template_key="checkin_pre_reminder")
    assert (row["status"], row["cancelled_reason"]) == ("cancelled", "account_inactive")
    assert world.mail.to(person.email, "checkin_pre_reminder") == []
    # the same pass sent the active account's
    assert len(world.mail.to(control.email, "checkin_pre_reminder")) == 1
