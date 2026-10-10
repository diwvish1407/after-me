"""SQL for trusted contacts, invitations and the suppression list.

Ownership rule (ARCHITECTURE §4.3): :class:`ContactRepository` is owner-scoped like every other
repository: each method takes a keyword-only ``owner_id`` and filters by it, so one user can
never read or change another user's contact. The classes below it work on contact rows *without*
an owner because the caller is not a signed-in user but a contact holding a secret link. Each
method says what authenticates it, and ``tests/security/test_repository_ownership.py`` lists
every one of them as a deliberate exception:

* :class:`PortalRepository`: lookups by the SHA-256 of a presented invitation token, or by a
  contact ID that was proven by a valid opt-out MAC.
* :class:`SuppressionRepository`: the global list, and the one deliberate cross-user write
  (:meth:`SuppressionRepository.opt_out_all_contacts_with_email`).
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import BigInteger, ColumnElement, and_, exists, false, func, literal, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.models import User
from app.contacts.models import ContactVerification, EmailSuppression, TrustedContact
from app.contacts.tokens import CONSENT_TEXT_VERSION
from app.users.models import UserProfile

MAX_LISTED = 25  # the premium maximum: a list never holds more (API_SPEC §7)


class ContactRepository:
    """Owner-scoped access to a user's own contacts and their invitations."""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    @staticmethod
    def _live(owner_id: uuid.UUID) -> tuple[ColumnElement[bool], ColumnElement[bool]]:
        return (TrustedContact.user_id == owner_id, TrustedContact.deleted_at.is_(None))

    async def list(self, *, owner_id: uuid.UUID) -> list[TrustedContact]:
        stmt = (
            select(TrustedContact)
            .where(*self._live(owner_id))
            .order_by(TrustedContact.priority, TrustedContact.created_at, TrustedContact.id)
            .limit(MAX_LISTED)
        )
        return list((await self._session.execute(stmt)).scalars())

    async def get(
        self, *, owner_id: uuid.UUID, contact_id: uuid.UUID, for_update: bool = False
    ) -> TrustedContact | None:
        stmt = select(TrustedContact).where(TrustedContact.id == contact_id, *self._live(owner_id))
        if for_update:
            stmt = stmt.with_for_update().execution_options(populate_existing=True)
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def display_names(
        self, *, owner_id: uuid.UUID, contact_ids: Sequence[uuid.UUID]
    ) -> dict[uuid.UUID, str]:
        """Names of the user's own contacts, deleted ones included: ``display_name`` is kept on
        a soft delete so that the user's own history can still say who was notified."""
        if not contact_ids:
            return {}
        stmt = select(TrustedContact.id, TrustedContact.display_name).where(
            TrustedContact.user_id == owner_id, TrustedContact.id.in_(list(contact_ids))
        )
        return {r[0]: r[1] for r in (await self._session.execute(stmt)).all()}

    async def count_live(self, *, owner_id: uuid.UUID) -> int:
        stmt = select(func.count()).select_from(TrustedContact).where(*self._live(owner_id))
        return int((await self._session.execute(stmt)).scalar_one())

    async def max_priority(self, *, owner_id: uuid.UUID) -> int:
        stmt = select(func.coalesce(func.max(TrustedContact.priority), 0)).where(
            *self._live(owner_id)
        )
        return int((await self._session.execute(stmt)).scalar_one())

    async def email_in_use(
        self,
        *,
        owner_id: uuid.UUID,
        email_normalized: str,
        except_contact_id: uuid.UUID | None = None,
    ) -> bool:
        conditions = [
            TrustedContact.email_normalized == email_normalized,
            *self._live(owner_id),
        ]
        if except_contact_id is not None:
            conditions.append(TrustedContact.id != except_contact_id)
        stmt = select(exists().where(and_(*conditions)))
        return bool((await self._session.execute(stmt)).scalar_one())

    async def create(
        self,
        *,
        owner_id: uuid.UUID,
        display_name: str,
        relationship: str,
        relationship_label: str | None,
        email: str,
        phone_e164: str | None,
        priority: int,
        now: datetime,
    ) -> TrustedContact:
        """``email`` is already normalised (trimmed, lower case). The database's partial unique
        index is the final arbiter of duplicates: the caller maps its violation to 409."""
        contact = TrustedContact(
            user_id=owner_id,
            display_name=display_name,
            relationship=relationship,
            relationship_label=relationship_label,
            email=email,
            email_normalized=email,
            phone_e164=phone_e164,
            priority=priority,
            verification_status="pending",
            status_changed_at=now,
            is_active=True,
            invitation_send_count=0,
            created_at=now,
            updated_at=now,
        )
        self._session.add(contact)
        await self._session.flush()
        return contact

    async def soft_delete(
        self, *, owner_id: uuid.UUID, contact_id: uuid.UUID, now: datetime
    ) -> bool:
        """Mark deleted and scrub every personal field at once (DATABASE §4). ``display_name``
        stays for the owner's own history. Returns False when there was nothing to delete."""
        stmt = (
            update(TrustedContact)
            .where(TrustedContact.id == contact_id, *self._live(owner_id))
            .values(
                deleted_at=now,
                email=None,
                email_normalized=None,
                phone_e164=None,
                relationship_label=None,
                updated_at=now,
            )
            .returning(TrustedContact.id)
        )
        return (await self._session.execute(stmt)).scalar_one_or_none() is not None

    # ------------------------------------------------------------------ invitations

    async def invalidate_invitations(
        self, *, owner_id: uuid.UUID, contact_id: uuid.UUID, now: datetime
    ) -> int:
        """Every unanswered invitation of this contact stops working now."""
        owned = (
            select(TrustedContact.id)
            .where(TrustedContact.id == contact_id, TrustedContact.user_id == owner_id)
            .scalar_subquery()
        )
        stmt = (
            update(ContactVerification)
            .where(
                ContactVerification.contact_id == owned,
                ContactVerification.responded_at.is_(None),
                ContactVerification.expires_at > now,
            )
            .values(expires_at=now)
        )
        return int((await self._session.execute(stmt)).rowcount or 0)  # type: ignore[attr-defined]

    async def add_invitation(
        self,
        *,
        owner_id: uuid.UUID,
        contact_id: uuid.UUID,
        token_hash: bytes,
        expires_at: datetime,
        now: datetime,
        decoy: bool = False,
    ) -> None:
        """Store an invitation for a contact that belongs to ``owner_id``. With ``decoy`` the same
        INSERT runs with ``WHERE false`` and writes nothing: a suppressed address costs the same
        database work as a normal one."""
        values = (
            contact_id,
            token_hash,
            now,
            expires_at,
            CONSENT_TEXT_VERSION,
            now,
        )
        columns = (
            ContactVerification.contact_id,
            ContactVerification.token_hash,
            ContactVerification.sent_at,
            ContactVerification.expires_at,
            ContactVerification.consent_text_version,
            ContactVerification.created_at,
        )
        source = select(
            *(literal(v, type_=c.type) for v, c in zip(values, columns, strict=True))
        ).where(
            false()
            if decoy
            else exists().where(
                TrustedContact.id == contact_id,
                TrustedContact.user_id == owner_id,
                TrustedContact.deleted_at.is_(None),
            )
        )
        await self._session.execute(
            insert(ContactVerification).from_select([c.key for c in columns], source)
        )


@dataclass(frozen=True)
class PortalContact:
    """A contact together with the account that invited them (for the pages and the notices)."""

    contact: TrustedContact
    owner_id: uuid.UUID
    owner_email: str
    owner_name: str


@dataclass(frozen=True)
class InvitationRow:
    contact_id: uuid.UUID
    expires_at: datetime
    responded_at: datetime | None


class PortalRepository:
    """Contact-facing lookups, authenticated by a secret the caller presented (see module doc)."""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def find_invitation(self, token_hash: bytes) -> InvitationRow | None:
        """The invitation with this token hash: possession of the secret is the credential.
        The caller checks ``responded_at`` and ``expires_at``."""
        stmt = select(
            ContactVerification.contact_id,
            ContactVerification.expires_at,
            ContactVerification.responded_at,
        ).where(ContactVerification.token_hash == token_hash)
        row = (await self._session.execute(stmt)).one_or_none()
        if row is None:
            return None
        return InvitationRow(
            contact_id=row.contact_id, expires_at=row.expires_at, responded_at=row.responded_at
        )

    async def get_contact(
        self, contact_id: uuid.UUID, *, for_update: bool = False
    ) -> PortalContact | None:
        """A live contact with its inviter (``contact_id`` comes from a token the caller already
        proved: an invitation hash or an opt-out MAC)."""
        stmt = (
            select(TrustedContact, User.id, User.email, UserProfile.display_name)
            .join(User, User.id == TrustedContact.user_id)
            .outerjoin(UserProfile, UserProfile.user_id == User.id)
            .where(TrustedContact.id == contact_id, TrustedContact.deleted_at.is_(None))
            .execution_options(populate_existing=True)
        )
        if for_update:
            stmt = stmt.with_for_update(of=TrustedContact)
        row = (await self._session.execute(stmt)).one_or_none()
        if row is None:
            return None
        contact, owner_id, owner_email, owner_name = row
        return PortalContact(
            contact=contact,
            owner_id=owner_id,
            owner_email=owner_email,
            owner_name=owner_name or "Someone",
        )

    async def answer_invitation(
        self,
        *,
        token_hash: bytes,
        response: str,
        ip_hash: bytes,
        now: datetime,
    ) -> bool:
        """Record the answer exactly once: the UPDATE matches only an invitation that is
        unanswered and unexpired, so concurrent submissions succeed at most once."""
        stmt = (
            update(ContactVerification)
            .where(
                ContactVerification.token_hash == token_hash,
                ContactVerification.responded_at.is_(None),
                ContactVerification.expires_at > now,
            )
            .values(
                responded_at=now,
                response=response,
                consent_text_version=CONSENT_TEXT_VERSION,
                ip_hash=ip_hash,
            )
            .returning(ContactVerification.id)
        )
        return (await self._session.execute(stmt)).scalar_one_or_none() is not None

    async def invalidate_invitations(self, contact_id: uuid.UUID, *, now: datetime) -> None:
        """Opt-out or decline ends every unanswered invitation of the contact (``contact_id``
        was resolved from a presented token)."""
        await self._session.execute(
            update(ContactVerification)
            .where(
                ContactVerification.contact_id == contact_id,
                ContactVerification.responded_at.is_(None),
                ContactVerification.expires_at > now,
            )
            .values(expires_at=now)
        )


@dataclass(frozen=True)
class OptedOutContact:
    contact_id: uuid.UUID
    owner_id: uuid.UUID
    owner_email: str
    owner_name: str
    contact_name: str


class SuppressionRepository:
    """The global suppression list and the cross-user opt-out."""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def is_suppressed(self, email_hashes: Sequence[bytes]) -> bool:
        """Whether any of ``email_hashes`` (the current and previous pepper's HMAC of one
        normalised address) is on the list. The list is global by design."""
        stmt = select(exists().where(EmailSuppression.email_hash.in_(list(email_hashes))))
        return bool((await self._session.execute(stmt)).scalar_one())

    async def lock_address(self, email_hash: bytes) -> None:
        """Wait for, then hold until the transaction ends, the lock of one address.

        Every request that is about to opt an address out *everywhere* takes this lock before it
        locks any contact row, so two such requests (the same person answering invitations from
        two accounts at once) run one after the other. Without it each would hold its own
        contact and wait for the other's. ``email_hash`` is the suppression hash, not the
        address."""
        key = int.from_bytes(email_hash[:8], "big", signed=True)
        await self._session.execute(select(func.pg_advisory_xact_lock(literal(key, BigInteger))))

    async def add(
        self,
        email_hash: bytes,
        *,
        reason: str,
        source_contact_id: uuid.UUID | None,
        now: datetime,
    ) -> None:
        stmt = (
            insert(EmailSuppression)
            .values(
                email_hash=email_hash,
                reason=reason,
                source_contact_id=source_contact_id,
                created_at=now,
            )
            .on_conflict_do_nothing(index_elements=[EmailSuppression.email_hash])
        )
        await self._session.execute(stmt)

    async def opt_out_all_contacts_with_email(
        self,
        *,
        email_normalized: str,
        now: datetime,
        except_contact_id: uuid.UUID | None = None,
    ) -> list[OptedOutContact]:
        """THE cross-user write. A person who chose *Never contact me about AfterMe again* is
        listed as a contact by possibly several accounts; every live contact row holding this
        address (whoever owns it) becomes ``opted_out`` and loses its unanswered invitations.

        Authorised by the caller having verified an opt-out MAC or an invitation token for this
        very address; ``email_normalized`` is read from that contact, never from request input.
        Callers hold :meth:`lock_address` for the address first, which is what keeps concurrent
        opt-outs from deadlocking (they have already locked their own contact row); the rows are
        also locked in ID order. Returns the affected rows (with their owners) so each owner can
        be told.
        """
        ids = (
            select(TrustedContact.id)
            .where(
                TrustedContact.email_normalized == email_normalized,
                TrustedContact.deleted_at.is_(None),
                TrustedContact.verification_status != "opted_out",
            )
            .order_by(TrustedContact.id)
            .with_for_update()
        )
        if except_contact_id is not None:
            ids = ids.where(TrustedContact.id != except_contact_id)
        affected = list(
            (
                await self._session.execute(
                    update(TrustedContact)
                    .where(TrustedContact.id.in_(ids.scalar_subquery()))
                    .values(
                        verification_status="opted_out",
                        verified_at=None,
                        status_changed_at=now,
                        updated_at=now,
                    )
                    .returning(
                        TrustedContact.id, TrustedContact.user_id, TrustedContact.display_name
                    )
                )
            ).all()
        )
        if not affected:
            return []
        await self._session.execute(
            update(ContactVerification)
            .where(
                ContactVerification.contact_id.in_([a.id for a in affected]),
                ContactVerification.responded_at.is_(None),
                ContactVerification.expires_at > now,
            )
            .values(expires_at=now)
        )
        owners = {
            row.id: row
            for row in (
                await self._session.execute(
                    select(User.id, User.email, UserProfile.display_name)
                    .outerjoin(UserProfile, UserProfile.user_id == User.id)
                    .where(User.id.in_({a.user_id for a in affected}))
                )
            ).all()
        }
        return [
            OptedOutContact(
                contact_id=a.id,
                owner_id=a.user_id,
                owner_email=owners[a.user_id].email,
                owner_name=owners[a.user_id].display_name or "Someone",
                contact_name=a.display_name,
            )
            for a in affected
        ]
