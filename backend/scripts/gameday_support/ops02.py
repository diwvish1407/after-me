"""OPS-02: every worker killed for 30 minutes -> heartbeat page -> restart -> correct catch-up
(TEST_PLAN §7; ESCALATION_ENGINE §5.2, §6.7, FS-08; DEPLOYMENT §9 "Worker down").

The real worker is started, run for a healthy minute and SIGKILLed. The test clock then moves
30 simulated minutes over a deadline and two stages while the API stays up. Three people, each
there for one rule of the catch-up (times relative to ``K``, the moment of the kill):

* ``U1`` an incident is open and its stage fell due at K+5: 25 minutes late at the restart,
  more than ``LATE_TOLERANCE_SECONDS`` (300), so it must be put back, not run, and the person
  warned with ``incident_delayed``;
* ``U2`` its stage fell due at K+28: two minutes late, within the tolerance, so it runs as usual;
  its last reminder fell due while the worker was down and is superseded;
* ``U3`` the deadline fell due at K+15, while no worker was running: the incident opens at the
  restart with the anchor at that moment (a full grace period from then).
"""

from __future__ import annotations

import signal
from datetime import datetime, timedelta
from typing import Any

from .checks import (
    format_excerpt,
    minutes_text,
    reconcile_outbox,
    seconds_between,
    status_excerpt,
)
from .procs import HarnessError
from .stack import Context, Stack
from .world import Person

ID = "OPS-02"
REQUIRED = tuple(f"{ID}.{n}" for n in range(1, 16))  # every check id the run must have made
HEARTBEAT_STALE_SECONDS = 120
LATE_TOLERANCE_SECONDS = 300
LATE_SHIFT_MINUTES = 30
RECONCILE_MIN = 6  # sent email rows this run cannot have fewer than
DOWN_STEPS = (180, 600, 600, 420)  # three, ten, ten and seven minutes: thirty in all
DOC_ENGINE = "ESCALATION_ENGINE"
DOC_RUNBOOK = "DEPLOYMENT §9 (Worker down)"


def run(ctx: Context) -> None:
    stack = Stack(ctx, "ops02")
    try:
        Ops02(ctx, stack).execute()
    finally:
        stack.close()


class Ops02:
    def __init__(self, ctx: Context, stack: Stack) -> None:
        self.ctx = ctx
        self.s = stack
        self.rep = ctx.report
        self.p: dict[str, Person] = {}
        self.kill_at: datetime
        self.stage1_at: datetime
        self.stage2_at: datetime
        self.restart_floor: datetime
        self.before: dict[str, int] = {}
        self._down_lines: list[str] = []

    # ------------------------------------------------------------------ the whole scenario

    def execute(self) -> None:
        self.ctx.section("OPS-02  Workers killed for 30 minutes: heartbeat, restart, catch-up")
        self.ctx.say(
            "Purpose: with no worker running nothing may happen and the heartbeat must page; at\n"
            "the restart the engine must give everybody a full grace period (anchor rule), put\n"
            "back a stage that is more than 5 minutes late and tell the person, run a stage that\n"
            "is only slightly late, and send nothing twice."
        )
        self.s.create()
        self.s.start_api()
        self.s.start_worker()
        self._setup()
        self._kill()
        self._downtime()
        self._restart()
        self._catch_up()
        self._later()
        self._exactly_once()
        self._operator_view()

    # ------------------------------------------------------------------ set-up and the kill

    def _setup(self) -> None:
        self.ctx.phase("People, made through the real API; U1 and U2 miss their deadlines")
        sim, obs = self.s.sim, self.s.obs
        for tag in ("U1", "U2", "U3"):
            self.p[tag] = self.s.people.create(tag)
        obs.set_deadline(self.p["U1"].user_id, sim.now() + timedelta(seconds=60))
        sim.step(120)
        sim.wait_until("U1's incident", lambda: obs.open_incident(self.p["U1"].user_id) is not None)
        stage = obs.stage(self.p["U1"].user_id)
        if stage is None:
            msg = "U1 has an incident but no stage action"
            raise HarnessError(msg)
        self.stage1_at = stage["scheduled_for"]
        self.kill_at = self.stage1_at - timedelta(minutes=5)  # K
        deadline_2 = self.kill_at + timedelta(minutes=28) - timedelta(minutes=180)
        obs.set_deadline(self.p["U2"].user_id, deadline_2)
        obs.set_deadline(self.p["U3"].user_id, self.kill_at + timedelta(minutes=15))
        sim.advance(int((deadline_2 + timedelta(seconds=20) - sim.now()).total_seconds()))
        sim.settle()
        sim.wait_until("U2's incident", lambda: obs.open_incident(self.p["U2"].user_id) is not None)
        stage_2 = obs.stage(self.p["U2"].user_id)
        if stage_2 is None:
            msg = "U2 has an incident but no stage action"
            raise HarnessError(msg)
        self.stage2_at = stage_2["scheduled_for"]
        self.ctx.say(
            f"  U1's stage is due at K+5 min ({self.stage1_at:%H:%M:%S}Z), U2's at K+28 min "
            f"({self.stage2_at:%H:%M:%S}Z), U3's deadline at K+15 min."
        )

    def _counts(self) -> dict[str, int]:
        obs = self.s.obs
        return {
            "incidents": int(obs.scalar("SELECT count(*) FROM escalation_incidents")),
            "notifications": int(obs.scalar("SELECT count(*) FROM notifications")),
            "executed_actions": int(
                obs.scalar("SELECT count(*) FROM incident_actions WHERE status = 'executed'")
            ),
            "contact_alerts": int(
                obs.scalar(
                    "SELECT count(*) FROM notifications WHERE template_key = 'contact_alert'"
                )
            ),
        }

    def _kill(self) -> None:
        self.ctx.phase("A healthy minute, then SIGKILL")
        sim, s = self.s.sim, self.s
        sim.advance(int((self.kill_at - timedelta(seconds=60) - sim.now()).total_seconds()))
        sim.settle()
        sim.step(60)
        status = s.admin("status")
        document = status.document or {}
        age = document.get("worker_heartbeat_age_seconds")
        self.rep.check(
            f"{ID}.1",
            "healthy before the kill: the worker's heartbeat is fresh and nothing pages",
            status.code == 0
            and isinstance(age, (int, float))
            and age < HEARTBEAT_STALE_SECONDS
            and document.get("pages") == [],
            expected="status exit 0, heartbeat age < 120 s, no pages",
            actual=f"exit {status.code}, heartbeat age {age}, pages {document.get('pages')}",
            promise=f"{DOC_ENGINE} §12 (heartbeat age > 2 min pages)",
        )
        self.before = self._counts()
        code = s.stop_worker(signal.SIGKILL)
        self.rep.check(
            f"{ID}.2",
            "the worker process is gone after SIGKILL",
            code == -signal.SIGKILL and s.worker_proc is None,
            expected="exit status -9",
            actual=f"exit status {code}",
        )
        self.ctx.say(f"  the worker was killed at {sim.now():%H:%M:%S}Z (K); counts: {self.before}")

    # ------------------------------------------------------------------ the downtime

    def _downtime(self) -> None:
        self.ctx.phase("30 simulated minutes with no worker (the API stays up)")
        sim, s = self.s.sim, self.s
        for index, seconds in enumerate(DOWN_STEPS):
            sim.advance(seconds)
            if index == 0:
                status = s.admin("status")
                document = status.document or {}
                self.rep.check(
                    f"{ID}.3",
                    "three minutes after the kill the heartbeat page is raised",
                    status.code == 1
                    and "worker heartbeat older than 2 minutes" in (document.get("pages") or []),
                    expected="exit 1 with 'worker heartbeat older than 2 minutes'",
                    actual=f"exit {status.code}, pages {document.get('pages')}",
                    promise=f"{DOC_RUNBOOK}; {DOC_ENGINE} §12 (heartbeat age > 2 min pages)",
                )
                self._down_lines = [
                    f"$ python -m cli.admin status    (exit {status.code}, 3 min after the kill)",
                    *format_excerpt(status_excerpt(document)),
                ]
        status = s.admin("status")
        document = status.document or {}
        age = document.get("worker_heartbeat_age_seconds") or 0
        pages = document.get("pages") or []
        self.rep.check(
            f"{ID}.4",
            "after 30 minutes: the heartbeat page and the overdue-stage page are both raised",
            status.code == 1
            and "worker heartbeat older than 2 minutes" in pages
            and "due action not executed for 5 minutes" in pages
            and age >= 25 * 60,
            expected="exit 1; heartbeat and 'due action' pages; heartbeat age >= 25 min",
            actual=f"exit {status.code}; pages {pages}; heartbeat age {minutes_text(float(age))}",
            promise=f"{DOC_ENGINE} §12 (oldest due-but-unexecuted action > 5 min: page)",
        )
        self._down_lines += [
            "",
            f"$ python -m cli.admin status        (exit {status.code}, 30 min after the kill)",
            *format_excerpt(status_excerpt(document)),
        ]
        after = self._counts()
        self.rep.check(
            f"{ID}.5",
            "while down: the API answers and nothing happened (no incident, stage or message)",
            s.api.is_ready() and after == self.before,
            expected=f"API ready; counts unchanged {self.before}",
            actual=f"API ready={s.api.is_ready()}; counts {after}",
            promise=f"{DOC_ENGINE} FS-08 (all workers down: no incidents opened, no actions)",
        )

    # ------------------------------------------------------------------ the restart

    def _restart(self) -> None:
        self.ctx.phase("Restart the worker")
        sim = self.s.sim
        self.restart_floor = sim.now()
        self.s.start_worker()
        obs = self.s.obs
        sim.wait_until(
            "U3's incident to open", lambda: obs.open_incident(self.p["U3"].user_id) is not None
        )
        sim.wait_until(
            "U2's stage to run",
            lambda: (obs.stage(self.p["U2"].user_id) or {}).get("status") == "executed",
        )
        sim.settle()
        self.ctx.say(f"  worker restarted at about {self.restart_floor:%H:%M:%S}Z (K+30 min).")

    def _catch_up(self) -> None:
        obs = self.s.obs
        self.ctx.phase("Catch-up: what the engine did at the restart")
        self._check_u3(obs)
        self._check_u1(obs)
        self._check_u2(obs)

    def _check_u3(self, obs: Any) -> None:
        u3 = self.p["U3"]
        incident = obs.open_incident(u3.user_id)
        assert incident is not None  # noqa: S101 - waited for
        late = seconds_between(incident["missed_due_at"], incident["opened_at"])
        grace = incident["grace_ends_at"] - incident["anchor_at"]
        stage = obs.stage(u3.user_id)
        self.rep.check(
            f"{ID}.6",
            "U3 (deadline passed while down): incident opens at restart, anchor = now, full grace",
            incident["opened_at"] >= self.restart_floor
            and incident["anchor_at"] == incident["opened_at"]
            and grace == timedelta(minutes=180)
            and late >= 14 * 60
            and stage is not None
            and stage["status"] == "pending",
            expected="opened after restart; anchor = opened_at; grace 180 min; stage pending",
            actual=(
                f"opened {seconds_between(self.restart_floor, incident['opened_at']):+.0f}s "
                f"from restart, {minutes_text(late)} after the deadline; "
                f"grace {minutes_text(grace.total_seconds())}; "
                f"stage {stage['status'] if stage else None}"
            ),
            promise=f"{DOC_ENGINE} §5.2 and FS-08 (anchor = max(missed_due_at, opened_at))",
        )

    def _check_u1(self, obs: Any) -> None:
        u1 = self.p["U1"]
        stage = obs.stage(u1.user_id)
        deferred = obs.audit("escalation.stage_deferred", u1.user_id)
        told = [
            n for n in obs.notifications(u1.user_id, "incident_delayed") if n["channel"] == "email"
        ]
        alerts = obs.notifications(u1.user_id, "contact_alert")
        moved_to = stage["scheduled_for"] if stage else None
        late = deferred[0]["metadata"].get("late_seconds") if deferred else None
        self.rep.check(
            f"{ID}.7",
            "U1 (stage 25 min late): not run, put back to now + 30 min, audited with how late",
            stage is not None
            and stage["status"] == "pending"
            and not alerts
            and moved_to is not None
            and moved_to >= self.restart_floor + timedelta(minutes=LATE_SHIFT_MINUTES)
            and len(deferred) == 1
            and isinstance(late, int)
            and late > LATE_TOLERANCE_SECONDS,
            expected="pending at restart+30 min; 0 alerts; one stage_deferred audit, late > 300 s",
            actual=(
                f"stage {stage['status'] if stage else None} moved to "
                f"{moved_to:%H:%M:%S}Z; {len(alerts)} alerts; {len(deferred)} audits late={late}"
                if moved_to
                else "no stage"
            ),
            promise=f"{DOC_ENGINE} §6.7 (a stage more than LATE_TOLERANCE overdue is put back)",
        )
        mails = self.s.mailbox.count(to=u1.email, template="incident_delayed")
        self.rep.check(
            f"{ID}.8",
            "U1 is warned once with incident_delayed (outbox row and mail)",
            len(told) == 1 and mails == 1,
            expected="1 email row and 1 mail",
            actual=f"{len(told)} email rows, {mails} mails",
            promise=f"{DOC_ENGINE} §6.7 point 3 (one incident_delayed message)",
        )

    def _check_u2(self, obs: Any) -> None:
        u2 = self.p["U2"]
        stage = obs.stage(u2.user_id)
        reminders = obs.actions(u2.user_id, "user_reminder")
        stale = [r for r in reminders if r["variant"] == "last_chance"]
        deferred = obs.audit("escalation.stage_deferred", u2.user_id)
        late = (
            seconds_between(stage["scheduled_for"], stage["executed_at"])
            if stage and stage["executed_at"]
            else None
        )
        self.rep.check(
            f"{ID}.9",
            "U2 (stage 2 min late, within 300 s): runs as usual, is not put back",
            stage is not None
            and stage["status"] == "executed"
            and not deferred
            and late is not None
            and 0 < late <= LATE_TOLERANCE_SECONDS,
            expected="stage executed, not deferred, late <= 300 s",
            actual=(
                f"stage {stage['status'] if stage else None}, late {late}s, "
                f"{len(deferred)} deferrals"
            ),
            promise=f"{DOC_ENGINE} §6.7 (only a stage later than the tolerance is put back)",
        )
        self.rep.check(
            f"{ID}.10",
            "U2's reminder that fell due while down is superseded, not sent late",
            len(stale) == 1
            and stale[0]["status"] == "cancelled"
            and (stale[0]["outcome"] or {}).get("reason") == "superseded",
            expected="last_chance reminder cancelled (superseded)",
            actual=f"{[(r['status'], r['outcome']) for r in stale]}",
            promise=f"{DOC_ENGINE} §13.1 note 3 (a reminder after the end of grace is superseded)",
        )

    # ------------------------------------------------------------------ afterwards

    def _later(self) -> None:
        """U2's alert leaves after the settle delay, exactly once; U1's deferred stage runs at
        its new time, exactly once."""
        self.ctx.phase("Time goes on: the settle delay passes, then U1's put-back stage falls due")
        sim, obs = self.s.sim, self.s.obs
        u1, u2 = self.p["U1"], self.p["U2"]
        for _ in range(2):
            sim.step(180)
        mails_u2 = self.s.mailbox.count(to=u2.contact_email, template="contact_alert")
        self.rep.check(
            f"{ID}.11",
            "U2's contact is alerted exactly once, after the settle delay",
            mails_u2 == 1,
            expected="1 contact_alert mail",
            actual=f"{mails_u2} mails",
            promise=f"{DOC_ENGINE} §8.2 and INV-5 (exactly-once effects)",
        )
        stage = obs.stage(u1.user_id)
        assert stage is not None  # noqa: S101
        limit = stage["scheduled_for"] + timedelta(minutes=8)
        while sim.now() < limit:
            sim.step(180)
        mails_u1 = self.s.mailbox.count(to=u1.contact_email, template="contact_alert")
        stage = obs.stage(u1.user_id)
        self.rep.check(
            f"{ID}.12",
            "U1's put-back stage runs at its new time and its contact is alerted exactly once",
            stage is not None and stage["status"] == "executed" and mails_u1 == 1,
            expected="stage executed; 1 contact_alert mail",
            actual=f"stage {stage['status'] if stage else None}; {mails_u1} mails",
            promise=f"{DOC_ENGINE} §6.7 (it can only delay an alert, never drop it)",
        )

    def _exactly_once(self) -> None:
        self.ctx.phase("Nothing twice: the outbox, the mail recording and the audit trail")
        obs = self.s.obs
        rows = obs.all(
            "SELECT n.provider_message_id AS id, n.template_key AS template, "
            "lower(coalesce(c.email_normalized, u.email_normalized)) AS recipient "
            "FROM notifications n LEFT JOIN trusted_contacts c ON c.id = n.contact_id "
            "LEFT JOIN users u ON u.id = n.user_id "
            "WHERE n.status = 'sent' AND n.channel = 'email'"
        )
        sent = [(str(r["id"]), r["template"], r["recipient"]) for r in rows]
        templates = {
            r["template_key"] for r in obs.all("SELECT DISTINCT template_key FROM notifications")
        }
        problems = reconcile_outbox(sent, self.s.mailbox.files(), templates, minimum=RECONCILE_MIN)
        self.rep.check(
            f"{ID}.13",
            "each sent outbox row has exactly one mail by provider id; no stray or repeated mail",
            not problems,
            expected=f">= {RECONCILE_MIN} sent rows, each matched to one mail file; no stray mail",
            actual="; ".join(problems[:3]) or f"{len(sent)} rows, all matched",
            promise=f"{DOC_ENGINE} INV-5 and §8.3 (exactly-once effects)",
        )
        twice = obs.all(
            "SELECT i.id FROM escalation_incidents i WHERE "
            "(SELECT count(*) FROM audit_logs a WHERE a.action = 'escalation.stage_executed' "
            " AND a.resource_id = i.id) > "
            "(SELECT count(*) FROM incident_actions x WHERE x.incident_id = i.id "
            " AND x.kind = 'execute_stage' AND x.status = 'executed') "
            "OR (SELECT count(*) FROM audit_logs a WHERE a.action = 'escalation.reminder_sent' "
            " AND a.resource_id = i.id) > "
            "(SELECT count(*) FROM incident_actions x WHERE x.incident_id = i.id "
            " AND x.kind = 'user_reminder' AND x.status = 'executed')"
        )
        held = int(obs.scalar("SELECT count(*) FROM incident_actions WHERE status = 'held'"))
        self.rep.check(
            f"{ID}.14",
            "no action executed twice; none held",
            not twice and held == 0,
            expected="executions in the audit trail == executed actions; 0 held",
            actual=f"{len(twice)} incidents with extra executions; {held} held",
            promise=f"{DOC_ENGINE} INV-5",
        )
        status = self.s.admin("status")
        document = status.document or {}
        age = document.get("worker_heartbeat_age_seconds")
        self.rep.check(
            f"{ID}.15",
            "final: heartbeat fresh again, nothing pages",
            status.code == 0
            and document.get("pages") == []
            and isinstance(age, (int, float))
            and age < HEARTBEAT_STALE_SECONDS,
            expected="exit 0, pages [], heartbeat age < 120 s",
            actual=f"exit {status.code}, pages {document.get('pages')}, heartbeat age {age}",
            promise=f"{DOC_RUNBOOK} (restart; check heartbeats; no held actions)",
        )
        self._final = status_excerpt(document)

    def _operator_view(self) -> None:
        obs = self.s.obs
        deferred = obs.audit("escalation.stage_deferred", self.p["U1"].user_id)
        lines = [*self._down_lines, ""]
        for row in deferred:
            at = f"{row['occurred_at']:%H:%M:%S}Z"
            lines.append(f"audit escalation.stage_deferred  {at}  {row['metadata']}")
        lines += ["", "$ python -m cli.admin status        (after the restart and catch-up)"]
        lines += format_excerpt(self._final)
        self.ctx.block("OPS-02, for DEPLOYMENT §9 'Worker down'", lines)
