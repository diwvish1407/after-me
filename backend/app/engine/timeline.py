"""Materialising an incident's timeline (ESCALATION_ENGINE §5.2, §5.3). Pure.

Every offset is measured from ``anchor_at = max(missed_due_at, opened_at)``, so an incident
that was opened late (a worker outage) still gives the person the full grace period (INV-8).
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Final

from app.incidents.snapshot import PlanSnapshot

# Reminders that fall inside the grace period (§5.3).
LAST_CHANCE_LEAD: Final = timedelta(minutes=15)


@dataclass(frozen=True)
class PlannedAction:
    kind: str  # user_reminder | user_final_warning | execute_stage
    variant: str | None  # missed | midpoint | last_chance (reminders only)
    step_id: uuid.UUID | None
    scheduled_for: datetime
    dedupe_key: str


def anchor_for(missed_due_at: datetime, opened_at: datetime) -> datetime:
    return max(missed_due_at, opened_at)


def dedupe_key(incident_id: uuid.UUID, kind: str, discriminator: str) -> str:
    """``incident:{incident_id}:{kind}:{variant|stage_id}`` (§5.3)."""
    return f"incident:{incident_id}:{kind}:{discriminator}"


def materialise(
    *,
    incident_id: uuid.UUID,
    snapshot: PlanSnapshot,
    anchor_at: datetime,
    final_warning_lead: timedelta,
) -> list[PlannedAction]:
    grace = timedelta(minutes=snapshot.grace_minutes)
    actions = [
        PlannedAction(
            "user_reminder",
            "missed",
            None,
            anchor_at,
            dedupe_key(incident_id, "user_reminder", "missed"),
        ),
        PlannedAction(
            "user_reminder",
            "midpoint",
            None,
            anchor_at + grace / 2,
            dedupe_key(incident_id, "user_reminder", "midpoint"),
        ),
        PlannedAction(
            "user_reminder",
            "last_chance",
            None,
            anchor_at + grace - LAST_CHANCE_LEAD,
            dedupe_key(incident_id, "user_reminder", "last_chance"),
        ),
    ]
    for stage in snapshot.stages:
        offset = timedelta(minutes=stage.offset_minutes)
        if stage.releases:
            actions.append(
                PlannedAction(
                    "user_final_warning",
                    None,
                    stage.stage_id,
                    anchor_at + offset - final_warning_lead,
                    dedupe_key(incident_id, "user_final_warning", str(stage.stage_id)),
                )
            )
        actions.append(
            PlannedAction(
                "execute_stage",
                None,
                stage.stage_id,
                anchor_at + offset,
                dedupe_key(incident_id, "execute_stage", str(stage.stage_id)),
            )
        )
    return actions
