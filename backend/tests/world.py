"""A world to drive the whole system in tests: the real HTTP API, the real engine (as the
``afterme_worker`` role), a frozen clock, and the recording providers.

Time moves only when the test moves it. ``advance_to`` jumps from one interesting instant (a
deadline, an action, a queued message) to the next and ticks at each, so a multi-day scenario
costs a handful of ticks and stays deterministic.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

import psycopg

from app.api.container import build_worker_services
from app.engine.dispatcher import Dispatcher, DispatchReport
from app.engine.runtime import Engine, TickReport
from app.notifications.email import RecordingEmailProvider
from app.notifications.push import RecordingPushProvider
from tests.support import Harness, bearer, make_premium

Db = psycopg.Connection[dict[str, Any]]
PASSWORD = "correct horse battery staple"


def ist(text: str) -> datetime:
    """``"2026-10-14T20:00"`` in Asia/Kolkata (UTC+05:30) as an aware UTC instant."""
    naive = datetime.fromisoformat(text)
    return (naive - timedelta(hours=5, minutes=30)).replace(tzinfo=UTC)


@dataclass
class Person:
    email: str
    tokens: dict[str, Any]
    user_id: str
    contacts: dict[str, str] = field(default_factory=dict)  # label -> contact id

    @property
    def headers(self) -> dict[str, str]:
        return bearer(self.tokens)


class World:
    def __init__(self, h: Harness, engine: Engine, owner_db: Db) -> None:
        self.h = h
        self.engine = engine
        self.db = owner_db
        self.clock = h.clock
        self.ticks = 0
        self.push = RecordingPushProvider()
        self.dispatcher = Dispatcher(engine.services, push=self.push)
        self.last_dispatch = DispatchReport()

    @property
    def mail(self) -> RecordingEmailProvider:
        return self.h.mail

    # ------------------------------------------------------------------ people

    async def person(self, email: str = "owner@example.com", *, premium: bool = False) -> Person:
        tokens = await self.h.signup(email)
        if premium:
            make_premium(self.db, email)
        return Person(email=email, tokens=tokens, user_id=tokens["user"]["id"])

    async def contact(
        self, person: Person, label: str, *, verified: bool = True, **extra: Any
    ) -> str:
        email = f"{label.lower()}.{person.user_id[:6]}@example.com"
        await self.login(person)
        response = await self.h.add_contact(person.tokens, email, name=label, **extra)
        assert response.status_code == 201, response.text
        contact_id = str(response.json()["id"])
        person.contacts[label] = contact_id
        if verified:
            self.db.execute(
                "UPDATE trusted_contacts SET verification_status = 'verified', "
                "verified_at = now() WHERE id = %s",
                (contact_id,),
            )
        return contact_id

    async def plan(
        self,
        person: Person,
        stages: Iterable[tuple[int, list[str]]],
        *,
        grace: int | None = None,
    ) -> dict[str, Any]:
        """``stages`` as ``(offset_minutes, [contact labels])``; the first offset is the grace."""
        listed = list(stages)
        grace_minutes = grace if grace is not None else listed[0][0]
        current = await self.h.client.get("/v1/plan", headers=person.headers)
        existing = current.json()["stages"]
        body = {
            "grace_minutes": grace_minutes,
            "stages": [
                {
                    "id": existing[i]["id"] if i < len(existing) else None,
                    "offset_minutes": offset,
                    "notify_contact_ids": [person.contacts[label] for label in labels],
                }
                for i, (offset, labels) in enumerate(listed)
            ],
        }
        response = await self.h.client.put(
            "/v1/plan", json=body, headers={**person.headers, "If-Match": current.headers["etag"]}
        )
        assert response.status_code == 200, response.text
        plan: dict[str, Any] = response.json()
        return plan

    async def activate(self, person: Person) -> dict[str, Any]:
        response = await self.h.client.post("/v1/checkin/activate", headers=person.headers)
        assert response.status_code == 200, response.text
        body: dict[str, Any] = response.json()
        return body

    async def ready(
        self,
        email: str = "owner@example.com",
        *,
        contacts: tuple[str, ...] = ("Mom",),
        stages: tuple[tuple[int, tuple[str, ...]], ...] = ((180, ("Mom",)),),
        premium: bool = True,
        activate: bool = True,
    ) -> Person:
        person = await self.person(email, premium=premium)
        for label in contacts:
            await self.contact(person, label)
        await self.plan(person, [(o, list(c)) for o, c in stages])
        if activate:
            await self.activate(person)
        return person

    async def checkin(self, person: Person, *, expect: int = 200, key: str | None = None) -> Any:
        """I'M OK now (a fresh sign-in first, so the access token is never the problem)."""
        person.tokens = await self.h.relogin(person.email)
        import uuid

        response = await self.h.client.post(
            "/v1/checkins",
            headers={**bearer(person.tokens), "Idempotency-Key": key or str(uuid.uuid4())},
        )
        assert response.status_code == expect, response.text
        return response

    async def call(self, person: Person, method: str, path: str, **kwargs: Any) -> Any:
        """An API call as ``person``, after a fresh sign-in (the clock may have moved far past
        the access token's lifetime)."""
        await self.login(person)
        headers = {**person.headers, **kwargs.pop("headers", {})}
        return await self.h.client.request(method, path, headers=headers, **kwargs)

    async def safe(
        self, person: Person, incident_id: str, *, expect: int = 200, key: str | None = None
    ) -> Any:
        """I'M SAFE: a fresh sign-in, the password, then the confirmation."""
        import uuid

        await self.login(person)
        assert (await self.h.reauth(person.tokens)).status_code == 204
        response = await self.h.client.post(
            f"/v1/incidents/{incident_id}/safe",
            headers={**person.headers, "Idempotency-Key": key or str(uuid.uuid4())},
        )
        assert response.status_code == expect, response.text
        return response

    async def login(self, person: Person) -> None:
        person.tokens = await self.h.relogin(person.email)

    # ------------------------------------------------------------------ time

    async def tick(self) -> TickReport:
        """One engine tick and one dispatcher pass, as the worker process runs them."""
        self.ticks += 1
        report = await self.engine.tick()
        # as workers/engine.py: an unknown Hold state sends nothing contact-facing
        self.last_dispatch = await self.dispatcher.dispatch(contact_facing=not report.hold_unknown)
        return report

    async def dispatch(self) -> DispatchReport:
        self.last_dispatch = await self.dispatcher.dispatch()
        return self.last_dispatch

    def _next_instant(self, after: datetime, limit: datetime) -> datetime | None:
        row = self.db.execute(
            """
            SELECT min(t) AS t FROM (
              SELECT next_due_at AS t FROM checkin_configurations
               WHERE status = 'active' AND next_due_at > %(after)s
              UNION ALL
              SELECT next_due_at - reminder_lead_minutes * interval '1 minute'
                FROM checkin_configurations
               WHERE status = 'active' AND reminder_lead_minutes > 0
                 AND next_due_at - reminder_lead_minutes * interval '1 minute' > %(after)s
              UNION ALL
              SELECT scheduled_for FROM incident_actions
               WHERE status = 'pending' AND scheduled_for > %(after)s
              UNION ALL
              SELECT send_after FROM notifications
               WHERE status = 'queued' AND send_after > %(after)s
              UNION ALL
              SELECT next_attempt_at FROM notifications
               WHERE status = 'queued' AND next_attempt_at > %(after)s
            ) q WHERE t <= %(limit)s
            """,
            {"after": after, "limit": limit},
        ).fetchone()
        return None if row is None else row["t"]

    async def advance_to(self, target: datetime) -> None:
        """Move the clock to ``target``, ticking at every instant where something is due."""
        if target < self.clock.current:
            raise AssertionError("time only moves forward")
        await self.tick()
        while True:
            nxt = self._next_instant(self.clock.current, target)
            if nxt is None:
                break
            self.clock.set(nxt)  # exactly when it is due: `<= now` is inclusive
            await self.tick()
        self.clock.set(target)
        await self.tick()

    async def advance(self, **delta: float) -> None:
        await self.advance_to(self.clock.current + timedelta(**delta))

    # ------------------------------------------------------------------ inspection

    def incidents(self, person: Person) -> list[dict[str, Any]]:
        return [
            dict(r)
            for r in self.db.execute(
                "SELECT * FROM escalation_incidents WHERE user_id = %s ORDER BY opened_at",
                (person.user_id,),
            ).fetchall()
        ]

    def open_incident(self, person: Person) -> dict[str, Any] | None:
        row = self.db.execute(
            "SELECT * FROM escalation_incidents WHERE user_id = %s "
            "AND status IN ('grace','escalating','escalated')",
            (person.user_id,),
        ).fetchone()
        return dict(row) if row else None

    def actions(self, person: Person, **where: str) -> list[dict[str, Any]]:
        clauses = " AND ".join(f"{k} = %s" for k in where)
        query = "SELECT * FROM incident_actions WHERE user_id = %s"
        if clauses:
            query += f" AND {clauses}"
        query += " ORDER BY scheduled_for, kind"
        return [
            dict(r) for r in self.db.execute(query, (person.user_id, *where.values())).fetchall()
        ]

    def notifications(self, person: Person, **where: str) -> list[dict[str, Any]]:
        clauses = " AND ".join(f"{k} = %s" for k in where)
        query = "SELECT * FROM notifications WHERE user_id = %s"
        if clauses:
            query += f" AND {clauses}"
        query += " ORDER BY created_at, template_key, channel"
        return [
            dict(r) for r in self.db.execute(query, (person.user_id, *where.values())).fetchall()
        ]

    def config(self, person: Person) -> dict[str, Any]:
        row = self.db.execute(
            "SELECT * FROM checkin_configurations WHERE user_id = %s", (person.user_id,)
        ).fetchone()
        assert row is not None
        return dict(row)

    async def dispose(self) -> None:
        await self.engine.services.db.dispose()


def build_world(h: Harness, owner_db: Db) -> World:
    services = build_worker_services(
        h.settings, clock=h.clock, email_provider=h.app.state.services.mailer.provider
    )
    return World(h, Engine(services, instance_id="test-worker"), owner_db)
