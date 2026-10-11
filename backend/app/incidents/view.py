"""Building the incident object the API returns (API_SPEC §9). Shared by the incidents routes
and the Home aggregate so that both always agree."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal

from app.incidents.models import OPEN_STATUSES, EscalationIncident, IncidentAction
from app.incidents.schemas import IncidentOut, ReleaseOut, TimelineContact, TimelineItem
from app.incidents.snapshot import PlanSnapshot, SnapshotError, parse_snapshot


def build_incident(
    incident: EscalationIncident,
    actions: list[IncidentAction],
    names: dict[uuid.UUID, str],
    *,
    now: datetime,
    releases: list[ReleaseOut] | None = None,
) -> IncidentOut:
    try:
        snapshot: PlanSnapshot | None = parse_snapshot(incident.plan_snapshot)
    except SnapshotError:
        snapshot = None
    is_open = incident.status in OPEN_STATUSES
    messaged = incident.contacts_messaged_at is not None
    timeline: list[TimelineItem] = []
    for action in actions:
        stage = snapshot.stage(action.step_id) if snapshot and action.step_id else None
        contacts: list[TimelineContact] | None = None
        if action.kind == "execute_stage" and stage is not None:
            results = _results(action)
            contacts = [
                TimelineContact(
                    id=contact_id,
                    display_name=names.get(contact_id, ""),
                    result=results.get(str(contact_id)),
                )
                for contact_id in stage.notify_contact_ids
            ]
        timeline.append(
            TimelineItem(
                kind=action.kind,  # type: ignore[arg-type]
                variant=action.variant,  # type: ignore[arg-type]
                stage_position=stage.position if stage is not None else None,
                scheduled_for=action.scheduled_for,
                status=action.status,  # type: ignore[arg-type]
                contacts=contacts,
                release_count=len(stage.releases)
                if stage is not None and action.kind != "user_reminder"
                else None,
            )
        )
    return IncidentOut(
        id=incident.id,
        status=incident.status,  # type: ignore[arg-type]
        requires=("safe" if messaged else "checkin") if is_open else None,
        missed_due_at=incident.missed_due_at,
        anchor_at=incident.anchor_at,
        grace_ends_at=incident.grace_ends_at,
        contacts_messaged=messaged,
        closed_at=incident.closed_at,
        closed_by=incident.closed_by,
        timeline=timeline,
        releases=releases or [],
        server_time=now,
    )


def _results(action: IncidentAction) -> dict[str, Literal["messaged", "skipped"]]:
    outcome = action.outcome or {}
    targets = outcome.get("targets", [])
    found: dict[str, Literal["messaged", "skipped"]] = {}
    for target in targets:
        if not isinstance(target, dict):
            continue
        result = target.get("result")
        if result == "messaged":
            found[str(target.get("contact_id"))] = "messaged"
        elif result == "skipped":
            found[str(target.get("contact_id"))] = "skipped"
    return found
