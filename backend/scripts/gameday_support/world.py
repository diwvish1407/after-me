"""What people and operators do in a rehearsal: HTTP calls to the real API, SQL observation as
the owner role, and the test clock (API_SPEC §17).

People are made through the public API (sign-up with the mailed code, a contact, a plan, a
schedule, activation). Two things are done in the database, as ``backend/README.md`` describes
for trying a miss quickly: a contact's acceptance (the invitation pages are covered by the
Android suite) and the instant of a deadline (the API cannot set ``next_due_at``, and the
12-hour minimum window would cost twelve simulated hours of probes).
"""

from __future__ import annotations

import re
import secrets
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

import httpx
import psycopg
from psycopg.rows import dict_row

from .checks import parse_mail_file
from .procs import HarnessError, wait_for

PASSWORD = "correct horse battery staple"  # noqa: S105 - an account on a throwaway database
DEVICE = {"platform": "android", "app_version": "1.0.0+1", "os_version": "gameday", "locale": "en"}
CLOCK_KEY = "test_clock_offset_seconds"
_CODE_RE = re.compile(r"\b(\d{6})\b")
GRACE_MINUTES = 180  # a preset: the free tier takes no custom offsets


Row = dict[str, Any]


# --------------------------------------------------------------------------------------------
# the database, as the owner role
# --------------------------------------------------------------------------------------------


class Observer:
    def __init__(self, conninfo: str) -> None:
        self.conn: psycopg.Connection[Row] = psycopg.connect(
            conninfo, autocommit=True, row_factory=dict_row
        )

    def close(self) -> None:
        self.conn.close()

    def all(self, sql: str, params: tuple[Any, ...] | dict[str, Any] | None = None) -> list[Row]:
        return [dict(r) for r in self.conn.execute(sql, params).fetchall()]  # type: ignore[arg-type]

    def one(self, sql: str, params: tuple[Any, ...] | dict[str, Any] | None = None) -> Row | None:
        row = self.conn.execute(sql, params).fetchone()  # type: ignore[arg-type]
        return None if row is None else dict(row)

    def run(self, sql: str, params: tuple[Any, ...] | dict[str, Any] | None = None) -> None:
        self.conn.execute(sql, params)  # type: ignore[arg-type]

    def scalar(self, sql: str, params: tuple[Any, ...] | dict[str, Any] | None = None) -> Any:
        row = self.conn.execute(sql, params).fetchone()  # type: ignore[arg-type]
        return None if row is None else next(iter(row.values()))

    # ------------------------------------------------------------------ the test clock

    def sim_now(self) -> datetime:
        """The database clock plus the test offset: what the API and the worker call "now"."""
        value = self.scalar(
            "SELECT now() + COALESCE((SELECT (value #>> '{}')::bigint FROM system_flags "
            "WHERE key = %s), 0) * interval '1 second'",
            (CLOCK_KEY,),
        )
        assert isinstance(value, datetime)  # noqa: S101
        return value

    def advance_clock(self, seconds: int) -> None:
        """The statement ``POST /test/clock/advance`` runs, for when the API is not there."""
        self.run(
            "INSERT INTO system_flags (key, value, updated_by) "
            "VALUES (%(k)s, to_jsonb(%(s)s::bigint), 'gameday') "
            "ON CONFLICT (key) DO UPDATE SET value = to_jsonb("
            "(system_flags.value #>> '{}')::bigint + %(s)s::bigint), "
            "updated_at = now(), updated_by = 'gameday'",
            {"k": CLOCK_KEY, "s": seconds},
        )

    def last_beat(self, service: str = "engine") -> datetime | None:
        value = self.scalar(
            "SELECT max(last_beat_at) FROM service_heartbeats WHERE service = %s", (service,)
        )
        return value if isinstance(value, datetime) else None

    # ------------------------------------------------------------------ what the engine wrote

    def incidents(self, user_id: str) -> list[Row]:
        return self.all(
            "SELECT * FROM escalation_incidents WHERE user_id = %s ORDER BY opened_at", (user_id,)
        )

    def open_incident(self, user_id: str) -> Row | None:
        return self.one(
            "SELECT * FROM escalation_incidents WHERE user_id = %s "
            "AND status IN ('grace', 'escalating', 'escalated')",
            (user_id,),
        )

    def stage(self, user_id: str) -> Row | None:
        return self.one(
            "SELECT * FROM incident_actions WHERE user_id = %s AND kind = 'execute_stage' "
            "ORDER BY created_at DESC, scheduled_for LIMIT 1",
            (user_id,),
        )

    def actions(self, user_id: str, kind: str | None = None) -> list[Row]:
        return self.all(
            "SELECT * FROM incident_actions WHERE user_id = %s AND (%s::text IS NULL OR kind = %s) "
            "ORDER BY scheduled_for, kind",
            (user_id, kind, kind),
        )

    def notifications(self, user_id: str, template: str | None = None) -> list[Row]:
        return self.all(
            "SELECT * FROM notifications WHERE user_id = %s "
            "AND (%s::text IS NULL OR template_key = %s) ORDER BY created_at, id",
            (user_id, template, template),
        )

    def holds(self) -> list[Row]:
        return self.all("SELECT * FROM system_holds ORDER BY started_at")

    def audit(self, action: str, subject: str | None = None) -> list[Row]:
        return self.all(
            "SELECT * FROM audit_logs WHERE action = %s "
            "AND (%s::text IS NULL OR subject_user_id::text = %s) ORDER BY id",
            (action, subject, subject),
        )

    def config(self, user_id: str) -> Row:
        row = self.one("SELECT * FROM checkin_configurations WHERE user_id = %s", (user_id,))
        if row is None:
            msg = f"no check-in configuration for {user_id}"
            raise HarnessError(msg)
        return row

    def set_deadline(self, user_id: str, at: datetime) -> None:
        """Place ``next_due_at`` (see the module docstring for why this is not the API)."""
        self.run(
            "UPDATE checkin_configurations SET next_due_at = %s WHERE user_id = %s "
            "AND status = 'active'",
            (at, user_id),
        )


# --------------------------------------------------------------------------------------------
# the real API
# --------------------------------------------------------------------------------------------


class Api:
    def __init__(self, base_url: str, test_token: str) -> None:
        self.base_url = base_url
        self.http = httpx.Client(base_url=base_url, timeout=20.0)
        self._test = {"X-Test-Token": test_token}

    def close(self) -> None:
        self.http.close()

    def is_ready(self) -> bool:
        try:
            return self.http.get("/health/ready", timeout=3.0).status_code == httpx.codes.OK
        except httpx.TransportError:
            return False

    def call(
        self,
        method: str,
        path: str,
        *,
        token: str | None = None,
        json: object | None = None,
        headers: dict[str, str] | None = None,
    ) -> httpx.Response:
        merged = dict(headers or {})
        if token is not None:
            merged["Authorization"] = f"Bearer {token}"
        return self.http.request(method, path, json=json, headers=merged)

    def clock_advance(self, seconds: int) -> None:
        response = self.http.post(
            "/test/clock/advance", json={"seconds": seconds}, headers=self._test
        )
        expect(response, httpx.codes.OK, "POST /test/clock/advance")

    def probe(self, probe_token: str) -> None:
        response = self.http.post(
            "/internal/probe", headers={"X-Probe-Token": probe_token, "X-Probe-Source": "gameday"}
        )
        expect(response, httpx.codes.NO_CONTENT, "POST /internal/probe")

    def mail(
        self, *, to: str | None = None, template: str | None = None, limit: int = 50
    ) -> list[dict[str, str]]:
        params: dict[str, str | int] = {"limit": limit}
        if to:
            params["to"] = to
        if template:
            params["template"] = template
        response = self.http.get("/test/mail", params=params, headers=self._test)
        expect(response, httpx.codes.OK, "GET /test/mail")
        messages: list[dict[str, str]] = response.json()["messages"]
        return messages


def expect(response: httpx.Response, status: int, what: str) -> None:
    if response.status_code != status:
        body = response.text.strip().replace("\n", " ")[:300]
        msg = f"{what}: expected HTTP {int(status)}, got {response.status_code}: {body}"
        raise HarnessError(msg)


class Mailbox:
    """The mails the console provider wrote: through ``GET /test/mail`` while the API is up, and
    by reading the same files (same parser) while it is not."""

    def __init__(self, api: Api, directory: Path) -> None:
        self.api = api
        self.directory = directory

    def find(self, *, to: str | None = None, template: str | None = None) -> list[dict[str, str]]:
        wanted = to.strip().lower() if to else None
        try:
            return [
                {"to": m["to"].lower(), "template": m["template"], "subject": m["subject"]}
                for m in self.api.mail(to=wanted, template=template)
            ]
        except (httpx.TransportError, HarnessError):
            pass
        found: list[dict[str, str]] = []
        for path in sorted(self.directory.glob("*.txt")):
            try:
                parsed = parse_mail_file(path.read_text(encoding="utf-8"))
            except OSError:
                continue
            if parsed is None:
                continue
            if wanted is not None and parsed["to"] != wanted:
                continue
            if template is not None and parsed["template"] != template:
                continue
            found.append(parsed)
        return found

    def count(self, *, to: str | None = None, template: str | None = None) -> int:
        return len(self.find(to=to, template=template))

    def files(self) -> list[tuple[str, str, str]]:
        """Every mail written, as ``(file name, template, recipient)``. The console provider's
        message id is the file name, so this is what outbox rows are reconciled against; it
        reads the directory (the API's listing is capped at 50)."""
        found: list[tuple[str, str, str]] = []
        for path in sorted(self.directory.glob("*.txt")):
            try:
                parsed = parse_mail_file(path.read_text(encoding="utf-8"))
            except OSError:
                continue
            if parsed is not None:
                found.append((path.name, parsed["template"], parsed["to"]))
        return found


# --------------------------------------------------------------------------------------------
# people
# --------------------------------------------------------------------------------------------


@dataclass
class Person:
    tag: str
    email: str
    user_id: str = ""
    contact_id: str = ""
    contact_email: str = ""
    tokens: dict[str, Any] = field(default_factory=dict)

    @property
    def access(self) -> str:
        return str(self.tokens["access_token"])


class People:
    """Makes people through the API and acts as them."""

    def __init__(self, api: Api, observer: Observer, mailbox: Mailbox) -> None:
        self.api = api
        self.obs = observer
        self.mail = mailbox
        self.run_id = secrets.token_hex(3)

    def create(
        self, tag: str, *, reminder_lead: int = 0, grace_minutes: int = GRACE_MINUTES
    ) -> Person:
        """An account with one verified contact, a one-stage plan (grace 180 minutes unless
        ``grace_minutes`` says otherwise, which is a custom time: the account is made premium
        in the database, as an operator would with ``user set-tier``) and an active daily
        schedule."""
        email = f"gd-{self.run_id}-{tag.lower()}@example.com"
        person = Person(
            tag=tag, email=email, contact_email=f"mom-{tag.lower()}-{self.run_id}@example.com"
        )
        started = self.api.call(
            "POST",
            "/v1/auth/register/start",
            json={
                "email": email,
                "password": PASSWORD,
                "display_name": f"Gameday {tag}",
                "timezone": "Asia/Kolkata",
                "locale": "en",
            },
        )
        expect(started, httpx.codes.ACCEPTED, f"sign-up of {tag}")
        code = self._signup_code(email)
        verified = self.api.call(
            "POST",
            "/v1/auth/register/verify",
            json={"email": email, "code": code, "password": PASSWORD, "device": DEVICE},
        )
        expect(verified, httpx.codes.CREATED, f"verifying {tag}")
        person.tokens = verified.json()
        person.user_id = str(person.tokens["user"]["id"])

        contact = self.api.call(
            "POST",
            "/v1/contacts",
            token=person.access,
            json={
                "display_name": f"Mom {tag}",
                "relationship": "mother",
                "email": person.contact_email,
            },
        )
        expect(contact, httpx.codes.CREATED, f"adding the contact of {tag}")
        person.contact_id = str(contact.json()["id"])
        self.obs.run(
            "UPDATE trusted_contacts SET verification_status = 'verified', verified_at = now() "
            "WHERE id = %s",
            (person.contact_id,),
        )
        if grace_minutes != GRACE_MINUTES:
            self.obs.run("UPDATE users SET tier = 'premium' WHERE id = %s", (person.user_id,))
        self._plan(person, grace_minutes)
        self._schedule(person, reminder_lead)
        activated = self.api.call("POST", "/v1/checkin/activate", token=person.access)
        expect(activated, httpx.codes.OK, f"activating {tag}")
        return person

    def _signup_code(self, email: str) -> str:
        found: list[str] = []

        def arrived() -> bool:
            messages = self.api.mail(to=email, template="signup_code", limit=1)
            if not messages:
                return False
            match = _CODE_RE.search(messages[0]["text"])
            if match:
                found.append(match.group(1))
            return bool(found)

        wait_for(f"the sign-up code for {email}", arrived, timeout=15)
        return found[0]

    def _plan(self, person: Person, grace_minutes: int) -> None:
        current = self.api.call("GET", "/v1/plan", token=person.access)
        expect(current, httpx.codes.OK, "GET /v1/plan")
        put = self.api.call(
            "PUT",
            "/v1/plan",
            token=person.access,
            headers={"If-Match": current.headers["etag"]},
            json={
                "grace_minutes": grace_minutes,
                "stages": [
                    {
                        "id": None,
                        "offset_minutes": grace_minutes,
                        "notify_contact_ids": [person.contact_id],
                    }
                ],
            },
        )
        expect(put, httpx.codes.OK, f"PUT /v1/plan of {person.tag}")

    def _schedule(self, person: Person, reminder_lead: int) -> None:
        current = self.api.call("GET", "/v1/checkin/schedule", token=person.access)
        expect(current, httpx.codes.OK, "GET /v1/checkin/schedule")
        version = current.json()["version"]
        put = self.api.call(
            "PUT",
            "/v1/checkin/schedule",
            token=person.access,
            headers={"If-Match": f'"sched-{version}"'},
            json={
                "interval_days": 1,
                "due_local_time": "12:00",
                "reminder_lead_minutes": reminder_lead,
            },
        )
        expect(put, httpx.codes.OK, f"PUT /v1/checkin/schedule of {person.tag}")

    def login(self, person: Person) -> None:
        """Fresh tokens: the clock may have moved far past the access token's 15 minutes."""
        response = self.api.call(
            "POST",
            "/v1/auth/login",
            json={"email": person.email, "password": PASSWORD, "device": DEVICE},
        )
        expect(response, httpx.codes.OK, f"login of {person.tag}")
        person.tokens = response.json()

    def check_in(self, person: Person) -> httpx.Response:
        """I'M OK, as the app sends it."""
        self.login(person)
        return self.api.call(
            "POST",
            "/v1/checkins",
            token=person.access,
            headers={"Idempotency-Key": str(uuid.uuid4())},
            json={},
        )


# --------------------------------------------------------------------------------------------
# the test clock and the worker's pace
# --------------------------------------------------------------------------------------------


class Sim:
    """Moves simulated time and waits until the worker has acted on it."""

    def __init__(self, api: Api, observer: Observer, probe_token: str | None = None) -> None:
        self.api = api
        self.obs = observer
        self.probe_token = probe_token

    def now(self) -> datetime:
        return self.obs.sim_now()

    def advance(self, seconds: int) -> None:
        """The test clock moves for the API and the worker together (API_SPEC §17). With the
        API down the same statement is run directly."""
        seconds = max(int(seconds), 1)
        try:
            self.api.clock_advance(seconds)
        except (httpx.TransportError, HarnessError):
            self.obs.advance_clock(seconds)

    def settle(self, after: datetime | None = None, *, timeout: float = 40.0) -> None:
        """Wait for two worker ticks that started after ``after``: the first has seen the new
        time, and the second starting means the first (engine pass and dispatch) finished."""
        reference = after or self.now()
        first: list[datetime] = []

        def two_ticks() -> bool:
            beat = self.obs.last_beat()
            if beat is None or beat <= reference:
                return False
            if not first:
                first.append(beat)
                return False
            return beat > first[0]

        wait_for("the worker to tick", two_ticks, timeout=timeout, every=0.15)

    def step(self, seconds: int, *, probe: bool = False) -> datetime:
        """Move time, send a probe like the uptime monitor does (when asked), wait for the
        worker. Returns the simulated time after the step."""
        self.advance(seconds)
        if probe:
            if self.probe_token is None:
                msg = "this stack has no probe token"
                raise HarnessError(msg)
            self.api.probe(self.probe_token)
        at = self.now()
        self.settle(at)
        return at

    def wait_until(self, what: str, check: Any, *, timeout: float = 30.0) -> None:
        wait_for(what, check, timeout=timeout, every=0.2)


def pause(seconds: float) -> None:
    time.sleep(seconds)
