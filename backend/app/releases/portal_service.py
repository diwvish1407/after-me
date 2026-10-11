"""The recipient portal for released instructions (API_SPEC §13.1; ARCHITECTURE §7.2).

A contact opens the link from the email (the token travels in the URL *fragment*), and the
token is exchanged by POST for a short **portal session** (a cookie, stored hashed). Content
needs a second step: a six-digit one-time code sent to the contact's *verified* address. Every
step re-checks that the contact is still eligible and that the access and the releases are not
revoked: the portal never relies on a revocation having been written, it looks at the state.

Nothing here puts instruction text anywhere but the response of a successful ``view``: not
in a log, an audit record, an email, a token or an error.
"""

from __future__ import annotations

import re
import secrets
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from enum import StrEnum
from typing import Final

from sqlalchemy import and_, exists, func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.api.deps import RequestContext
from app.audit import writer as audit
from app.auth.models import User
from app.checkins.models import CheckinEvent
from app.contacts.models import EmailSuppression, TrustedContact
from app.contacts.tokens import new_optout_token, optout_link, suppression_hash_candidates
from app.core.logging import get_logger
from app.incidents.models import OPEN_STATUSES, EscalationIncident
from app.instructions.models import Instruction
from app.notifications import outbox
from app.notifications.mailer import EmailTemplate, mask_email
from app.notifications.render import day_time, duration_text
from app.ops.models import SystemHold
from app.plans.models import EscalationStep
from app.releases.models import (
    PortalAccess,
    PortalOtpChallenge,
    PortalSession,
    PortalToken,
    ReleaseEvent,
)
from app.security.envelope import DecryptionError
from app.security.hashing import sha256
from app.security.rate_limit import (
    PORTAL_NEW_LINK_PER_ACCESS,
    PORTAL_OTP_SEND_PER_ACCESS,
    PORTAL_OTP_VERIFY_PER_ACCESS,
)
from app.security.vault import VaultUnavailableError
from app.users.models import UserProfile

_log = get_logger("afterme.portal")

TOKEN_PREFIX: Final = "rt_"  # noqa: S105 - a URL prefix, not a secret
SESSION_COOKIE: Final = "__Host-afterme_portal"
SESSION_TTL: Final = timedelta(minutes=60)
ELEVATION_TTL: Final = timedelta(minutes=15)
OTP_TTL: Final = timedelta(minutes=10)
OTP_MAX_ATTEMPTS: Final = 5
_RAW_TOKEN: Final = re.compile(r"^[A-Za-z0-9_-]{43}$")
_CODE: Final = re.compile(r"^[0-9]{6}$")
_OTP_CONTEXT: Final = "portal_otp"
_COOKIE_MAX: Final = 128


class PortalInvalidError(Exception):
    """The link or session cannot be used. Deliberately carries no reason."""


class PortalWithdrawnError(Exception):
    """A real link whose release was taken back because the person checked in: said plainly
    ("no longer available, they are safe") instead of as a broken link."""

    def __init__(self, owner_name: str) -> None:
        super().__init__("withdrawn")
        self.owner_name = owner_name


class CodeResult(StrEnum):
    OK = "ok"
    WRONG = "wrong"
    EXPIRED = "expired"
    LOCKED = "locked"


class ViewState(StrEnum):
    READY = "ready"
    NOT_YET = "not_yet"
    GONE = "gone"
    CHECKED_IN = "checked_in"
    ERROR = "error"  # something that should be shown could not be: not the same as withdrawn


@dataclass(frozen=True)
class OpenedSession:
    cookie: str
    owner_name: str
    masked_email: str


@dataclass(frozen=True)
class CodeSent:
    owner_name: str
    masked_email: str


@dataclass(frozen=True)
class ViewItem:
    title: str
    body: str


@dataclass(frozen=True)
class ReleaseView:
    state: ViewState
    owner_name: str
    owner_email: str
    last_checkin: str | None = None
    after_text: str | None = None
    items: list[ViewItem] = field(default_factory=list)
    missing: int = 0  # items that exist but could not be shown right now


@dataclass(frozen=True)
class _Resolved:
    access: PortalAccess
    contact: TrustedContact
    owner: User
    owner_name: str
    timezone: str


class ReleasePortalService:
    def __init__(
        self, *, session: AsyncSession, services: AppServices, ctx: RequestContext
    ) -> None:
        self.session = session
        self.services = services
        self.ctx = ctx

    # ------------------------------------------------------------------ plumbing

    async def _now(self) -> datetime:
        return await self.services.clock.now(self.session)

    def _event(
        self, action: str, now: datetime, resolved: _Resolved, **metadata: str | int | bool
    ) -> audit.AuditEvent:
        """The contact acts; the account holder is the subject and sees it in their feed."""
        return audit.AuditEvent(
            action=action,
            occurred_at=now,
            subject_user_id=resolved.owner.id,
            actor_type="contact",
            actor_id=resolved.contact.id,
            resource_type="portal_access",
            resource_id=resolved.access.id,
            request_id=self.ctx.request_id,
            ip_hash=self.ctx.ip_hash,
            metadata=dict(metadata),
        )

    @staticmethod
    def _raw_token(value: str) -> str:
        if not value.startswith(TOKEN_PREFIX):
            raise PortalInvalidError
        raw = value[len(TOKEN_PREFIX) :]
        if not _RAW_TOKEN.fullmatch(raw):
            raise PortalInvalidError
        return raw

    async def _resolve(self, access: PortalAccess, now: datetime) -> _Resolved:
        """The contact and owner behind an access, or :class:`PortalInvalidError` when anything
        about them has changed: the access is revoked, the contact is gone, switched off, no
        longer verified or suppressed, or the account is not active."""
        if access.revoked_at is not None:
            raise PortalInvalidError
        row = (
            await self.session.execute(
                select(TrustedContact, User, UserProfile.display_name, UserProfile.timezone)
                .join(User, User.id == TrustedContact.user_id)
                .outerjoin(UserProfile, UserProfile.user_id == User.id)
                .where(TrustedContact.id == access.contact_id, User.id == access.user_id)
            )
        ).first()
        if row is None:
            raise PortalInvalidError
        contact, owner, owner_name, timezone = row
        if (
            contact.deleted_at is not None
            or not contact.is_active
            or contact.verification_status != "verified"
            or not contact.email
            or not contact.email_normalized
            or owner.status != "active"
        ):
            raise PortalInvalidError
        if await self._suppressed(contact.email_normalized):
            raise PortalInvalidError
        return _Resolved(access, contact, owner, owner_name or "Someone", timezone or "UTC")

    async def _suppressed(self, email_normalized: str) -> bool:
        hashes = suppression_hash_candidates(self.services.pepper, email_normalized)
        found = await self.session.execute(
            select(exists().where(EmailSuppression.email_hash.in_(hashes)))
        )
        return bool(found.scalar_one())

    async def _has_open_release(self, access: PortalAccess) -> bool:
        stmt = select(
            exists().where(
                ReleaseEvent.incident_id == access.incident_id,
                ReleaseEvent.contact_id == access.contact_id,
                ReleaseEvent.revoked_at.is_(None),
                # not only "not revoked": the incident itself must still be open, so that a
                # closing path that forgot to revoke can never leave content readable
                exists().where(
                    EscalationIncident.id == ReleaseEvent.incident_id,
                    EscalationIncident.status.in_(OPEN_STATUSES),
                ),
            )
        )
        return bool((await self.session.execute(stmt)).scalar_one())

    # ------------------------------------------------------------------ the link

    async def open_session(self, token_field: str) -> OpenedSession:
        """Exchange a link token for a portal session. Opens nothing else: the contact still
        has to enter the code before any content is shown."""
        raw = self._raw_token(token_field)
        now = await self._now()
        token = (
            await self.session.execute(
                select(PortalToken).where(PortalToken.token_hash == sha256(raw))
            )
        ).scalar_one_or_none()
        if token is None:
            raise PortalInvalidError
        access = (
            await self.session.execute(
                select(PortalAccess).where(PortalAccess.id == token.access_id)
            )
        ).scalar_one_or_none()
        if access is None:
            raise PortalInvalidError
        if token.expires_at <= now:
            await self._denied(access, now, "link_expired")
            raise PortalInvalidError
        try:
            resolved = await self._resolve(access, now)
            if not await self._has_open_release(access):
                raise PortalInvalidError
        except PortalInvalidError:
            await self._denied(access, now, "not_available")
            await self._raise_if_withdrawn(access, now)
            raise

        if token.first_used_at is None:
            token.first_used_at = now
        cookie = secrets.token_urlsafe(32)
        self.session.add(
            PortalSession(
                access_id=access.id,
                session_hash=sha256(cookie),
                expires_at=now + SESSION_TTL,
                ip_hash=self.ctx.ip_hash,
            )
        )
        await self.services.audit.record(
            self.session, self._event(audit.PORTAL_SESSION_CREATED, now, resolved)
        )
        await self.session.commit()
        return OpenedSession(
            cookie=cookie,
            owner_name=resolved.owner_name,
            masked_email=mask_email(resolved.contact.email or ""),
        )

    async def _denied(self, access: PortalAccess, now: datetime, reason: str) -> None:
        """A real link that was refused is on the account holder's record (no content, no
        address): a pattern of them is how a leaked link shows."""
        await self.services.audit.record(
            self.session,
            audit.AuditEvent(
                action=audit.PORTAL_ACCESS_DENIED,
                occurred_at=now,
                subject_user_id=access.user_id,
                actor_type="contact",
                actor_id=access.contact_id,
                resource_type="portal_access",
                resource_id=access.id,
                request_id=self.ctx.request_id,
                ip_hash=self.ctx.ip_hash,
                metadata={"reason": reason},
            ),
        )
        await self.session.commit()

    async def _raise_if_withdrawn(self, access: PortalAccess, now: datetime) -> None:
        """When everything was taken back because the person checked in, and the contact is
        still someone we may talk to, say so (USER_FLOWS §12.2) rather than "link broken"."""
        reasons = {
            row[0]
            for row in (
                await self.session.execute(
                    select(ReleaseEvent.revoke_reason).where(
                        ReleaseEvent.incident_id == access.incident_id,
                        ReleaseEvent.contact_id == access.contact_id,
                    )
                )
            ).all()
        }
        if not reasons or not reasons <= {"user_checkin", "user_safe"}:
            return
        copy = PortalAccess(
            id=access.id,
            user_id=access.user_id,
            incident_id=access.incident_id,
            contact_id=access.contact_id,
            revoked_at=None,  # only the contact's own standing is judged here
        )
        try:
            resolved = await self._resolve(copy, now)
        except PortalInvalidError:
            return
        raise PortalWithdrawnError(resolved.owner_name)

    async def request_new_link(self, token_field: str) -> None:
        """A fresh link for a release that is still valid, sent only to the contact's verified
        address. Always answers the same, whatever the token was."""
        try:
            raw = self._raw_token(token_field)
        except PortalInvalidError:
            return
        now = await self._now()
        token = (
            await self.session.execute(
                select(PortalToken).where(PortalToken.token_hash == sha256(raw))
            )
        ).scalar_one_or_none()
        if token is None:
            return
        access = (
            await self.session.execute(
                select(PortalAccess).where(PortalAccess.id == token.access_id)
            )
        ).scalar_one_or_none()
        if access is None:
            return
        try:
            resolved = await self._resolve(access, now)
        except PortalInvalidError:
            return
        if not await self._has_open_release(access):
            return
        result = await self.services.limiter.enforce(
            [(PORTAL_NEW_LINK_PER_ACCESS, str(access.id))], now=now
        )
        self.ctx.note_rate_limit(result)
        after = await self._after_minutes(access)
        bucket = int(now.timestamp() // 3600)
        await outbox.enqueue(
            self.session,
            [
                outbox.Draft(
                    user_id=access.user_id,
                    audience="contact",
                    category=outbox.CATEGORY_CONTACT_OTHER,
                    channel="email",
                    template_key=outbox.CONTACT_RELEASE,
                    send_after=now,
                    dedupe_key=f"newlink:{access.id}:{bucket}",
                    contact_id=access.contact_id,
                    incident_id=access.incident_id,
                    params={"access_id": str(access.id), "after_minutes": after},
                )
            ],
            now=now,
        )
        await self.services.audit.record(
            self.session, self._event(audit.PORTAL_NEW_LINK, now, resolved)
        )
        await self.session.commit()

    async def _after_minutes(self, access: PortalAccess) -> int:
        """When the earliest release of this access was set to happen (its stage's offset)."""
        offset = (
            await self.session.execute(
                select(func.min(EscalationStep.offset_minutes))
                .join(ReleaseEvent, ReleaseEvent.step_id == EscalationStep.id)
                .where(
                    ReleaseEvent.incident_id == access.incident_id,
                    ReleaseEvent.contact_id == access.contact_id,
                )
            )
        ).scalar_one_or_none()
        return int(offset) if offset is not None else 1440

    # ------------------------------------------------------------------ the session

    async def _load(self, cookie: str | None, now: datetime) -> tuple[PortalSession, _Resolved]:
        if not cookie or len(cookie) > _COOKIE_MAX:
            raise PortalInvalidError
        found = (
            await self.session.execute(
                select(PortalSession).where(PortalSession.session_hash == sha256(cookie))
            )
        ).scalar_one_or_none()
        if found is None or found.revoked_at is not None or found.expires_at <= now:
            raise PortalInvalidError
        access = (
            await self.session.execute(
                select(PortalAccess).where(PortalAccess.id == found.access_id)
            )
        ).scalar_one_or_none()
        if access is None:
            raise PortalInvalidError
        try:
            return found, await self._resolve(access, now)
        except PortalInvalidError:
            await self._raise_if_withdrawn(access, now)
            raise

    async def code_prompt(self, cookie: str | None) -> CodeSent:
        now = await self._now()
        _, resolved = await self._load(cookie, now)
        await self.session.commit()
        return CodeSent(resolved.owner_name, mask_email(resolved.contact.email or ""))

    async def send_code(self, cookie: str | None) -> CodeSent:
        now = await self._now()
        portal_session, resolved = await self._load(cookie, now)
        if not await self._has_open_release(resolved.access):
            # Nothing to unlock any more (the incident closed and a closing path left the
            # access unrevoked): no code is mailed for it. ``view`` would refuse anyway.
            raise PortalInvalidError
        result = await self.services.limiter.enforce(
            [(PORTAL_OTP_SEND_PER_ACCESS, str(resolved.access.id))], now=now
        )
        self.ctx.note_rate_limit(result)
        # An earlier code stops working the moment a new one is asked for.
        await self.session.execute(
            update(PortalOtpChallenge)
            .where(
                PortalOtpChallenge.portal_session_id == portal_session.id,
                PortalOtpChallenge.consumed_at.is_(None),
            )
            .values(consumed_at=now)
        )
        challenge_id = uuid.uuid4()
        code = f"{secrets.randbelow(1_000_000):06d}"
        self.session.add(
            PortalOtpChallenge(
                id=challenge_id,
                portal_session_id=portal_session.id,
                code_hash=self.services.pepper.hmac(_OTP_CONTEXT, str(challenge_id), code),
                expires_at=now + OTP_TTL,
            )
        )
        contact = resolved.contact
        assert contact.email is not None  # noqa: S101 - _resolve refuses a contact without one
        assert contact.email_normalized is not None  # noqa: S101
        message = self.services.mailer.render(
            EmailTemplate.PORTAL_CODE,
            to=contact.email,
            contact_name=contact.display_name,
            user_name=resolved.owner_name,
            user_email=resolved.owner.email,
            code=code,
            optout_link=optout_link(
                self.services.settings.public_base_url,
                new_optout_token(self.services.pepper, contact.id, contact.email_normalized),
            ),
        )
        await self.services.audit.record(
            self.session, self._event(audit.PORTAL_OTP_SENT, now, resolved)
        )
        await self.session.commit()
        await self.services.mailer.deliver([message])
        return CodeSent(resolved.owner_name, mask_email(contact.email))

    async def verify_code(self, cookie: str | None, code: str) -> CodeResult:
        now = await self._now()
        portal_session, resolved = await self._load(cookie, now)
        result = await self.services.limiter.enforce(
            [(PORTAL_OTP_VERIFY_PER_ACCESS, str(resolved.access.id))], now=now
        )
        self.ctx.note_rate_limit(result)
        challenge = (
            await self.session.execute(
                select(PortalOtpChallenge)
                .where(
                    PortalOtpChallenge.portal_session_id == portal_session.id,
                    PortalOtpChallenge.consumed_at.is_(None),
                )
                .order_by(PortalOtpChallenge.created_at.desc())
                .limit(1)
                .with_for_update()
            )
        ).scalar_one_or_none()
        if challenge is None or challenge.expires_at <= now:
            await self.session.commit()
            return CodeResult.EXPIRED
        # The attempt is counted *before* it is compared, atomically: five tries, however many
        # requests race.
        counted = (
            await self.session.execute(
                update(PortalOtpChallenge)
                .where(
                    PortalOtpChallenge.id == challenge.id,
                    PortalOtpChallenge.attempts < OTP_MAX_ATTEMPTS,
                    PortalOtpChallenge.consumed_at.is_(None),
                )
                .values(attempts=PortalOtpChallenge.attempts + 1)
                .returning(PortalOtpChallenge.attempts)
            )
        ).scalar_one_or_none()
        if counted is None:
            await self.session.commit()
            return CodeResult.LOCKED
        if not _CODE.fullmatch(code) or not self.services.pepper.verify(
            challenge.code_hash, _OTP_CONTEXT, str(challenge.id), code
        ):
            await self.services.audit.record(
                self.session,
                self._event(audit.PORTAL_OTP_FAILED, now, resolved, attempt=int(counted)),
            )
            await self.session.commit()
            return CodeResult.WRONG
        challenge.consumed_at = now
        portal_session.otp_verified_at = now
        portal_session.elevated_until = now + ELEVATION_TTL
        await self.services.audit.record(
            self.session, self._event(audit.PORTAL_OTP_VERIFIED, now, resolved)
        )
        await self.session.commit()
        return CodeResult.OK

    async def end_session(self, cookie: str | None) -> None:
        if not cookie or len(cookie) > _COOKIE_MAX:
            return
        now = await self._now()
        await self.session.execute(
            update(PortalSession)
            .where(PortalSession.session_hash == sha256(cookie), PortalSession.revoked_at.is_(None))
            .values(revoked_at=now)
        )
        await self.session.commit()

    # ------------------------------------------------------------------ the content

    async def view(self, cookie: str | None) -> ReleaseView | None:
        """What this contact may see now. ``None`` when the code step has not been done (or has
        lapsed): the caller asks for a code again."""
        now = await self._now()
        portal_session, resolved = await self._load(cookie, now)
        if portal_session.elevated_until is None or portal_session.elevated_until <= now:
            await self.session.commit()
            return None
        access = resolved.access
        owner = resolved.owner_name, resolved.owner.email

        if not await self._has_open_release(access):
            closed = (
                await self.session.execute(
                    select(EscalationIncident.closed_by).where(
                        EscalationIncident.id == access.incident_id
                    )
                )
            ).first()
            checked_in = closed is not None and closed.closed_by in ("user_checkin", "user_safe")
            await self.session.commit()
            state = ViewState.CHECKED_IN if checked_in else ViewState.GONE
            return ReleaseView(state, *owner)

        rows = await self._visible(access, now)
        if not rows:
            await self.session.commit()
            return ReleaseView(ViewState.NOT_YET, *owner)

        shown: list[tuple[ReleaseEvent, ViewItem, int | None]] = []
        missing = 0
        for release, instruction, offset in rows:
            if instruction.content_ciphertext is None:
                missing += 1
                continue
            try:
                title, body = await self.services.vault.open(
                    self.session,
                    user_id=instruction.user_id,
                    instruction_id=instruction.id,
                    ciphertext=instruction.content_ciphertext,
                    key_version=instruction.content_key_version,
                )
            except (DecryptionError, VaultUnavailableError):
                # Not the same as withdrawn: something that should be shown cannot be, right
                # now. Said so, and logged for someone to look at (identifiers only).
                _log.error(
                    "portal.content_unavailable",
                    access_id=str(access.id),
                    instruction_id=str(instruction.id),
                )
                missing += 1
                continue
            shown.append((release, ViewItem(title=title, body=body), offset))
        if not shown:
            await self.session.commit()
            return ReleaseView(ViewState.ERROR, *owner, missing=missing)

        # Counted, and re-checked, in one statement: a release revoked since it was read is
        # neither counted nor shown (the window is the statement, not the decrypt).
        still = {
            row[0]
            for row in (
                await self.session.execute(
                    update(ReleaseEvent)
                    .where(
                        ReleaseEvent.id.in_([r.id for r, _, _ in shown]),
                        ReleaseEvent.revoked_at.is_(None),
                    )
                    .values(
                        first_viewed_at=func.coalesce(ReleaseEvent.first_viewed_at, now),
                        last_viewed_at=now,
                        view_count=ReleaseEvent.view_count + 1,
                    )
                    .returning(ReleaseEvent.id)
                )
            ).all()
        }
        shown = [entry for entry in shown if entry[0].id in still]
        if not shown:
            await self.session.commit()
            return ReleaseView(ViewState.GONE, *owner)
        await self.services.audit.record(
            self.session, self._event(audit.RELEASE_VIEWED, now, resolved, releases=len(shown))
        )
        last = (
            await self.session.execute(
                select(func.max(CheckinEvent.received_at)).where(
                    CheckinEvent.user_id == resolved.owner.id
                )
            )
        ).scalar_one_or_none()
        offsets = [offset for _, _, offset in shown if offset is not None]
        await self.session.commit()
        return ReleaseView(
            ViewState.READY,
            *owner,
            last_checkin=day_time(last, resolved.timezone) if last else None,
            after_text=duration_text(min(offsets)) if offsets else None,
            items=[item for _, item, _ in shown],
            missing=missing,
        )

    async def _visible(
        self, access: PortalAccess, now: datetime
    ) -> list[tuple[ReleaseEvent, Instruction, int | None]]:
        """Releases of this (incident, contact) that are not revoked, are past the settle delay,
        were not created inside a Hold window that has not been processed, and whose instruction
        is still active."""
        # The same reach as the rollback (a Hold takes back what ran up to one settle delay
        # before it began: ESCALATION_ENGINE §7.3), so nothing that may still be rolled back is
        # ever readable.
        settle = timedelta(seconds=self.services.settings.settle_delay_seconds)
        in_hold = exists().where(
            SystemHold.started_at - settle <= ReleaseEvent.released_at,
            or_(SystemHold.ended_at.is_(None), SystemHold.ended_at >= ReleaseEvent.released_at),
            SystemHold.exit_processed_at.is_(None),
        )
        stmt = (
            select(ReleaseEvent, Instruction, EscalationStep.offset_minutes)
            .join(Instruction, Instruction.id == ReleaseEvent.instruction_id)
            .outerjoin(EscalationStep, EscalationStep.id == ReleaseEvent.step_id)
            .where(
                and_(
                    ReleaseEvent.incident_id == access.incident_id,
                    ReleaseEvent.contact_id == access.contact_id,
                    ReleaseEvent.user_id == access.user_id,
                    ReleaseEvent.revoked_at.is_(None),
                    ReleaseEvent.visible_after <= now,
                    exists().where(
                        EscalationIncident.id == ReleaseEvent.incident_id,
                        EscalationIncident.status.in_(OPEN_STATUSES),
                    ),
                    Instruction.user_id == access.user_id,
                    Instruction.deleted_at.is_(None),
                    Instruction.status == "active",
                    ~in_hold,
                )
            )
            .order_by(ReleaseEvent.released_at, ReleaseEvent.id)
        )
        return [(r[0], r[1], r[2]) for r in (await self.session.execute(stmt)).all()]
