"""The safety gate (ESCALATION_ENGINE §6.4). Pure decision logic.

The executor gathers the facts inside the per-user transaction, after locking, and asks
:func:`decide` whether an action may run. Every check fails *safe*: anything uncertain means the
action does not run, and there is no "execute anyway" path (INV-4).

The per-target checks G7 and G8 do not decide whether the action runs; they *narrow* what it
does (INV-7): see :func:`contact_problem`.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from typing import Final

CONTACT_FACING_KINDS: Final = frozenset({"execute_stage"})


class Decision(StrEnum):
    RUN = "run"
    LEAVE_PENDING = "leave_pending"  # not now (Hold, waiting for the final warning)
    CANCEL = "cancel"  # no longer relevant
    HOLD_AND_ALERT = "hold_and_alert"  # inconsistent: never auto-executed, operator is paged


@dataclass(frozen=True)
class GateFacts:
    """Everything the gate looks at, read inside the transaction after locking."""

    kind: str
    now: datetime
    scheduled_for: datetime
    grace_ends_at: datetime
    hold_active: bool
    incident_open: bool
    user_active: bool
    snapshot_recognised: bool
    ownership_consistent: bool  # incident.user_id == action.user_id == the locked user
    checkin_after_missed_due: bool
    release_offset_ok: bool  # stages with releases are still >= MIN_RELEASE_OFFSET
    needs_final_warning: bool
    final_warning_executed: bool
    final_warning_wait_exceeded: bool  # waited more than 30 minutes (G9)


@dataclass(frozen=True)
class GateResult:
    decision: Decision
    gate: str  # "G1".."G9" or "ok"

    @property
    def runs(self) -> bool:
        return self.decision is Decision.RUN


def decide(f: GateFacts) -> GateResult:  # noqa: PLR0911 - a flat, ordered list of gates
    """Evaluate G1-G9 in the order of the specification. The first failing check decides."""
    contact_facing = f.kind in CONTACT_FACING_KINDS

    # G1: not in Hold (contact-facing actions only). Left pending; shifted when Hold ends.
    if contact_facing and f.hold_active:
        return GateResult(Decision.LEAVE_PENDING, "G1")
    # G2: the incident is still open.
    if not f.incident_open:
        return GateResult(Decision.CANCEL, "G2")
    # G6 (first of its two parts, so that nothing below reads data it cannot trust):
    # recognised snapshot schema and consistent ownership.
    if not f.snapshot_recognised or not f.ownership_consistent:
        return GateResult(Decision.HOLD_AND_ALERT, "G6")
    # G3: no check-in exists that the incident did not absorb.
    if f.checkin_after_missed_due:
        return GateResult(Decision.HOLD_AND_ALERT, "G3")
    # G4: due now, and never before the end of grace; releases never before the minimum.
    if f.scheduled_for > f.now:
        return GateResult(Decision.LEAVE_PENDING, "G4")
    if contact_facing and f.scheduled_for < f.grace_ends_at:
        return GateResult(Decision.HOLD_AND_ALERT, "G4")
    if contact_facing and not f.release_offset_ok:
        return GateResult(Decision.HOLD_AND_ALERT, "G4")
    # G5: the account is active (deletion closes the incident separately).
    if not f.user_active:
        return GateResult(Decision.CANCEL, "G5")
    # G9: a stage that releases runs only after its final warning was executed.
    if contact_facing and f.needs_final_warning and not f.final_warning_executed:
        if f.final_warning_wait_exceeded:
            return GateResult(Decision.HOLD_AND_ALERT, "G9")
        return GateResult(Decision.LEAVE_PENDING, "G9")
    return GateResult(Decision.RUN, "ok")


# --- per-target narrowing (G7) ----------------------------------------------------------------


@dataclass(frozen=True)
class ContactFacts:
    exists: bool
    belongs_to_user: bool
    deleted: bool
    is_active: bool
    verification_status: str
    suppressed: bool


def contact_problem(c: ContactFacts) -> str | None:
    """Why this contact must not be messaged, or ``None`` when it may be (G7). The reason is a
    short code that is recorded with the outcome; it never contains the person's data."""
    if not c.exists or not c.belongs_to_user:
        return "not_found"
    if c.deleted:
        return "deleted"
    if not c.is_active:
        return "inactive"
    if c.verification_status != "verified":
        return f"not_verified_{c.verification_status}"
    if c.suppressed:
        return "suppressed"
    return None
