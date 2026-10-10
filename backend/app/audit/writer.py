"""Audit writer (SECURITY §9).

Audit rows are written in the same transaction as the change they describe, or, for failure
records that must survive an error response, in an independent transaction. Metadata may only
hold identifiers, reason codes and counts: the writer rejects anything that looks sensitive.
"""

from __future__ import annotations

import re
import uuid
from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import datetime
from typing import Final

from sqlalchemy.ext.asyncio import AsyncSession

from app.audit.models import AuditLog
from app.core.db import Database

# --- Phase 1 actions ------------------------------------------------------------------------
SIGNUP_STARTED: Final = "auth.signup_started"
SIGNUP_VERIFIED: Final = "auth.signup_verified"
LOGIN_SUCCEEDED: Final = "auth.login_succeeded"
LOGIN_FAILED: Final = "auth.login_failed"
LOCKED: Final = "auth.locked"
LOGOUT: Final = "auth.logout"
LOGOUT_ALL: Final = "auth.logout_all"
REFRESH_REUSE_DETECTED: Final = "auth.refresh_reuse_detected"
REAUTH_SUCCEEDED: Final = "auth.reauth_succeeded"
REAUTH_FAILED: Final = "auth.reauth_failed"
SESSION_REVOKED: Final = "session.revoked"

# --- Phase 2 actions ------------------------------------------------------------------------
PASSWORD_CHANGED: Final = "auth.password_changed"  # noqa: S105
PASSWORD_RESET_REQUESTED: Final = "auth.password_reset_requested"  # noqa: S105
PASSWORD_RESET_COMPLETED: Final = "auth.password_reset_completed"  # noqa: S105
EMAIL_CHANGE_REQUESTED: Final = "auth.email_change_requested"
EMAIL_CHANGED: Final = "auth.email_changed"
PROFILE_UPDATED: Final = "profile.updated"
PROFILE_TIMEZONE_CHANGED: Final = "profile.timezone_changed"

# --- Phase 3 actions ------------------------------------------------------------------------
CONTACT_CREATED: Final = "contact.created"
CONTACT_UPDATED: Final = "contact.updated"
CONTACT_DELETED: Final = "contact.deleted"
CONTACT_INVITATION_SENT: Final = "contact.invitation_sent"
CONTACT_ACCEPTED: Final = "contact.accepted"
CONTACT_DECLINED: Final = "contact.declined"
CONTACT_OPTED_OUT: Final = "contact.opted_out"

# --- Phase 4 actions ------------------------------------------------------------------------
CHECKIN_RECORDED: Final = "checkin.recorded"
SCHEDULE_UPDATED: Final = "schedule.updated"
SCHEDULE_ACTIVATED: Final = "schedule.activated"
SCHEDULE_DEACTIVATED: Final = "schedule.deactivated"

# --- Phase 5 actions ------------------------------------------------------------------------
PLAN_UPDATED: Final = "plan.updated"
INCIDENT_OPENED: Final = "incident.opened"
INCIDENT_RESOLVED: Final = "incident.resolved"
INCIDENT_CANCELLED: Final = "incident.cancelled"
INCIDENT_VOIDED: Final = "incident.voided"
REMINDER_SENT: Final = "escalation.reminder_sent"
FINAL_WARNING_SENT: Final = "escalation.final_warning_sent"
STAGE_EXECUTED: Final = "escalation.stage_executed"
STAGE_DEFERRED: Final = "escalation.stage_deferred"
ACTION_HELD: Final = "escalation.action_held"
NOTIFICATION_SENT: Final = "notification.sent"
NOTIFICATION_FAILED: Final = "notification.failed"
HOLD_ENTERED: Final = "system.hold_entered"
HOLD_EXITED: Final = "system.hold_exited"
CONSISTENCY_VIOLATION: Final = "system.consistency_violation"
OPERATOR_HOLD_ENTER: Final = "operator.hold_enter"
OPERATOR_HOLD_EXIT: Final = "operator.hold_exit"
OPERATOR_VOID_INCIDENT: Final = "operator.void_incident"
OPERATOR_RETRY_ACTION: Final = "operator.retry_action"

PHASE1_ACTIONS: Final = frozenset(
    {
        SIGNUP_STARTED,
        SIGNUP_VERIFIED,
        LOGIN_SUCCEEDED,
        LOGIN_FAILED,
        LOCKED,
        LOGOUT,
        LOGOUT_ALL,
        REFRESH_REUSE_DETECTED,
        REAUTH_SUCCEEDED,
        REAUTH_FAILED,
        SESSION_REVOKED,
    }
)

PHASE2_ACTIONS: Final = frozenset(
    {
        PASSWORD_CHANGED,
        PASSWORD_RESET_REQUESTED,
        PASSWORD_RESET_COMPLETED,
        EMAIL_CHANGE_REQUESTED,
        EMAIL_CHANGED,
        PROFILE_UPDATED,
        PROFILE_TIMEZONE_CHANGED,
    }
)
PHASE3_ACTIONS: Final = frozenset(
    {
        CONTACT_CREATED,
        CONTACT_UPDATED,
        CONTACT_DELETED,
        CONTACT_INVITATION_SENT,
        CONTACT_ACCEPTED,
        CONTACT_DECLINED,
        CONTACT_OPTED_OUT,
    }
)
PHASE4_ACTIONS: Final = frozenset(
    {CHECKIN_RECORDED, SCHEDULE_UPDATED, SCHEDULE_ACTIVATED, SCHEDULE_DEACTIVATED}
)
PHASE5_ACTIONS: Final = frozenset(
    {
        PLAN_UPDATED,
        INCIDENT_OPENED,
        INCIDENT_RESOLVED,
        INCIDENT_CANCELLED,
        INCIDENT_VOIDED,
        REMINDER_SENT,
        FINAL_WARNING_SENT,
        STAGE_EXECUTED,
        STAGE_DEFERRED,
        ACTION_HELD,
        NOTIFICATION_SENT,
        NOTIFICATION_FAILED,
        HOLD_ENTERED,
        HOLD_EXITED,
        CONSISTENCY_VIOLATION,
        OPERATOR_HOLD_ENTER,
        OPERATOR_HOLD_EXIT,
        OPERATOR_VOID_INCIDENT,
        OPERATOR_RETRY_ACTION,
    }
)
KNOWN_ACTIONS: Final = (
    PHASE1_ACTIONS | PHASE2_ACTIONS | PHASE3_ACTIONS | PHASE4_ACTIONS | PHASE5_ACTIONS
)

# Shown in the Activity feed (SECURITY §9, marked ✓). auth.login_succeeded is visible only for a
# new device, which the caller states explicitly.
USER_VISIBLE_ACTIONS: Final = frozenset(
    {
        LOGOUT_ALL,
        REFRESH_REUSE_DETECTED,
        PASSWORD_CHANGED,
        PASSWORD_RESET_COMPLETED,
        EMAIL_CHANGED,
        PROFILE_TIMEZONE_CHANGED,
        CONTACT_CREATED,
        CONTACT_DELETED,
        CONTACT_INVITATION_SENT,
        CONTACT_ACCEPTED,
        CONTACT_DECLINED,
        CONTACT_OPTED_OUT,
        CHECKIN_RECORDED,
        SCHEDULE_UPDATED,
        SCHEDULE_ACTIVATED,
        SCHEDULE_DEACTIVATED,
        PLAN_UPDATED,
        INCIDENT_OPENED,
        INCIDENT_RESOLVED,
        INCIDENT_CANCELLED,
        INCIDENT_VOIDED,
        FINAL_WARNING_SENT,
        STAGE_EXECUTED,
    }
)

_METADATA_KEY_RE: Final = re.compile(r"^[a-z][a-z0-9_]{0,39}$")
_FORBIDDEN_KEY_PARTS: Final = (
    "password",
    "token",
    "code",
    "otp",
    "secret",
    "email",
    "phone",
    "name",
    "title",
    "body",
    "address",
)
_FORBIDDEN_KEYS: Final = frozenset({"ip", "ua", "user_agent"})
_MAX_STRING: Final = 64
_SAFE_STRING_RE: Final = re.compile(r"^[A-Za-z0-9_.:-]*$")

MetadataValue = str | int | bool | None


class AuditMetadataError(ValueError):
    """A programming error: metadata would store something that is not an ID or reason code."""


def validate_metadata(metadata: Mapping[str, object]) -> dict[str, MetadataValue]:
    clean: dict[str, MetadataValue] = {}
    for key, value in metadata.items():
        if (
            not _METADATA_KEY_RE.match(key)
            or key in _FORBIDDEN_KEYS
            or any(p in key for p in _FORBIDDEN_KEY_PARTS)
        ):
            msg = f"audit metadata key not allowed: {key!r}"
            raise AuditMetadataError(msg)
        if isinstance(value, uuid.UUID):
            clean[key] = str(value)
        elif isinstance(value, str):
            if len(value) > _MAX_STRING or not _SAFE_STRING_RE.match(value):
                msg = f"audit metadata value for {key!r} must be a short reason code or ID"
                raise AuditMetadataError(msg)
            clean[key] = value
        elif value is None or isinstance(value, (bool, int)):
            clean[key] = value
        else:
            msg = f"audit metadata value for {key!r} has an unsupported type"
            raise AuditMetadataError(msg)
    return clean


@dataclass(frozen=True)
class AuditEvent:
    action: str
    occurred_at: datetime
    subject_user_id: uuid.UUID | None
    actor_type: str = "user"
    actor_id: uuid.UUID | None = None
    resource_type: str | None = None
    resource_id: uuid.UUID | None = None
    request_id: str | None = None
    ip_hash: bytes | None = None
    metadata: dict[str, MetadataValue | uuid.UUID] = field(default_factory=dict)
    user_visible: bool | None = None  # None: decided by the action

    def to_row(self) -> AuditLog:
        if self.action not in KNOWN_ACTIONS:
            msg = f"unknown audit action: {self.action!r}"
            raise AuditMetadataError(msg)
        visible = (
            self.user_visible
            if self.user_visible is not None
            else self.action in USER_VISIBLE_ACTIONS
        )
        return AuditLog(
            occurred_at=self.occurred_at,
            actor_type=self.actor_type,
            actor_id=self.actor_id,
            subject_user_id=self.subject_user_id,
            action=self.action,
            resource_type=self.resource_type,
            resource_id=self.resource_id,
            request_id=self.request_id,
            ip_hash=self.ip_hash,
            user_visible=visible,
            metadata_=validate_metadata(self.metadata),
        )


class AuditWriter:
    def __init__(self, db: Database) -> None:
        self._db = db

    async def record(self, session: AsyncSession, event: AuditEvent) -> None:
        """Write in the caller's transaction: committed or rolled back with the change."""
        session.add(event.to_row())
        await session.flush()

    async def record_independent(self, event: AuditEvent) -> None:
        """Write and commit on a separate connection (failure records)."""
        row = event.to_row()
        async with self._db.independent_session() as session:
            session.add(row)
