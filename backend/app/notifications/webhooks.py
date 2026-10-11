"""Delivery, bounce and complaint events from the email providers (API_SPEC §14).

A provider's webhook is untrusted until its signature (Resend: Svix HMAC) or password (Postmark:
Basic auth) is verified, and even then it only ever *adds knowledge*: a log row, a suppressed
address, a contact marked ``bounced``. It cannot create a message, an incident or a release.

Events are idempotent: every provider event id is stored once (``uq_notification_logs_event``),
so a webhook that is delivered twice, or out of order, changes nothing the second time. An event
about a message we did not send through the outbox (a signup code, say) is acknowledged and
ignored.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from typing import Any, Final

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.audit import writer as audit
from app.audit.writer import AuditEvent
from app.core.logging import get_logger
from app.notifications import unreachable
from app.notifications.models import EmailReceipt, Notification, NotificationLog

_log = get_logger("afterme.webhook")

TOLERANCE_SECONDS: Final = 300
SUPPORTED: Final = ("resend", "postmark")


class WebhookRejected(Exception):  # noqa: N818 - rendered as a bare 401
    """The signature or password did not verify."""


class WebhookMalformed(Exception):  # noqa: N818 - rendered as a bare 400
    """The body is not an event we can read."""


class Kind(StrEnum):
    DELIVERED = "delivered"
    HARD_BOUNCE = "hard_bounce"
    SOFT_BOUNCE = "soft_bounce"
    FAILED = "failed"  # the provider says it could not deliver (after its own retries)
    COMPLAINT = "complaint"
    OTHER = "other"


@dataclass(frozen=True)
class DeliveryEvent:
    provider: str
    event_id: str
    message_id: str
    kind: Kind
    code: str = ""
    # The address the message went to, lower-cased: an event is only applied to a contact that
    # still has it. Empty when the provider did not say.
    recipient: str = ""
    # Our own notification id, echoed from the tag/metadata we sent: finds the message even when
    # the event arrives before the dispatcher stored the provider's message id.
    notification_id: str = ""


# --- verification -----------------------------------------------------------------------------


def verify_resend(secret: str, headers: Mapping[str, str], body: bytes, now: datetime) -> None:
    """Svix: ``HMAC-SHA256(base64(secret), f"{id}.{timestamp}.{body}")``."""
    msg_id = headers.get("svix-id", "")
    stamp = headers.get("svix-timestamp", "")
    signatures = headers.get("svix-signature", "")
    try:
        sent_at = int(stamp)
        key = base64.b64decode(secret.removeprefix("whsec_"), validate=True)
    except (ValueError, binascii.Error):
        raise WebhookRejected from None
    if not msg_id or not signatures or abs(now.timestamp() - sent_at) > TOLERANCE_SECONDS:
        raise WebhookRejected
    signed = f"{msg_id}.{stamp}.".encode() + body
    expected = base64.b64encode(hmac.new(key, signed, hashlib.sha256).digest()).decode()
    for candidate in signatures.split():
        version, _, value = candidate.partition(",")
        if version == "v1" and hmac.compare_digest(value.encode(), expected.encode()):
            return
    raise WebhookRejected


def verify_postmark(secret: str, headers: Mapping[str, str]) -> None:
    """HTTP Basic auth: the password of the URL given to Postmark is the secret."""
    header = headers.get("authorization", "")
    scheme, _, encoded = header.partition(" ")
    if scheme.lower() != "basic":
        raise WebhookRejected
    try:
        decoded = base64.b64decode(encoded, validate=True).decode()
    except (ValueError, binascii.Error):
        raise WebhookRejected from None
    _, _, password = decoded.partition(":")
    if not hmac.compare_digest(password.encode(), secret.encode()):
        raise WebhookRejected


# --- parsing ----------------------------------------------------------------------------------


def _load(body: bytes) -> Any:
    try:
        return json.loads(body)
    except ValueError:
        raise WebhookMalformed from None


def _uuid_or_empty(value: object) -> str:
    try:
        return str(uuid.UUID(str(value)))
    except ValueError:
        return ""


def _first_address(value: object) -> str:
    if isinstance(value, list) and value:
        value = value[0]
    return value.strip().lower() if isinstance(value, str) else ""


def parse_resend(body: bytes, svix_id: str) -> list[DeliveryEvent]:
    event = _load(body)
    if not isinstance(event, dict):
        raise WebhookMalformed
    kind_name = str(event.get("type", ""))
    data = event.get("data")
    if not isinstance(data, dict):
        return []
    message_id = str(data.get("email_id", ""))
    tags = data.get("tags")
    notification_id = (
        _uuid_or_empty(tags.get("notification_id", "")) if isinstance(tags, dict) else ""
    )
    if not message_id and not notification_id:
        return []
    bounce = data.get("bounce")
    if kind_name == "email.delivered":
        kind, code = Kind.DELIVERED, ""
    elif kind_name == "email.complained":
        kind, code = Kind.COMPLAINT, "complaint"
    elif kind_name == "email.bounced":
        permanent = isinstance(bounce, dict) and str(bounce.get("type", "")).lower() == "permanent"
        kind = Kind.HARD_BOUNCE if permanent else Kind.SOFT_BOUNCE
        code = f"bounce_{str((bounce or {}).get('type', 'unknown')).lower()}"[:48]
    elif kind_name in ("email.failed", "email.suppressed"):
        kind, code = Kind.FAILED, kind_name.removeprefix("email.")
    else:
        return []  # sent, opened, clicked, delivery_delayed: nothing we act on
    return [
        DeliveryEvent(
            "resend",
            svix_id or f"{message_id}:{kind_name}",
            message_id,
            kind,
            code,
            recipient=_first_address(data.get("to")),
            notification_id=notification_id,
        )
    ]


def parse_postmark(body: bytes) -> list[DeliveryEvent]:
    event = _load(body)
    if not isinstance(event, dict):
        raise WebhookMalformed
    record = str(event.get("RecordType", ""))
    message_id = str(event.get("MessageID", ""))
    metadata = event.get("Metadata")
    notification_id = (
        _uuid_or_empty(metadata.get("notification_id", "")) if isinstance(metadata, dict) else ""
    )
    if not message_id and not notification_id:
        return []
    identifier = str(event.get("ID") or "")
    recipient = _first_address(event.get("Email") or event.get("Recipient"))
    base = {"recipient": recipient, "notification_id": notification_id}
    if record == "Delivery":
        return [
            DeliveryEvent("postmark", f"{message_id}:delivery", message_id, Kind.DELIVERED, **base)
        ]
    if record == "SpamComplaint":
        return [
            DeliveryEvent(
                "postmark",
                identifier or f"{message_id}:complaint",
                message_id,
                Kind.COMPLAINT,
                "complaint",
                **base,
            )
        ]
    if record == "Bounce":
        bounce_type = str(event.get("Type", ""))
        # Only "the address does not exist". "Blocked" (an ISP refusing *us*) and
        # "ManuallyDeactivated" are not a statement about the contact.
        hard = bounce_type in ("HardBounce", "BadEmailAddress")
        return [
            DeliveryEvent(
                "postmark",
                identifier or f"{message_id}:bounce",
                message_id,
                Kind.HARD_BOUNCE if hard else Kind.SOFT_BOUNCE,
                f"bounce_{bounce_type.lower()}"[:48],
                **base,
            )
        ]
    return []


# --- processing -------------------------------------------------------------------------------


class EmailEventService:
    def __init__(self, *, session: AsyncSession, services: AppServices) -> None:
        self.session = session
        self.services = services

    def _secret(self, provider: str) -> str | None:
        settings = self.services.settings
        if provider == settings.email_provider and settings.email_webhook_secret:
            return settings.email_webhook_secret.get_secret_value()
        if provider == settings.email_fallback_provider and settings.email_fallback_webhook_secret:
            return settings.email_fallback_webhook_secret.get_secret_value()
        return None

    def known(self, provider: str) -> bool:
        return provider in SUPPORTED and self._secret(provider) is not None

    async def handle(self, provider: str, headers: Mapping[str, str], body: bytes) -> int:
        """Verify, parse and apply. Returns the number of events that changed something."""
        secret = self._secret(provider)
        if provider not in SUPPORTED or secret is None:
            raise WebhookRejected
        now = await self.services.clock.now(self.session)
        if provider == "resend":
            verify_resend(secret, headers, body, now)
            events = parse_resend(body, headers.get("svix-id", ""))
        else:
            verify_postmark(secret, headers)
            events = parse_postmark(body)
        applied = 0
        for event in events:
            if await self._apply(event, now):
                applied += 1
        await self.session.commit()
        return applied

    async def _apply(self, event: DeliveryEvent, now: datetime) -> bool:
        row = await self._find_notification(event)
        if row is not None:
            return await self._apply_to_notification(row, event, now)
        receipt = (
            await self.session.execute(
                select(EmailReceipt)
                .where(
                    EmailReceipt.provider == event.provider,
                    EmailReceipt.provider_message_id == event.message_id,
                )
                .limit(1)
            )
        ).scalar_one_or_none()
        if receipt is None:
            return False  # not ours (or an event that outran its own record)
        # A message sent straight to a contact (an invitation): there is no outbox row to log
        # against, and the effects are idempotent by state (a repeat changes nothing).
        _log.info("webhook.event", provider=event.provider, kind=event.kind.value, direct=True)
        return await self._effects(
            owner_id=receipt.user_id, contact_id=receipt.contact_id, event=event, now=now
        )

    async def _find_notification(self, event: DeliveryEvent) -> Notification | None:
        if event.notification_id:
            found = (
                await self.session.execute(
                    select(Notification)
                    .where(Notification.id == uuid.UUID(event.notification_id))
                    .limit(1)
                )
            ).scalar_one_or_none()
            if found is not None:
                return found
        if not event.message_id:
            return None
        return (
            await self.session.execute(
                select(Notification)
                .where(
                    Notification.provider == event.provider,
                    Notification.provider_message_id == event.message_id,
                )
                .limit(1)
            )
        ).scalar_one_or_none()

    async def _apply_to_notification(
        self, row: Notification, event: DeliveryEvent, now: datetime
    ) -> bool:
        outcome = {
            Kind.DELIVERED: "delivered",
            Kind.HARD_BOUNCE: "bounced",
            Kind.COMPLAINT: "complained",
            Kind.SOFT_BOUNCE: "error",
            Kind.FAILED: "error",
        }.get(event.kind)
        if outcome is None:
            return False
        inserted = (
            await self.session.execute(
                insert(NotificationLog)
                .values(
                    notification_id=row.id,
                    attempted_at=now,
                    provider=event.provider,
                    outcome=outcome,
                    provider_message_id=event.message_id or None,
                    error_code=event.code or None,
                    provider_event_id=event.event_id[:200],
                )
                .on_conflict_do_nothing(
                    index_elements=["provider", "provider_event_id"],
                    index_where=NotificationLog.provider_event_id.is_not(None),
                )
                .returning(NotificationLog.id)
            )
        ).scalar_one_or_none()
        if inserted is None:
            return False  # this event was seen before
        _log.info(
            "webhook.event",
            provider=event.provider,
            kind=event.kind.value,
            template=row.template_key,
            audience=row.audience,
        )
        if row.audience != "contact" or row.contact_id is None:
            if event.kind in (Kind.HARD_BOUNCE, Kind.COMPLAINT, Kind.FAILED):
                # The person's own address: nothing to tell them by email. It is on the record.
                await self.services.audit.record(
                    self.session,
                    AuditEvent(
                        action=audit.NOTIFICATION_FAILED,
                        occurred_at=now,
                        subject_user_id=row.user_id,
                        actor_type="system",
                        resource_type="notification",
                        resource_id=row.id,
                        metadata={"template": row.template_key, "error_class": event.code},
                    ),
                )
            return True
        await self._effects(owner_id=row.user_id, contact_id=row.contact_id, event=event, now=now)
        return True

    async def _effects(
        self, *, owner_id: uuid.UUID, contact_id: uuid.UUID, event: DeliveryEvent, now: datetime
    ) -> bool:
        reason = {
            Kind.HARD_BOUNCE: unreachable.BOUNCED,
            Kind.COMPLAINT: unreachable.COMPLAINT,
            Kind.SOFT_BOUNCE: unreachable.UNDELIVERABLE,
            Kind.FAILED: unreachable.UNDELIVERABLE,
        }.get(event.kind)
        if reason is None:
            return True  # delivered
        return await unreachable.contact_unreachable(
            self.session,
            self.services,
            owner_id=owner_id,
            contact_id=contact_id,
            reason=reason,
            now=now,
            expected_address=event.recipient or None,
        )


def new_event_id() -> str:  # pragma: no cover - used by tests only
    return uuid.uuid4().hex
