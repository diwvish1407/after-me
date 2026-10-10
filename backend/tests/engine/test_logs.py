"""Nothing personal reaches a log or an audit record while the engine works (SECURITY §10;
ESCALATION_ENGINE §12: structured events carry user_id, incident_id, action_id, kind and
outcome, never names, addresses, instruction content or tokens)."""

from __future__ import annotations

import io
import logging
from collections.abc import Iterator
from datetime import timedelta

import pytest

from app.core.logging import build_formatter
from tests.world import World, ist

DUE = ist("2026-10-09T20:00")


@pytest.fixture
def captured() -> Iterator[io.StringIO]:
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(build_formatter(json=True))
    handler.setLevel(logging.DEBUG)
    root = logging.getLogger()
    previous = root.level
    root.addHandler(handler)
    root.setLevel(logging.DEBUG)
    try:
        yield stream
    finally:
        root.removeHandler(handler)
        root.setLevel(previous)


async def test_a_whole_escalation_leaks_nothing_to_logs_or_audit(
    world: World, captured: io.StringIO
) -> None:
    person = await world.ready(
        contacts=("Quentin", "Rowan"), stages=((180, ("Quentin",)), (1440, ("Rowan",)))
    )
    world.db.execute(
        "UPDATE devices SET push_token = 'fcm-secret-token-0123456789' WHERE id = "
        "(SELECT id FROM devices WHERE user_id = %s ORDER BY created_at, id LIMIT 1)",
        (person.user_id,),
    )
    world.mail.fail_next = True  # a provider failure is logged too
    await world.advance_to(DUE + timedelta(minutes=1440 + 10))
    incident_id = str(world.open_incident(person)["id"])  # type: ignore[index]
    await world.safe(person, incident_id)
    await world.tick()

    output = captured.getvalue()
    assert "incident.opened" in output
    quentin = f"quentin.{person.user_id[:6]}@example.com"
    rowan = f"rowan.{person.user_id[:6]}@example.com"
    for secret in (
        person.email,
        quentin,
        rowan,
        "Quentin",
        "Rowan",
        "Test User",
        "fcm-secret-token-0123456789",
        "oo_",
        "Bearer ",
        "correct horse battery staple",
    ):
        assert secret not in output, f"leaked into logs: {secret[:12]}"

    audit = str(
        world.db.execute(
            "SELECT action, metadata, resource_type FROM audit_logs WHERE subject_user_id = %s",
            (person.user_id,),
        ).fetchall()
    )
    for secret in (person.email, quentin, rowan, "Quentin", "Rowan", "fcm-secret"):
        assert secret not in audit
    outbox = str(
        world.db.execute(
            "SELECT params, cancelled_reason, provider_message_id FROM notifications"
        ).fetchall()
    )
    for secret in (person.email, quentin, rowan, "Quentin", "Rowan", "Test User"):
        assert secret not in outbox
