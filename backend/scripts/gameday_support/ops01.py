"""OPS-01: ingress outage -> Hold -> recovery -> shift (TEST_PLAN §7; ESCALATION_ENGINE §7;
DEPLOYMENT §9 "Hold entered (ingestion)").

One outage, rehearsed against the real API and the real worker with the test clock. The monitor
path is down for 15 simulated minutes (no probe); from minute 7 the API process is killed too, so
nobody can check in. Five people, each there for one reason:

* ``B``  an incident is open and its stage falls due one minute after the last good probe: the
  stage runs before the worker could know (the undetected window), then the Hold is found
  and backdated, and the stage is rolled back and shifted when the Hold ends;
* ``B2`` the same, but the person checks in while the monitor path is down and the API is up;
* ``A``  the deadline falls in the middle of the outage while the API is down: nobody can check
  in, and no incident may open during the Hold;
* ``A2`` the deadline falls inside the outage while the API is still up, and the person checks
  in after it passed (the Hold kept the incident from opening);
* ``R``  a pre-deadline reminder falls inside the Hold: user messages go on.

Times are given relative to ``L``, the last good probe.
"""

from __future__ import annotations

import signal
from collections import Counter
from datetime import datetime, timedelta
from math import ceil

from .checks import (
    close_to,
    count_differences,
    expected_shift,
    format_excerpt,
    held_back,
    minutes_text,
    not_before_full_grace,
    reconcile_outbox,
    seconds_between,
    status_excerpt,
)
from .procs import HarnessError
from .stack import Context, Stack
from .world import Person, Row

ID = "OPS-01"
REQUIRED = tuple(  # every check id the run must have made
    f"{ID}.{n}"
    for n in (
        [
            "1",
            "2",
            "3",
            "4",
            "4b",
            "5",
            "6",
            "7.9",
            "7.14",
            "8",
            "9",
            "9b",
            "10",
            "11",
            "12",
            "13",
            "13b",
            "14",
            "15",
            "15b",
            "16",
            "17",
        ]
    )
)
STALE_SECONDS = 180  # INGESTION_STALE_SECONDS
FRESH_SECONDS = 600  # HOLD_EXIT_FRESH_SECONDS
BUFFER_MINUTES = 30  # HOLD_RECOVERY_BUFFER_MINUTES
SETTLE_SECONDS = 300  # SETTLE_DELAY_SECONDS
GRACE_MINUTES = 60  # a custom time: the test accounts are made premium, as `user set-tier` does
GRACE = timedelta(minutes=GRACE_MINUTES)
CONTACT_FACING_AFTER = 360  # seconds past the settle delay the run keeps going for an alert
HEALTHY_MINUTES = 8
OUTAGE_STEPS = [75] + [60] * 14  # fifteen minutes and fifteen seconds, in one-minute steps
CHECKIN_B2_STEP = 5
CHECKIN_A2_STEP = 7  # then the API is killed
A_QUIET_STEPS = (9, 14)
RECONCILE_MIN = 8  # sent email rows a run of this length cannot have fewer than
HELD_STEP = 9  # B's message is past its send_after (about L+375 s) and the Hold is open
REMINDER_STEP = 11
RECOVERY_STEPS = 16
LATE_TICKS = 150  # a stage that runs "on time" starts within two steps of its time
DOC_ENGINE = "ESCALATION_ENGINE"
DOC_RUNBOOK = "DEPLOYMENT §9 (Hold entered, ingestion)"
HTTP_OK = 200


def run(ctx: Context) -> None:
    stack = Stack(ctx, "ops01")
    try:
        Ops01(ctx, stack).execute()
    finally:
        stack.close()


class Ops01:
    def __init__(self, ctx: Context, stack: Stack) -> None:
        self.ctx = ctx
        self.s = stack
        self.rep = ctx.report
        self.p: dict[str, Person] = {}
        self.stage_at: datetime
        self.last_probe: datetime
        self.first_fresh: datetime
        self.shifted_to: datetime | None = None
        self.hold_seen: datetime | None = None
        self._outage_lines: list[str] = []
        self._final: dict[str, object] = {}

    # ------------------------------------------------------------------ the whole scenario

    def execute(self) -> None:
        self.ctx.section("OPS-01  Ingress outage: Hold, recovery, shift")
        self.ctx.say(
            "Purpose: when the probe path stops, the worker must enter a Hold (backdated to the\n"
            "last good probe) and nothing may reach a contact; when the probes are back the Hold\n"
            "must end by itself, take back what ran undetected and move every deadline by the\n"
            "Hold's length plus 30 minutes, so that nobody is alerted wrongly. Then the system\n"
            "must still work: a later miss still escalates."
        )
        self.s.create()
        self.s.start_api()
        self.s.start_worker()
        self._people()
        self._open_incidents()
        self._enable_monitoring()
        self._healthy_period()
        self._outage()
        self._recovery()
        self._afterwards()
        self._operator_view()

    # ------------------------------------------------------------------ set-up

    def _people(self) -> None:
        self.ctx.phase("People, made through the real API")
        for tag, lead in (("A", 0), ("A2", 0), ("B", 0), ("B2", 0), ("R", 30)):
            self.p[tag] = self.s.people.create(tag, reminder_lead=lead, grace_minutes=GRACE_MINUTES)
        self.ctx.say("  A, A2, B, B2 and R each have one verified contact, a one-stage plan (grace")
        self.ctx.say("  60 minutes) and an active daily schedule.")

    def _open_incidents(self) -> None:
        self.ctx.phase("B and B2 miss a deadline (monitoring is not on yet)")
        sim, obs = self.s.sim, self.s.obs
        for tag in ("B", "B2"):
            obs.set_deadline(self.p[tag].user_id, sim.now() + timedelta(seconds=60))
        sim.step(120)
        sim.wait_until(
            "incidents for B and B2",
            lambda: all(obs.open_incident(self.p[t].user_id) for t in ("B", "B2")),
        )
        stage = obs.stage(self.p["B"].user_id)
        if stage is None:
            msg = "B has an incident but no stage action"
            raise HarnessError(msg)
        self.stage_at = stage["scheduled_for"]
        self.ctx.say(f"  incidents open; stage 1 of B is due at {self.stage_at:%H:%M:%S}Z.")

    def _enable_monitoring(self) -> None:
        """DEPLOYMENT §4: ``PROBE_TOKEN`` turns the ingestion trigger on. The API and worker are
        restarted with it, and a first probe arrives before the worker's first tick, so the
        start itself is not a Hold."""
        self.ctx.phase("Configure the probe token (restart API and worker with it)")
        sim, s = self.s.sim, self.s
        target = self.stage_at - timedelta(minutes=HEALTHY_MINUTES)
        sim.advance(int((target - sim.now()).total_seconds()))
        sim.settle()
        s.stop_worker()
        s.stop_api()
        s.start_api(monitored=True)
        s.api.probe(self.ctx.keys.probe_token)
        s.start_worker(monitored=True)
        sim.settle()
        holds = s.obs.holds()
        if holds:
            msg = f"a Hold exists before the outage began: {holds[0]['reason']}"
            raise HarnessError(msg)

    # ------------------------------------------------------------------ the healthy period

    def _healthy_period(self) -> None:
        self.ctx.phase(f"Healthy: a probe every simulated minute for {HEALTHY_MINUTES} minutes")
        sim, obs, s = self.s.sim, self.s.obs, self.s
        target = self.stage_at - timedelta(seconds=60)
        sent = 1
        while (target - sim.now()).total_seconds() > 60:  # noqa: PLR2004
            sim.step(60, probe=True)
            sent += 1
        sim.step(max(1, ceil((target - sim.now()).total_seconds())), probe=True)
        sent += 1
        self.last_probe = obs.scalar("SELECT max(received_at) FROM ingestion_probes")
        for tag, minutes in (("A", 8), ("A2", 6), ("R", 40)):
            obs.set_deadline(self.p[tag].user_id, self.last_probe + timedelta(minutes=minutes))
        status = s.admin("status")
        document = status.document or {}
        holds = len(obs.holds())
        self.rep.check(
            f"{ID}.1",
            "healthy: probes arrive, no Hold, nothing pages",
            holds == 0 and status.code == 0 and document.get("pages") == [],
            expected="no Hold; status exit 0, no pages",
            actual=f"{holds} holds; status exit {status.code}, pages {document.get('pages')}",
            promise=DOC_RUNBOOK,
        )
        self.ctx.say(f"  {sent} probes sent; the last good probe L = {self.last_probe:%H:%M:%S}Z.")
        self.ctx.say("  B and B2: stage 1 at L+1 min. Deadlines: A at L+8, A2 at L+6, R at L+40.")

    # ------------------------------------------------------------------ the outage

    def _outage(self) -> None:
        self.ctx.phase("Outage: no probes for 15 simulated minutes, in one-minute steps")
        s = self.s
        for k, seconds in enumerate(OUTAGE_STEPS, start=1):
            at = s.sim.step(seconds)
            self._note_hold(k, at)
            if k == CHECKIN_B2_STEP:
                self._b2_checks_in()
            if k == CHECKIN_A2_STEP:
                self._a2_checks_in()
                self.ctx.say(f"  L+{k} min: the API process is killed (the ingress is gone).")
                s.stop_api(signal.SIGKILL)
            if k in A_QUIET_STEPS:
                self._a_is_quiet(k)
            if k == HELD_STEP:
                self._b_message_held()
            if k == REMINDER_STEP:
                self._r_was_reminded()
        s.start_api()
        s.api.probe(self.ctx.keys.probe_token)
        self.first_fresh = s.obs.scalar("SELECT max(received_at) FROM ingestion_probes")
        self.ctx.say(f"  L+15 min: API back, first fresh probe at {self.first_fresh:%H:%M:%S}Z.")

    def _note_hold(self, k: int, at: datetime) -> None:
        if self.hold_seen is not None:
            return
        holds = self.s.obs.holds()
        if not holds:
            return
        self.hold_seen = at
        hold = holds[0]
        self.ctx.say(f"  L+{k} min: the worker entered a Hold (reason {hold['reason']}).")
        self._hold_checks(hold)

    def _hold_checks(self, hold: Row) -> None:
        obs = self.s.obs
        started = seconds_between(self.last_probe, hold["started_at"])
        detected = seconds_between(self.last_probe, hold["detected_at"])
        self.rep.check(
            f"{ID}.2",
            "the worker enters an ingestion Hold, backdated to the last good probe",
            hold["reason"] == "ingestion"
            and close_to(hold["started_at"], self.last_probe, 1.0)
            and STALE_SECONDS < detected <= STALE_SECONDS + 90,
            expected=f"ingestion, started_at = L, detected after L+{STALE_SECONDS}s",
            actual=f"{hold['reason']}, started_at L{started:+.0f}s, detected L+{detected:.0f}s",
            promise=f"{DOC_ENGINE} §7.2 (Hold starts if the latest probe is stale; backdated)",
        )
        status = self.s.admin("status")
        hold_status = self.s.admin("hold", "status")
        document = status.document or {}
        held = hold_status.document or {}
        self._outage_lines = [
            f"$ python -m cli.admin status          (exit {status.code})",
            *format_excerpt(status_excerpt(document)),
            f"$ python -m cli.admin hold status     (exit {hold_status.code})",
            *format_excerpt(status_excerpt(held)),
        ]
        self.rep.check(
            f"{ID}.3",
            "operator view: status pages 'hold active'; hold status names the ingestion Hold",
            status.code == 1
            and "hold active" in (document.get("pages") or [])
            and held.get("hold_active") is True
            and held.get("hold_reasons") == ["ingestion"],
            expected="status exit 1 with 'hold active'; hold_reasons ['ingestion']",
            actual=f"status exit {status.code}, pages {document.get('pages')}; "
            f"reasons {held.get('hold_reasons')}",
            promise=f"{DOC_RUNBOOK}; {DOC_ENGINE} §12 (Hold active pages)",
        )
        stage = obs.stage(self.p["B"].user_id)
        executed = stage is not None and stage["status"] == "executed"
        self.rep.check(
            f"{ID}.4",
            "B's stage ran before the Hold was known (the undetected window)",
            executed and obs.open_incident(self.p["B"].user_id) is not None,
            expected="stage executed before the Hold was detected",
            actual=f"stage {stage['status'] if stage else None}",
        )

    def _b_message_held(self) -> None:
        """Asserted only once B's alert is past its ``send_after`` with the Hold open, so that
        "nothing left" cannot be true merely because it was not yet due."""
        obs, b = self.s.obs, self.p["B"]
        now = self.s.sim.now()
        due = [
            n
            for n in obs.notifications(b.user_id, "contact_alert")
            if n["send_after"] <= now - timedelta(seconds=30)
        ]
        incident = obs.open_incident(b.user_id) or {}
        mails = self.s.mailbox.count(to=b.contact_email, template="contact_alert")
        hold_open = any(h["ended_at"] is None for h in obs.holds())
        problems = held_back(due, mails, incident.get("contacts_messaged_at"), hold_open=hold_open)
        self.rep.check(
            f"{ID}.4b",
            "B's alert is past its send_after, the Hold is open, and it was held back",
            not problems,
            expected="a due alert still queued; 0 mails; contacts_messaged_at null",
            actual="; ".join(problems) or f"{len(due)} due alert(s) queued, 0 mails",
            promise=f"{DOC_ENGINE} §7.3 (nothing contact-facing is sent while in Hold, INV-10)",
        )

    def _b2_checks_in(self) -> None:
        b2 = self.p["B2"]
        response = self.s.people.check_in(b2)
        body = response.json() if response.status_code == HTTP_OK else {}
        incidents = self.s.obs.incidents(b2.user_id)
        alerts = self.s.obs.notifications(b2.user_id, "contact_alert")
        mails = self.s.mailbox.count(to=b2.contact_email, template="contact_alert")
        state = incidents[0] if incidents else {}
        self.rep.check(
            f"{ID}.5",
            "monitor path down, API up: B2's I'M OK is accepted and nobody is told",
            response.status_code == HTTP_OK
            and body.get("incident_resolved") is True
            and state.get("status") == "resolved"
            and state.get("closed_by") == "user_checkin"
            and len(alerts) >= 1
            and all(a["status"] == "cancelled" for a in alerts)
            and mails == 0,
            expected="200, incident resolved by user_checkin, alert cancelled, 0 mails",
            actual=(
                f"HTTP {response.status_code}; incident {state.get('status')}; "
                f"alerts {[a['status'] for a in alerts]}; {mails} mails"
            ),
            promise="ESCALATION_ENGINE §4.2, §9.1 (a check-in before contact resolves quietly)",
        )

    def _a2_checks_in(self) -> None:
        a2 = self.p["A2"]
        obs = self.s.obs
        passed = obs.config(a2.user_id)["next_due_at"] <= self.s.sim.now()
        response = self.s.people.check_in(a2)
        config = obs.config(a2.user_id)
        incidents = len(obs.incidents(a2.user_id))
        self.rep.check(
            f"{ID}.6",
            "A2's deadline passed inside the Hold; the I'M OK afterwards is accepted",
            passed
            and response.status_code == HTTP_OK
            and incidents == 0
            and config["status"] == "active"
            and config["next_due_at"] > self.s.sim.now(),
            expected="deadline passed; 200; no incident; schedule restarted",
            actual=(
                f"deadline passed={passed}; HTTP {response.status_code}; "
                f"{incidents} incidents; status {config['status']}"
            ),
            promise=f"{DOC_ENGINE} §7.3 (no incident is opened while in Hold; deadlines wait)",
        )

    def _a_is_quiet(self, k: int) -> None:
        a = self.p["A"]
        config = self.s.obs.config(a.user_id)
        passed = config["next_due_at"] <= self.s.sim.now()
        incidents = len(self.s.obs.incidents(a.user_id))
        if k == A_QUIET_STEPS[0]:
            self.ctx.say(f"  L+{k} min: A's deadline has passed with the API down; nothing opens.")
        self.rep.check(
            f"{ID}.7.{k}",
            f"L+{k}: A's deadline passed during the Hold and no incident is open",
            passed and incidents == 0 and config["status"] == "active",
            expected="deadline passed, status active, 0 incidents",
            actual=f"passed={passed}; status {config['status']}; {incidents} incidents",
            promise=f"{DOC_ENGINE} §7.3 (no incident is opened while in Hold, INV-10)",
        )

    def _r_was_reminded(self) -> None:
        r = self.p["R"]
        hold = self.s.obs.holds()[0]
        rows = self.s.obs.notifications(r.user_id, "checkin_pre_reminder")
        sent = [n for n in rows if n["status"] == "sent" and n["channel"] == "email"]
        mails = self.s.mailbox.count(to=r.email, template="checkin_pre_reminder")
        inside = (
            bool(sent)
            and hold["ended_at"] is None
            and all(n["sent_at"] >= hold["detected_at"] for n in sent)
        )
        self.rep.check(
            f"{ID}.8",
            "user reminders continue during the Hold (R's pre-deadline reminder is sent)",
            inside and mails >= 1,
            expected="pre-reminder email sent while the Hold is open",
            actual=f"{len(sent)} sent rows, {mails} mails, hold open={hold['ended_at'] is None}",
            promise=f"{DOC_ENGINE} §7.3 (user reminders continue)",
        )

    # ------------------------------------------------------------------ recovery

    def _recovery(self) -> None:
        self.ctx.phase("Recovery: probes resume, a probe every simulated minute")
        sim, obs = self.s.sim, self.s.obs
        ended: Row | None = None
        for minute in range(1, RECOVERY_STEPS + 1):
            sim.step(60, probe=True)
            row = obs.holds()[0]
            if row["ended_at"] is not None:
                ended = row
                self.ctx.say(f"  {minute} minutes of fresh probes: the Hold ended by itself.")
                break
        if ended is None:
            self.rep.check(
                f"{ID}.9",
                "the Hold exits automatically once probes are fresh",
                False,
                expected=f"Hold ended within {RECOVERY_STEPS} minutes of fresh probes",
                actual="still open",
                promise=f"{DOC_ENGINE} §7.2 (automatic exit)",
            )
            msg = "the Hold did not end; the rest of OPS-01 cannot be rehearsed"
            raise HarnessError(msg)
        sim.wait_until(
            "the Hold's exit to be processed",
            lambda: obs.holds()[0]["exit_processed_at"] is not None,
            timeout=40,
        )
        sim.settle()
        ended = obs.holds()[0]
        by_operator = len(obs.audit("operator.hold_exit"))
        processed = ended["exit_processed_at"] is not None
        self.rep.check(
            f"{ID}.9",
            "the Hold exits automatically once probes are fresh again (no operator action)",
            ended["reason"] == "ingestion" and by_operator == 0 and processed,
            expected="ingestion Hold ended and processed; 0 operator.hold_exit audit rows",
            actual=f"{ended['reason']} Hold; {by_operator} operator exits; processed={processed}",
            promise=f"{DOC_ENGINE} §7.2 (ingestion Hold: exit is automatic)",
        )
        fresh = seconds_between(self.first_fresh, ended["ended_at"])
        self.rep.check(
            f"{ID}.9b",
            "...and only after probes were fresh for the documented 10 continuous minutes",
            FRESH_SECONDS <= fresh <= FRESH_SECONDS + 120,
            expected=f"ended >= {FRESH_SECONDS // 60} min after the first fresh probe",
            actual=f"ended {minutes_text(fresh)} after the first fresh probe",
            promise=(
                "ESCALATION_ENGINE §7.2 and DEPLOYMENT §9 (exit after probes have been fresh for "
                "10 continuous minutes); code: app/engine/hold.py HoldMonitor._auto_exit"
            ),
        )

    # ------------------------------------------------------------------ after the Hold

    def _afterwards(self) -> None:
        self.ctx.phase("After the Hold: what was taken back, what moved, who was told")
        obs = self.s.obs
        hold = obs.holds()[0]
        exited = obs.audit("system.hold_exited")
        document = self.s.admin("hold", "status").document or {}
        self.rep.check(
            f"{ID}.10",
            "audit system.hold_exited once; hold status: no Hold, no exit pending",
            len(exited) == 1
            and document.get("hold_active") is False
            and document.get("hold_exit_pending") == 0,
            expected="1 hold_exited row; hold_active false; hold_exit_pending 0",
            actual=(
                f"{len(exited)} rows (metadata {exited[0]['metadata'] if exited else None}); "
                f"active={document.get('hold_active')} pending={document.get('hold_exit_pending')}"
            ),
            promise=f"{DOC_RUNBOOK} (verify system.hold_exited and the shift counts)",
        )
        self._shift_checks(hold)
        self._anchor_checks(hold)
        self._r_checks_in()
        self._finish()

    def _r_checks_in(self) -> None:
        """R got its reminder inside the Hold and checks in before the deadline: nobody is
        ever alerted about R, whatever happens next."""
        r = self.p["R"]
        response = self.s.people.check_in(r)
        incidents = len(self.s.obs.incidents(r.user_id))
        self.rep.check(
            f"{ID}.13b",
            "R checks in after the Hold: accepted, no incident",
            response.status_code == HTTP_OK and incidents == 0,
            expected="200; 0 incidents",
            actual=f"HTTP {response.status_code}; {incidents} incidents",
        )

    def _shift_checks(self, hold: Row) -> None:
        obs = self.s.obs
        b = self.p["B"]
        stage = obs.stage(b.user_id)
        want = expected_shift(hold["started_at"], hold["ended_at"], BUFFER_MINUTES)
        alerts = obs.notifications(b.user_id, "contact_alert")
        first = alerts[0] if alerts else {}
        moved = (
            stage["scheduled_for"] - stage["original_scheduled_for"] if stage is not None else None
        )
        self.shifted_to = stage["scheduled_for"] if stage else None
        self.rep.check(
            f"{ID}.11",
            "B's stage was rolled back (message cancelled) and shifted by Hold + 30 min",
            stage is not None
            and stage["status"] in ("pending", "executed")
            and moved == want
            and first.get("status") == "cancelled"
            and first.get("cancelled_reason") == "hold_rollback",
            expected=f"moved by {minutes_text(want.total_seconds())}; first alert hold_rollback",
            actual=(
                f"moved by {minutes_text(moved.total_seconds()) if moved else None}; "
                f"first alert {first.get('status')}/{first.get('cancelled_reason')}"
            ),
            promise=f"{DOC_ENGINE} §7.3 (roll back undelivered effects; shift by window + buffer)",
        )
        notices = self.s.mailbox.count(to=b.email, template="service_interruption")
        alerts_sent = self.s.mailbox.count(to=b.contact_email, template="contact_alert")
        self.rep.check(
            f"{ID}.12",
            "B is told about the interruption (service_interruption); no alert left",
            notices >= 1 and alerts_sent == 0,
            expected="a service_interruption mail to B; 0 contact_alert mails",
            actual=f"{notices} notices; {alerts_sent} alerts",
            promise=f"{DOC_ENGINE} §7.3 step 3 (each affected user is told)",
        )

    def _anchor_checks(self, hold: Row) -> None:
        obs = self.s.obs
        a = self.p["A"]
        self.s.sim.wait_until(
            "A's incident to open after the Hold",
            lambda: obs.open_incident(a.user_id) is not None,
            timeout=40,
        )
        incident = obs.open_incident(a.user_id)
        if incident is None:  # pragma: no cover - waited for
            msg = "A's incident vanished"
            raise HarnessError(msg)
        grace = incident["grace_ends_at"] - incident["opened_at"]
        after = seconds_between(hold["exit_processed_at"], incident["opened_at"])
        alerts = self.s.mailbox.count(to=a.contact_email, template="contact_alert")
        self.rep.check(
            f"{ID}.13",
            "A's incident opens only after the exit is processed, with a full grace period",
            incident["opened_at"] >= hold["exit_processed_at"]
            and incident["anchor_at"] == incident["opened_at"]
            and grace == GRACE
            and alerts == 0,
            expected="opened_at >= exit; anchor = opened_at; grace 60 min; 0 alerts",
            actual=(
                f"opened {after:+.0f}s from exit; grace {minutes_text(grace.total_seconds())}; "
                f"anchor==opened {incident['anchor_at'] == incident['opened_at']}; {alerts} alerts"
            ),
            promise="ESCALATION_ENGINE §5.2, §7.3 (anchor rule: a full grace after the Hold)",
        )

    def _finish(self) -> None:
        """The system is not stuck: B's shifted stage runs, once, and Mom is told once. The run
        then goes on until A's alert is due too, so that "no early or wrongful alert" is judged
        after every alert that could have left had time to."""
        sim, obs = self.s.sim, self.s.obs
        b, a = self.p["B"], self.p["A"]
        a_stage = obs.stage(a.user_id)
        due = [t for t in (self.shifted_to, a_stage["scheduled_for"] if a_stage else None) if t]
        limit = max(due or [sim.now()]) + timedelta(seconds=SETTLE_SECONDS + CONTACT_FACING_AFTER)
        while sim.now() < limit:
            alerted = [
                self.s.mailbox.count(to=p.contact_email, template="contact_alert") >= 1
                for p in (b, a)
            ]
            if all(alerted):
                break
            sim.step(120, probe=True)
        sim.step(60, probe=True)
        sim.settle()
        self._b_escalated()
        self._no_wrongful_alert()
        self._reconciled()

    def _b_escalated(self) -> None:
        obs, b = self.s.obs, self.p["B"]
        stage = obs.stage(b.user_id)
        alerts = obs.notifications(b.user_id, "contact_alert")
        sent = [n for n in alerts if n["status"] == "sent"]
        mails = self.s.mailbox.count(to=b.contact_email, template="contact_alert")
        late = None
        if stage is not None and stage["executed_at"] is not None:
            late = seconds_between(stage["scheduled_for"], stage["executed_at"])
        self.rep.check(
            f"{ID}.14",
            "a later miss still escalates: B's shifted stage runs on time, Mom hears once",
            stage is not None
            and stage["status"] == "executed"
            and late is not None
            and 0 <= late <= LATE_TICKS
            and len(sent) == 1
            and mails == 1,
            expected="stage executed at its shifted time (+-2 min); 1 alert sent; 1 mail",
            actual=(
                f"stage {stage['status'] if stage else None}, late {late}s; "
                f"{len(sent)} sent; {mails} mails"
            ),
            promise="ESCALATION_ENGINE §7.3 (deadlines are processed normally once the Hold ends)",
        )

    def _no_wrongful_alert(self) -> None:
        """Every mail that reached any contact mailbox, whatever its template: B's contact got
        one alert (its shifted stage), A's got one (after A's full grace, not before), and
        nobody else's got anything but its invitation. Read after both alerts were due and
        their settle delay passed, so that a leak would have shown."""
        obs = self.s.obs
        contacts = {p.contact_email.lower(): tag for tag, p in self.p.items()}
        actual: Counter[tuple[str, str]] = Counter()
        for _, template, recipient in self.s.mailbox.files():
            if recipient in contacts and template != "contact_invitation":
                actual[(contacts[recipient], template)] += 1
        expected = {("B", "contact_alert"): 1, ("A", "contact_alert"): 1}
        problems = count_differences(actual, expected)
        self.rep.check(
            f"{ID}.15",
            "no wrongful message to any contact (all templates, all mailboxes)",
            not problems,
            expected="B: 1 contact_alert, A: 1 (after its grace); A2, B2, R: nothing",
            actual="; ".join(problems) or str(dict(actual)),
            promise="ESCALATION_ENGINE §2 INV-10 and the principle: fail-safe, not fail-trigger",
        )
        a = self.p["A"]
        incident = obs.open_incident(a.user_id) or (obs.incidents(a.user_id) or [{}])[0]
        rows = [n for n in obs.notifications(a.user_id, "contact_alert") if n["status"] == "sent"]
        sent_at = rows[0]["sent_at"] if rows else None
        late_enough = (
            sent_at is not None
            and "anchor_at" in incident
            and not_before_full_grace(
                sent_at,
                incident["anchor_at"],
                grace_minutes=GRACE_MINUTES,
                settle_seconds=SETTLE_SECONDS,
            )
        )
        self.rep.check(
            f"{ID}.15b",
            "A's alert left no earlier than anchor + full grace + settle delay (INV-8)",
            bool(late_enough),
            expected="sent_at >= anchor_at + 60 min + 5 min",
            actual=(
                f"sent {seconds_between(incident['anchor_at'], sent_at) / 60:.1f} min after the "
                "anchor"
                if sent_at is not None and "anchor_at" in incident
                else "A's alert was never sent"
            ),
            promise="ESCALATION_ENGINE §2 INV-8 and §5.2 (the full grace is measured from opening)",
        )

    def _reconciled(self) -> None:
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
            f"{ID}.17",
            "each sent outbox row has exactly one mail by provider id; no stray mail",
            not problems,
            expected=f">= {RECONCILE_MIN} sent rows, each matched to one mail file; no stray mail",
            actual="; ".join(problems[:3]) or f"{len(sent)} rows, all matched",
            promise="ESCALATION_ENGINE INV-5 and §8.3 (exactly-once effects)",
        )
        status = self.s.admin("status")
        document = status.document or {}
        self.rep.check(
            f"{ID}.16",
            "final: status exits 0 with no page (nothing held, nothing queued past due)",
            status.code == 0 and document.get("pages") == [],
            expected="exit 0, pages []",
            actual=f"exit {status.code}, pages {document.get('pages')}",
            promise=DOC_RUNBOOK,
        )
        self._final = status_excerpt(document)

    # ------------------------------------------------------------------ the runbook excerpt

    def _operator_view(self) -> None:
        obs = self.s.obs
        lines = [*self._outage_lines, ""]
        for row in obs.audit("system.hold_entered"):
            lines.append(
                f"audit system.hold_entered  {row['occurred_at']:%H:%M:%S}Z  {row['metadata']}"
            )
        for row in obs.audit("system.hold_exited"):
            lines.append(
                f"audit system.hold_exited   {row['occurred_at']:%H:%M:%S}Z  {row['metadata']}"
            )
        lines += ["", "$ python -m cli.admin status          (after recovery)"]
        lines += format_excerpt(self._final)
        self.ctx.block("OPS-01, for DEPLOYMENT §9 'Hold entered (ingestion)'", lines)
