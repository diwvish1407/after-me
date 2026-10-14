"""OPS-03: invalid email-provider credentials -> retries -> fallback -> backlog page
(TEST_PLAN §7; ESCALATION_ENGINE §8.3; DEPLOYMENT §9 "Email provider outage" and "Provider
credentials invalid").

In-process, because a worker subprocess cannot take an injected HTTP transport: the real
``Engine`` and ``Dispatcher`` run against the throwaway database through the real
``AppServices`` container, configured ``email_provider=resend`` with ``postmark`` as the
fallback. ``build_email_provider(settings, client=...)`` gets an ``httpx.MockTransport`` that
answers 401 for api.resend.com and 200 for api.postmarkapp.com (and, in the second half, 401 for
both), and counts what it was asked. People and incidents are made through the real API process;
time moves with the test clock; the engine and dispatcher are driven tick by tick.

Three people: ``P1`` is alerted while only the primary is rejected; ``P2`` and ``P3`` are
alerted while both are, and make the backlog that drains when the credentials are fixed.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import uuid
from collections import Counter
from collections.abc import Iterator
from datetime import datetime, timedelta
from typing import Any

import httpx

from app.api.container import AppServices, build_worker_services
from app.core.config import Settings
from app.core.logging import configure_logging
from app.engine.dispatcher import Dispatcher
from app.engine.runtime import Engine
from app.notifications.email import EmailMessage
from app.notifications.errors import ProviderUnavailableError
from app.notifications.providers.chain import COOL_DOWN_SECONDS, FallbackEmailProvider
from app.notifications.providers.factory import build_email_provider
from app.notifications.providers.postmark import PostmarkEmailProvider
from app.notifications.providers.resend import ResendEmailProvider
from app.notifications.push import NoopPushProvider
from app.ops import admin
from app.testsupport.clock import OffsetDbClock

from .checks import format_excerpt, status_excerpt
from .procs import KID, HarnessError
from .stack import Context, Stack
from .world import Person

ID = "OPS-03"
REQUIRED = tuple(f"{ID}.{n}" for n in range(1, 11))  # every check id the run must have made
RESEND_HOST = "api.resend.com"
POSTMARK_HOST = "api.postmarkapp.com"
FALLBACK_WARNING = "the fallback email provider is carrying messages"
BACKLOG_PAGE = "queued message past send_after for 5 minutes"
ERROR_RATE_WARNING = "provider error rate above 5% in the last 15 minutes"
DOC_ENGINE = "ESCALATION_ENGINE §8.3"
DOC_RUNBOOK = "DEPLOYMENT §9 (Email provider outage; Provider credentials invalid)"
RESEND_KEY = "re_gameday_rejected_key_0000000000"
POSTMARK_TOKEN = "pm-gameday-rejected-token-0000000"  # noqa: S105 - rejected by the mock transport
UUID_LENGTH = 36
BACKLOG = 2  # the contact alerts of P2 and P3


def run(ctx: Context) -> None:
    stack = Stack(ctx, "ops03")
    try:
        Ops03(ctx, stack).execute()
    finally:
        stack.close()


# --------------------------------------------------------------------------------------------
# the transport that stands in for the two providers
# --------------------------------------------------------------------------------------------


class Providers:
    """What the two provider APIs answer, and what they were asked."""

    def __init__(self) -> None:
        self.mode = "healthy"  # healthy | primary_down | both_down
        self.calls: Counter[str] = Counter()
        self.accepted: Counter[str] = Counter()  # notification id -> 200s
        self.accepted_by: dict[str, str] = {}

    def handler(self, request: httpx.Request) -> httpx.Response:
        host = request.url.host
        self.calls[host] += 1
        body: dict[str, Any] = json.loads(request.content or b"{}")
        if host == RESEND_HOST:
            if self.mode == "healthy":
                return self._accept(host, _resend_id(body), {"id": f"re_{uuid.uuid4().hex[:12]}"})
            return httpx.Response(401, json={"message": "API key is invalid"})
        if host == POSTMARK_HOST:
            if self.mode == "both_down":
                return httpx.Response(
                    401, json={"ErrorCode": 10, "Message": "Bad or missing Server API token."}
                )
            return self._accept(
                host,
                str((body.get("Metadata") or {}).get("notification_id", "")),
                {"ErrorCode": 0, "MessageID": uuid.uuid4().hex},
            )
        return httpx.Response(404)

    def _accept(self, host: str, notification_id: str, payload: dict[str, Any]) -> httpx.Response:
        self.accepted[notification_id] += 1
        self.accepted_by[notification_id] = host
        return httpx.Response(200, json=payload)


def _resend_id(body: dict[str, Any]) -> str:
    for tag in body.get("tags", []):
        if tag.get("name") == "notification_id":
            return str(tag.get("value", ""))
    return ""


class Capture(logging.Handler):
    """The structured events of the process (structlog hands the event dict over as ``msg``)."""

    def __init__(self) -> None:
        super().__init__(level=logging.DEBUG)
        self.events: list[dict[str, Any]] = []

    def emit(self, record: logging.LogRecord) -> None:
        if isinstance(record.msg, dict):
            self.events.append(dict(record.msg))


class Clock:
    """The chain's cool-down clock (``time.monotonic`` in production), tied to simulated time."""

    def __init__(self) -> None:
        self.value = 1_000.0

    def __call__(self) -> float:
        return self.value


@contextlib.contextmanager
def _clean_environment() -> Iterator[None]:
    """``Settings`` reads ``AFTERME_*`` from the process: not the caller's shell."""
    saved = {k: v for k, v in os.environ.items() if k.startswith("AFTERME_")}
    for key in saved:
        del os.environ[key]
    try:
        yield
    finally:
        os.environ.update(saved)


# --------------------------------------------------------------------------------------------
# the scenario
# --------------------------------------------------------------------------------------------


class Ops03:
    def __init__(self, ctx: Context, stack: Stack) -> None:
        self.ctx = ctx
        self.s = stack
        self.rep = ctx.report
        self.p: dict[str, Person] = {}
        self.providers = Providers()
        self.capture = Capture()
        self.clock = Clock()
        self.services: AppServices
        self.engine: Engine
        self.dispatcher: Dispatcher
        self.chain: FallbackEmailProvider
        self.stage_times: dict[str, datetime] = {}
        self._block: list[str] = []

    def execute(self) -> None:
        self.ctx.section("OPS-03  Invalid email-provider credentials: retries, fallback, backlog")
        self.ctx.say(
            "Purpose: a provider that refuses our credentials is our fault, never a verdict on\n"
            "the contact. The message must go by the fallback; when both refuse it must stay\n"
            "queued with backoff, the backlog must page, and once the credentials are fixed it\n"
            "must drain with one send per message."
        )
        self.s.create()
        self.s.start_api()  # no worker process: the engine is driven in-process below
        for tag in ("P1", "P2", "P3"):
            self.p[tag] = self.s.people.create(tag)
        asyncio.run(self._drive())

    # ------------------------------------------------------------------ the in-process engine

    def _settings(self) -> Settings:
        db, keys = self.ctx.db, self.ctx.keys
        with _clean_environment():
            return Settings(
                app_env="test",  # type: ignore[arg-type]
                database_url=db.api_url,  # type: ignore[arg-type]
                worker_database_url=db.worker_url,  # type: ignore[arg-type]
                migration_database_url=db.owner_url,  # type: ignore[arg-type]
                maintenance_database_url=db.owner_url,  # type: ignore[arg-type]
                jwt_signing_keys={KID: keys.jwt_pem},  # type: ignore[dict-item]
                jwt_active_kid=KID,
                hmac_pepper=keys.pepper,  # type: ignore[arg-type]
                email_provider="resend",
                email_api_key=RESEND_KEY,  # type: ignore[arg-type]
                email_fallback_provider="postmark",
                email_fallback_api_key=POSTMARK_TOKEN,  # type: ignore[arg-type]
                push_provider="noop",
                argon2_time_cost=1,
                argon2_memory_cost_kib=1024,
                argon2_parallelism=1,
                rate_limit_enabled=False,
                tick_seconds=1,
                log_level="WARNING",
                probe_token=None,
                test_support_enabled=False,
            )

    async def _drive(self) -> None:
        settings = self._settings()
        configure_logging(settings)
        root = logging.getLogger()
        root.handlers = [self.capture]  # quiet: the events are read, not printed
        client = httpx.AsyncClient(transport=httpx.MockTransport(self.providers.handler))
        provider = build_email_provider(settings, client=client)
        if not isinstance(provider, FallbackEmailProvider):
            msg = "the configured chain is not a FallbackEmailProvider"
            raise HarnessError(msg)
        self.chain = provider
        self.chain._clock = self.clock  # the cool-down runs on simulated time
        self.services = build_worker_services(
            settings, clock=OffsetDbClock(), email_provider=provider
        )
        self.engine = Engine(self.services, instance_id="gameday-ops03")
        self.dispatcher = Dispatcher(self.services, push=NoopPushProvider())
        try:
            await self._adapters()
            await self._to_first_alert()
            await self._primary_rejected()
            await self._skip_window()
            await self._both_rejected()
            await self._credentials_fixed()
        finally:
            await self.services.db.dispose()
            await client.aclose()
        self._operator_view()

    async def _pump(self, seconds: int) -> None:
        """Move simulated time (the API's test clock, which the engine's clock reads too), then
        one engine tick and one dispatcher pass, as the worker loop does."""
        self.s.sim.advance(seconds)
        self.clock.value += seconds
        await self.engine.tick()
        await self.dispatcher.dispatch()

    async def _pump_to(self, at: datetime) -> None:
        await self._pump(max(int((at - self.s.sim.now()).total_seconds()) + 1, 1))

    # ------------------------------------------------------------------ what the adapters say

    async def _adapters(self) -> None:
        self.ctx.phase("The two adapters, asked directly with the rejected credentials")
        message = _message("adapter-check@example.invalid")
        resend = ResendEmailProvider(
            api_key=RESEND_KEY,
            client=httpx.AsyncClient(
                transport=httpx.MockTransport(
                    lambda _r: httpx.Response(401, json={"message": "API key is invalid"})
                )
            ),
        )
        postmark = PostmarkEmailProvider(
            api_key=POSTMARK_TOKEN,
            client=httpx.AsyncClient(
                transport=httpx.MockTransport(
                    lambda _r: httpx.Response(401, json={"ErrorCode": 10, "Message": "Bad token."})
                )
            ),
        )
        seen: dict[str, tuple[str, str]] = {}
        for name, adapter in (("resend", resend), ("postmark", postmark)):
            try:
                await adapter.send(message, idempotency_key=f"adapter-{name}")
            except Exception as exc:
                seen[name] = (type(exc).__name__, str(getattr(exc, "code", "")))
        self.rep.check(
            f"{ID}.1",
            "rejected credentials are ProviderUnavailableError at both adapters, never a verdict",
            seen.get("resend") == (ProviderUnavailableError.__name__, "resend_401")
            and seen.get("postmark") == (ProviderUnavailableError.__name__, "postmark_10"),
            expected="ProviderUnavailableError resend_401 / postmark_10",
            actual=str(seen),
            promise=(
                "DEPLOYMENT §9 (adapters answer ProviderUnavailableError: resend_401, postmark_10)"
            ),
        )

    # ------------------------------------------------------------------ driving an incident

    async def _to_first_alert(self) -> None:
        """P1 misses its deadline; its stage runs; its alert is queued and waits out the settle
        delay. P2 and P3 are brought to the same point half an hour later."""
        self.ctx.phase("P1 misses a deadline; the engine opens the incident and runs stage 1")
        obs, sim = self.s.obs, self.s.sim
        p1 = self.p["P1"]
        obs.set_deadline(p1.user_id, sim.now() + timedelta(seconds=60))
        await self._pump(120)
        stage = obs.stage(p1.user_id)
        if stage is None:
            msg = "P1 has no stage action after the deadline"
            raise HarnessError(msg)
        t1 = stage["scheduled_for"]
        deadline_2 = t1 - timedelta(minutes=150)  # their stage falls due at t1 + 30 minutes
        for tag in ("P2", "P3"):
            obs.set_deadline(self.p[tag].user_id, deadline_2)
        await self._pump_to(deadline_2 + timedelta(seconds=10))
        stage_2 = obs.stage(self.p["P2"].user_id)
        if stage_2 is None:
            msg = "P2 has no stage action after the deadline"
            raise HarnessError(msg)
        self.stage_times = {"P1": t1, "P2": stage_2["scheduled_for"]}
        self.providers.mode = "primary_down"
        await self._pump_to(t1 + timedelta(seconds=10))
        alert = obs.notifications(p1.user_id, "contact_alert")
        if len(alert) != 1 or alert[0]["status"] != "queued":
            msg = f"P1's alert is not queued behind the settle delay: {alert}"
            raise HarnessError(msg)
        self.ctx.say(
            "  P1's contact_alert is queued (send_after = stage + 5 min). Resend now refuses"
        )
        self.ctx.say("  the API key (HTTP 401); Postmark is fine.")

    async def _primary_rejected(self) -> None:
        self.ctx.phase("The alert is sent while only the primary provider is rejected")
        obs = self.s.obs
        p1 = self.p["P1"]
        before = Counter(self.providers.calls)
        await self._pump(310)
        row = obs.notifications(p1.user_id, "contact_alert")[0]
        failed = [e for e in self.capture.events if e.get("event") == "email.provider_failed"]
        first = failed[0] if failed else {}
        contact = obs.one(
            "SELECT verification_status FROM trusted_contacts WHERE id = %s", (p1.contact_id,)
        )
        bounced = obs.audit("contact.bounced", p1.user_id)
        resend_calls = self.providers.calls[RESEND_HOST] - before[RESEND_HOST]
        self.rep.check(
            f"{ID}.2",
            "the chain saw ProviderUnavailableError from Resend, not a verdict on the contact",
            first.get("provider") == "resend"
            and first.get("error_class") == ProviderUnavailableError.__name__
            and str(first.get("code")) == "resend_401"
            and contact is not None
            and contact["verification_status"] == "verified"
            and not bounced,
            expected="resend / ProviderUnavailableError / resend_401; contact verified",
            actual=(
                f"{first.get('provider')} / {first.get('error_class')} / {first.get('code')}; "
                f"contact {contact['verification_status'] if contact else None}; "
                f"{len(bounced)} bounces"
            ),
            promise=f"{DOC_ENGINE} (ProviderUnavailableError is never a verdict on the contact)",
        )
        self.rep.check(
            f"{ID}.3",
            "the alert is delivered by the fallback provider, once",
            row["status"] == "sent"
            and row["provider"] == "postmark"
            and self.providers.accepted[str(row["id"])] == 1
            and self.providers.accepted_by.get(str(row["id"])) == POSTMARK_HOST
            and resend_calls >= 1,
            expected="status sent via postmark; one accepted send; Resend asked and refused",
            actual=(
                f"{row['status']} via {row['provider']}; "
                f"accepted x{self.providers.accepted[str(row['id'])]}; "
                f"resend calls {resend_calls}"
            ),
            promise=f"{DOC_ENGINE} (the email fallback provider takes over in the same attempt)",
        )

    async def _skip_window(self) -> None:
        self.ctx.phase("After two failures the failed provider is skipped for 60 seconds")
        # Start from a known place: the cool-down that the dispatcher's own failures may have
        # set has run out, and Resend has failed at least twice in a row since it last worked.
        self.clock.value += COOL_DOWN_SECONDS + 1
        resend0 = self.providers.calls[RESEND_HOST]
        sends = 0
        while not self.chain.degraded and sends < 3:  # noqa: PLR2004
            sends += 1
            await self.chain.send(
                _message(f"skip-{sends}@example.invalid"), idempotency_key=f"skip-{sends}"
            )
        asked = self.providers.calls[RESEND_HOST] - resend0
        degraded = self.chain.degraded
        before_skipped = self.providers.calls[RESEND_HOST]
        postmark_before = self.providers.calls[POSTMARK_HOST]
        await self.chain.send(_message("skipped@example.invalid"), idempotency_key="skipped")
        resend_while_skipped = self.providers.calls[RESEND_HOST] - before_skipped
        postmark_while_skipped = self.providers.calls[POSTMARK_HOST] - postmark_before
        self.clock.value += COOL_DOWN_SECONDS + 1
        recovered = not self.chain.degraded
        before_again = self.providers.calls[RESEND_HOST]
        await self.chain.send(_message("again@example.invalid"), idempotency_key="again")
        asked_again = self.providers.calls[RESEND_HOST] - before_again
        self.rep.check(
            f"{ID}.4",
            "after two failures Resend is skipped for 60 s, then asked again",
            degraded
            and asked <= 2  # noqa: PLR2004
            and resend_while_skipped == 0
            and postmark_while_skipped == 1
            and recovered
            and asked_again == 1,
            expected="skipped: 0 Resend calls, 1 Postmark call; after 61 s: asked again",
            actual=(
                f"degraded={degraded} after {asked} Resend calls; while skipped Resend "
                f"{resend_while_skipped}, Postmark {postmark_while_skipped}; after 61 s: "
                f"recovered={recovered}, Resend {asked_again}"
            ),
            promise=f"{DOC_ENGINE} (after 2 consecutive failures a provider is skipped for 60 s)",
        )
        status = await admin.engine_status(self.services)
        self._block += [
            "-- primary rejected, fallback carrying (python -m cli.admin status):",
            *format_excerpt(status_excerpt(status.as_dict())),
        ]
        self.rep.check(
            f"{ID}.5",
            "status warns that the fallback provider is carrying messages; nothing pages",
            FALLBACK_WARNING in status.warnings
            and status.fallback_sends_15m >= 1
            and status.pages == [],
            expected=f"warning '{FALLBACK_WARNING}'; fallback_sends_15m >= 1",
            actual=(
                f"warnings {status.warnings}; fallback_sends_15m "
                f"{status.fallback_sends_15m}; pages {status.pages}"
            ),
            promise=f"{DOC_RUNBOOK}",
        )

    # ------------------------------------------------------------------ both rejected

    async def _both_rejected(self) -> None:
        self.ctx.phase("Both providers reject: P2's and P3's alerts stay queued with backoff")
        obs, sim = self.s.obs, self.s.sim
        self.providers.mode = "both_down"
        await self._pump_to(self.stage_times["P2"] + timedelta(seconds=10))  # stages run
        await self._pump(310)  # the settle delay passes: the first (failing) attempt
        rows = self._backlog()
        first_attempt = [
            (r["status"], r["attempt_count"], r["next_attempt_at"] is not None) for r in rows
        ]
        self.rep.check(
            f"{ID}.6",
            "with both providers rejecting, the messages stay queued with backoff (not failed)",
            len(rows) == BACKLOG
            and all(r["status"] == "queued" and r["attempt_count"] >= 1 for r in rows)
            and all(r["next_attempt_at"] is not None for r in rows),
            expected="2 contact alerts queued, attempt_count >= 1, next_attempt_at set",
            actual=f"{first_attempt}",
            promise=f"{DOC_ENGINE} (transient for the message: requeued with backoff 1, 2, 4 min)",
        )
        attempts = [r["attempt_count"] for r in rows]
        while (
            "queued message past send_after for 5 minutes"
            not in (await admin.engine_status(self.services)).pages
        ):
            next_at = min(r["next_attempt_at"] for r in self._backlog())
            await self._pump_to(next_at)
            if sim.now() > self.stage_times["P2"] + timedelta(minutes=40):
                break
        rows = self._backlog()
        status = await admin.engine_status(self.services)
        self._block += [
            "",
            "-- both providers rejecting (python -m cli.admin status):",
            *format_excerpt(status_excerpt(status.as_dict())),
        ]
        errors = obs.all("SELECT count(*) AS n FROM notification_logs WHERE outcome = 'error'")
        self.rep.check(
            f"{ID}.7",
            "the backlog pages ('queued message past send_after for 5 minutes'); nothing failed",
            BACKLOG_PAGE in status.pages
            and all(r["status"] == "queued" and r["attempt_count"] > min(attempts) for r in rows)
            and status.failed_messages_7d == 0
            and int(errors[0]["n"]) >= 2,  # noqa: PLR2004
            expected=f"page '{BACKLOG_PAGE}'; still queued; 0 failed; error rows logged",
            actual=(
                f"pages {status.pages}; attempts {[r['attempt_count'] for r in rows]}; "
                f"failed {status.failed_messages_7d}; error rows {errors[0]['n']}"
            ),
            promise=f"{DOC_RUNBOOK} (a paging 'queued message past send_after for 5 minutes')",
        )
        contacts = obs.all(
            "SELECT verification_status FROM trusted_contacts WHERE id = ANY(%s::uuid[])",
            ([self.p["P2"].contact_id, self.p["P3"].contact_id],),
        )
        self.rep.check(
            f"{ID}.8",
            "provider rejection leaves the contacts alone (verified, not bounced)",
            all(c["verification_status"] == "verified" for c in contacts)
            and not obs.audit("contact.bounced"),
            expected="both contacts verified; no contact.bounced audit",
            actual=(
                f"{[c['verification_status'] for c in contacts]}; "
                f"{len(obs.audit('contact.bounced'))} bounces"
            ),
            promise=f"{DOC_ENGINE} (ProviderUnavailableError never marks a contact bounced)",
        )

    def _backlog(self) -> list[dict[str, Any]]:
        return self.s.obs.all(
            "SELECT * FROM notifications WHERE template_key = 'contact_alert' "
            "AND user_id IN (%s, %s) ORDER BY created_at, id",
            (self.p["P2"].user_id, self.p["P3"].user_id),
        )

    # ------------------------------------------------------------------ credentials fixed

    async def _credentials_fixed(self) -> None:
        self.ctx.phase("The credentials are fixed: the backlog drains")
        obs = self.s.obs
        self.providers.mode = "healthy"
        queued = obs.all("SELECT next_attempt_at FROM notifications WHERE status = 'queued'")
        due = max((r["next_attempt_at"] for r in queued if r["next_attempt_at"]), default=None)
        if due is not None:
            await self._pump_to(due)
        await self._pump(5)
        rows = self._backlog()
        still = obs.all(
            "SELECT id FROM notifications WHERE status = 'queued' AND channel = 'email'"
        )
        once = {str(r["id"]): self.providers.accepted[str(r["id"])] for r in rows}
        sent_all = obs.all(
            "SELECT id FROM notifications WHERE status = 'sent' AND channel = 'email'"
        )
        twice = [i for i, n in self.providers.accepted.items() if n > 1 and len(i) == UUID_LENGTH]
        status = await admin.engine_status(self.services)
        self._block += [
            "",
            "-- credentials fixed, backlog drained (python -m cli.admin status):",
            *format_excerpt(status_excerpt(status.as_dict())),
        ]
        self.rep.check(
            f"{ID}.9",
            "the backlog drains: each message sent exactly once, nothing left queued",
            len(rows) == BACKLOG
            and all(r["status"] == "sent" for r in rows)
            and all(n == 1 for n in once.values())
            and not twice
            and not still
            and len(sent_all) >= 3,  # noqa: PLR2004
            expected="P2 and P3 alerts sent, one accepted send each; none twice; 0 queued",
            actual=(
                f"{[r['status'] for r in rows]}; accepted {list(once.values())}; "
                f"{len(twice)} sent twice; {len(still)} still queued"
            ),
            promise=f"{DOC_RUNBOOK} (fix the secret; nothing is lost) and INV-5",
        )
        self.rep.check(
            f"{ID}.10",
            "once drained, no page and no queued-message age remain",
            BACKLOG_PAGE not in status.pages
            and status.oldest_queued_message_age_seconds is None
            and status.pages == [],
            expected="pages []; oldest queued message age none",
            actual=f"pages {status.pages}; age {status.oldest_queued_message_age_seconds}",
            promise=f"{DOC_ENGINE} §12 (oldest queued notification past send_after)",
        )

    # ------------------------------------------------------------------ the runbook excerpt

    def _operator_view(self) -> None:
        self.ctx.block("OPS-03, for DEPLOYMENT §9 'Email provider outage'", self._block)


def _message(to: str) -> EmailMessage:
    return EmailMessage(
        to=to,
        subject="AfterMe game day",
        text="A rehearsal message. Nothing needs doing.\n",
        template="operator_test",
        sender="AfterMe <no-reply@afterme.invalid>",
        html=None,
    )
