"""Account deletion (DATABASE §4, SECURITY §10, API_SPEC §3 and §13.2).

One routine, two doors: ``DELETE /v1/me`` (signed in, just re-authenticated) and the public page
``/a/delete`` (emailed link + password: a Play Store requirement). Everything happens in one
transaction under the per-user lock, so the worker either runs before it or sees an inactive
account after it, and nothing contact-facing can follow the request except the all-clear that
undoes an alarm already raised:

* the open incident is voided and the contacts that were told get an all-clear;
* the schedule is off; releases and portal access are revoked; invitations stop working;
* every instruction loses its content and its recipients, and the user's wrapped key is deleted
  (so even a backup copy of the ciphertext can no longer be opened);
* contacts are scrubbed (those with an all-clear still queued are scrubbed by the maintenance
  job when it has left); sessions end; push tokens and unused links are dropped;
* the account becomes ``pending_deletion``, its address and password are overwritten, and the
  maintenance job removes the remaining rows after ``account_deletion_days``.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy import select

from app.api.deps import CurrentUser
from app.audit import writer as audit
from app.auth.base import AuthServiceBase
from app.auth.links import (
    DELETE_LINK_TTL,
    DELETE_PURPOSE,
    delete_link,
    hash_link_token,
    looks_like_delete_token,
    new_delete_token,
)
from app.auth.models import AUTH_TOKEN_PURPOSES
from app.checkins.repository import CheckinConfigRepository
from app.contacts.repository import ContactRepository
from app.core.errors import SessionRevoked
from app.core.validation import normalize_email
from app.incidents.closing import void_open_incident
from app.instructions.repository import InstructionRepository
from app.notifications import outbox
from app.notifications.email import EmailMessage
from app.notifications.mailer import DELETED_ADDRESS_SUFFIX, EmailTemplate
from app.notifications.models import Notification
from app.releases.repository import ReleaseRepository
from app.security.rate_limit import (
    DELETE_REQUEST_PER_EMAIL,
    DELETE_REQUEST_PER_EMAIL_NETWORK,
    WEB_DELETE_CONFIRM_PER_IP,
    WEB_LOGIN_PER_ACCOUNT,
)
from app.users.models import UserProfile

_NO_USER = uuid.UUID(int=0)
_UNUSABLE_HASH = "!"  # not a valid PHC string: no password can ever verify against it


class DeletionLinkInvalid(Exception):  # noqa: N818 - domain signal, rendered as a generic page
    """The link is malformed, unknown, used, expired, or its account is unusable."""


class WrongPassword(Exception):  # noqa: N818 - domain signal
    """The password on the deletion page did not match. The link stays valid."""


@dataclass(frozen=True)
class Deleted:
    purge_after: datetime
    emails: list[EmailMessage]


class DeletionService(AuthServiceBase):
    # ------------------------------------------------------------------ signed in

    async def request(self, current: CurrentUser) -> Deleted:
        """``DELETE /v1/me``: the caller has re-authenticated and typed DELETE."""
        now = await self._now()
        result = await self._delete(current.user_id, now, source="app")
        await self._commit_and_send(result.emails)
        return result

    # ------------------------------------------------------------------ the public page

    async def request_link(self, email: str) -> list[EmailMessage]:
        """``POST /a/delete``: always the same answer. Only a verified, active account gets a
        link, and it goes to the address on file."""
        now = await self._now()
        normalized = normalize_email(email)
        await self._limit_email(
            DELETE_REQUEST_PER_EMAIL_NETWORK, DELETE_REQUEST_PER_EMAIL, normalized, now
        )
        # No lock and no supersession: this page is public, and neither a held row lock nor a
        # link cancelled by the next request is something a stranger should be able to cause.
        user = await self.users.get_by_email(normalized)
        eligible = (
            user is not None and user.email_verified_at is not None and user.status == "active"
        )
        token = new_delete_token()
        secret_hash = hash_link_token(token)
        expires_at = now + DELETE_LINK_TTL
        message = self.services.mailer.render(
            EmailTemplate.ACCOUNT_DELETION_LINK,
            to=user.email if user is not None else email,
            link=delete_link(self.settings.public_base_url, token),
            expires_minutes=int(DELETE_LINK_TTL.total_seconds() // 60),
        )
        owner_id = user.id if user is not None and eligible else _NO_USER
        outbox_messages: list[EmailMessage] = []
        if user is not None and eligible:
            await self.codes.create_link(
                owner_id=owner_id,
                purpose=DELETE_PURPOSE,
                secret_hash=secret_hash,
                expires_at=expires_at,
                now=now,
            )
            outbox_messages.append(message)
        else:  # the same statements run, nothing is stored
            await self.codes.decoy_insert(
                kind="link",
                owner_id=owner_id,
                purpose=DELETE_PURPOSE,
                secret_hash=secret_hash,
                expires_at=expires_at,
                now=now,
            )
        await self.session.commit()
        return outbox_messages

    async def confirm_link(self, *, token: str, password: str, client_key: str) -> Deleted:
        """``POST /a/delete/confirm``. :class:`DeletionLinkInvalid` for any unusable link;
        :class:`WrongPassword` leaves the link valid so the person can try again."""
        now = await self._now()
        await self._limit_ip(client_key, now)
        if not looks_like_delete_token(token):
            raise DeletionLinkInvalid
        link = await self.codes.find_link(
            secret_hash=hash_link_token(token), purpose=DELETE_PURPOSE
        )
        if link is None or link.used_at is not None or link.expires_at <= now:
            raise DeletionLinkInvalid
        found = await self.users.get(link.user_id)
        if found is None or found.status != "active" or found.email_verified_at is None:
            raise DeletionLinkInvalid

        await self._limit(WEB_LOGIN_PER_ACCOUNT, str(found.id), now)
        if not await self.services.passwords.verify(found.password_hash, password):
            await self.services.audit.record_independent(
                self._event(
                    audit.REAUTH_FAILED,
                    now,
                    found.id,
                    unauthenticated=True,  # the caller holds a link, not a session
                    reason="account_deletion",
                    source="web",
                )
            )
            raise WrongPassword
        # The link is consumed in the same transaction as the deletion: both or neither.
        if not await self.codes.mark_used(owner_id=found.id, token_id=link.id, now=now):
            raise DeletionLinkInvalid
        result = await self._delete(found.id, now, source="web", verified_hash=found.password_hash)
        await self._commit_and_send(result.emails)
        return result

    async def _limit_ip(self, client_key: str, now: datetime) -> None:
        await self._limit(WEB_DELETE_CONFIRM_PER_IP, client_key, now)

    # ------------------------------------------------------------------ the routine

    async def _delete(
        self,
        user_id: uuid.UUID,
        now: datetime,
        *,
        source: str,
        verified_hash: str | None = None,
    ) -> Deleted:
        session = self.session
        # Lock order (ESCALATION_ENGINE §6.2): the per-user lock first, then the incident.
        config = await CheckinConfigRepository(session).get(owner_id=user_id, for_update=True)
        user = await self.users.get(user_id, for_update=True)
        if user is None or user.status != "active":
            raise SessionRevoked
        if verified_hash is not None and user.password_hash != verified_hash:
            # The password just checked is no longer the account's (a reset or change won the
            # race): the link, which was bound to that credential, no longer applies.
            raise DeletionLinkInvalid
        original_email = user.email

        outcome = await void_open_incident(
            session,
            audit_writer=self.services.audit,
            owner_id=user_id,
            closed_by="account_deleted",
            now=now,
            resume_schedule=False,
        )
        if config is not None and config.status != "inactive":
            config.status = "inactive"
            config.baseline_at = None
            config.next_due_at = None
            config.activated_at = None
            config.version += 1
            config.updated_at = now

        await ReleaseRepository(session).revoke_for_owner(
            owner_id=user_id, reason="account_deleted", now=now
        )
        await InstructionRepository(session).wipe_all(owner_id=user_id, now=now)
        await self.services.vault.destroy(session, user_id=user_id)

        await outbox.cancel_for_owner(
            session,
            owner_id=user_id,
            keep_templates=outbox.UNDOING_TEMPLATES,
            reason="account_deleted",
            now=now,
        )
        waiting = set(
            (
                await session.execute(
                    select(Notification.contact_id).where(
                        Notification.user_id == user_id,
                        Notification.contact_id.is_not(None),
                        Notification.template_key.in_(outbox.UNDOING_TEMPLATES),
                        Notification.status.in_(("queued", "sending")),
                    )
                )
            ).scalars()
        )
        contacts = ContactRepository(session)
        await contacts.invalidate_all_invitations(owner_id=user_id, now=now)
        await contacts.scrub_for_account_deletion(
            owner_id=user_id, keep={c for c in waiting if c}, now=now
        )

        await self.sessions.revoke_all(owner_id=user_id, reason="account_deleted", now=now)
        await self.devices.clear_all_push_tokens(owner_id=user_id, now=now)
        for purpose in AUTH_TOKEN_PURPOSES:
            await self.codes.invalidate_unused(owner_id=user_id, purpose=purpose, now=now)
        await self.codes.clear_payloads(owner_id=user_id)

        tombstone = f"deleted-{user_id}{DELETED_ADDRESS_SUFFIX}"
        user.status = "pending_deletion"
        user.deletion_requested_at = now
        user.email = tombstone
        user.email_normalized = tombstone
        user.password_hash = _UNUSABLE_HASH
        user.updated_at = now
        # The name stays until the retention job has seen the last all-clear leave: that message
        # says whose alert it withdraws. Everything else about the person goes now.
        profile = await session.get(UserProfile, user_id)
        if profile is not None:
            profile.phone_e164 = None
            profile.country_code = None
            profile.updated_at = now

        purge_after = now + timedelta(days=self.settings.account_deletion_days)
        await self.services.audit.record(
            session,
            self._event(
                audit.ACCOUNT_DELETION_REQUESTED,
                now,
                user_id,
                resource_type="account",
                user_visible=False,
                source=source,
                voided_incident=outcome is not None,
            ),
        )
        notice = self.services.mailer.render(
            EmailTemplate.ACCOUNT_DELETION_REQUESTED,
            to=original_email,
            purge_date=purge_after.strftime("%-d %B %Y"),
            all_clear=bool(outcome is not None and outcome.all_clear_to),
        )
        return Deleted(purge_after=purge_after, emails=[notice])
