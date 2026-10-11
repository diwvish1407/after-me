"""Import every ORM model so ``Base.metadata`` is complete (Alembic, schema-drift test)."""

from __future__ import annotations

from sqlalchemy import MetaData

from app.audit.models import AuditLog
from app.auth.models import AuthSession, AuthToken, Device, RefreshToken, User
from app.checkins.models import CheckinConfiguration, CheckinEvent
from app.contacts.models import ContactVerification, EmailSuppression, TrustedContact
from app.core.db import Base
from app.core.models import SystemFlag
from app.incidents.models import EscalationIncident, IncidentAction
from app.instructions.models import Instruction, InstructionCategory, InstructionRecipient
from app.notifications.models import EmailReceipt, Notification, NotificationLog
from app.ops.models import IngestionProbe, ServiceHeartbeat, SystemHold
from app.plans.models import EscalationPlan, EscalationStep, EscalationStepContact
from app.releases.models import (
    PortalAccess,
    PortalOtpChallenge,
    PortalSession,
    PortalToken,
    ReleaseEvent,
)
from app.security.models import RateLimitCounter, UserKey
from app.users.models import UserProfile

__all__ = [
    "AuditLog",
    "AuthSession",
    "AuthToken",
    "CheckinConfiguration",
    "CheckinEvent",
    "ContactVerification",
    "Device",
    "EmailReceipt",
    "EmailSuppression",
    "EscalationIncident",
    "EscalationPlan",
    "EscalationStep",
    "EscalationStepContact",
    "IncidentAction",
    "IngestionProbe",
    "Instruction",
    "InstructionCategory",
    "InstructionRecipient",
    "Notification",
    "NotificationLog",
    "PortalAccess",
    "PortalOtpChallenge",
    "PortalSession",
    "PortalToken",
    "RateLimitCounter",
    "RefreshToken",
    "ReleaseEvent",
    "ServiceHeartbeat",
    "SystemFlag",
    "SystemHold",
    "TrustedContact",
    "User",
    "UserKey",
    "UserProfile",
    "metadata",
]

metadata: MetaData = Base.metadata

# Tables in dependency order (parents first). Used by tests to truncate between cases.
PHASE1_TABLES: tuple[str, ...] = (
    "users",
    "user_profiles",
    "devices",
    "sessions",
    "refresh_tokens",
    "auth_tokens",
    "checkin_configurations",
    "audit_logs",
    "system_flags",
    "rate_limit_counters",
)

# Phase 3: trusted contacts, invitations, the global suppression list.
PHASE3_TABLES: tuple[str, ...] = (
    "trusted_contacts",
    "contact_verifications",
    "email_suppressions",
)
# Phase 4: the check-in history (and idempotent replay store).
PHASE4_TABLES: tuple[str, ...] = ("checkin_events",)

# Phase 5: the plan, incidents and their timeline, the outbox, Hold and worker liveness.
PHASE5_TABLES: tuple[str, ...] = (
    "escalation_plans",
    "escalation_steps",
    "escalation_step_contacts",
    "escalation_incidents",
    "incident_actions",
    "notifications",
    "notification_logs",
    "system_holds",
    "ingestion_probes",
    "service_heartbeats",
)

# Phase 6: the wrapped keys, instructions and recipients, releases and the recipient portal.
PHASE6_TABLES: tuple[str, ...] = (
    "user_keys",
    "instruction_categories",
    "instructions",
    "instruction_recipients",
    "release_events",
    "portal_access",
    "portal_tokens",
    "portal_sessions",
    "portal_otp_challenges",
)
# Phase 8: what a provider told us about mail that was sent straight to a contact.
PHASE8_TABLES: tuple[str, ...] = ("email_receipts",)
ALL_TABLES: tuple[str, ...] = (
    PHASE1_TABLES + PHASE3_TABLES + PHASE4_TABLES + PHASE5_TABLES + PHASE6_TABLES + PHASE8_TABLES
)
