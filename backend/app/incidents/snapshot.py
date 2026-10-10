"""The plan snapshot stored on an incident (ESCALATION_ENGINE §5.4).

It holds **identifiers only**, never names, addresses or content. At execution each identifier
is re-validated against live data (INV-7): a snapshot can only ever be narrowed.
"""

from __future__ import annotations

import uuid
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any, Final

SNAPSHOT_SCHEMA: Final = 1


class SnapshotError(ValueError):
    """The stored snapshot is not one this release understands (gate G6)."""


@dataclass(frozen=True)
class SnapshotRelease:
    instruction_id: uuid.UUID
    contact_id: uuid.UUID


@dataclass(frozen=True)
class SnapshotStage:
    stage_id: uuid.UUID
    position: int
    offset_minutes: int
    notify_contact_ids: tuple[uuid.UUID, ...]
    releases: tuple[SnapshotRelease, ...] = ()


@dataclass(frozen=True)
class PlanSnapshot:
    plan_id: uuid.UUID
    plan_version: int
    grace_minutes: int
    stages: tuple[SnapshotStage, ...]

    def stage(self, stage_id: uuid.UUID) -> SnapshotStage | None:
        return next((s for s in self.stages if s.stage_id == stage_id), None)


def build_snapshot(
    *,
    plan_id: uuid.UUID,
    plan_version: int,
    grace_minutes: int,
    stages: Sequence[SnapshotStage],
) -> dict[str, Any]:
    return {
        "schema": SNAPSHOT_SCHEMA,
        "plan_id": str(plan_id),
        "plan_version": plan_version,
        "grace_minutes": grace_minutes,
        "stages": [
            {
                "stage_id": str(s.stage_id),
                "position": s.position,
                "offset_minutes": s.offset_minutes,
                "notify_contact_ids": [str(c) for c in s.notify_contact_ids],
                "releases": [
                    {"instruction_id": str(r.instruction_id), "contact_id": str(r.contact_id)}
                    for r in s.releases
                ],
            }
            for s in stages
        ],
    }


def parse_snapshot(raw: object) -> PlanSnapshot:
    """Strict: anything unexpected is an error, never a guess (fail safe, INV-4)."""
    try:
        if not isinstance(raw, Mapping) or raw.get("schema") != SNAPSHOT_SCHEMA:
            raise SnapshotError("unrecognised snapshot schema")
        stages = tuple(
            SnapshotStage(
                stage_id=uuid.UUID(s["stage_id"]),
                position=_positive_int(s["position"]),
                offset_minutes=_positive_int(s["offset_minutes"]),
                notify_contact_ids=tuple(uuid.UUID(c) for c in s["notify_contact_ids"]),
                releases=tuple(
                    SnapshotRelease(uuid.UUID(r["instruction_id"]), uuid.UUID(r["contact_id"]))
                    for r in s["releases"]
                ),
            )
            for s in raw["stages"]
        )
        positions = [s.position for s in stages]
        if len(set(positions)) != len(positions) or positions != sorted(positions):
            raise SnapshotError("stages out of order")
        return PlanSnapshot(
            plan_id=uuid.UUID(raw["plan_id"]),
            plan_version=_positive_int(raw["plan_version"]),
            grace_minutes=_positive_int(raw["grace_minutes"]),
            stages=stages,
        )
    except SnapshotError:
        raise
    except (KeyError, TypeError, ValueError, AttributeError) as exc:
        raise SnapshotError("malformed snapshot") from exc


def _positive_int(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise SnapshotError("expected a positive integer")
    return value
