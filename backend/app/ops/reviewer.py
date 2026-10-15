"""The Google Play reviewer (demo) account (``python -m cli.admin reviewer-account ...``;
docs/PLAY_STORE.md §6, docs/RELEASE.md).

Play's reviewers need working credentials for an app behind a login. Login is email + password
only (a code is needed only at signup), so a pre-verified account works with **no bypass of any
kind**: this module makes an ordinary account in the state a person reaches after onboarding,
and nothing in the API, the engine or the portal knows that it is special.

What ``create`` makes (and ``reset`` restores):

* a **verified** account, ``tier = 'premium'`` (every screen is reachable; Premium is granted by
  an operator in 1.0, PRD D5), display name "Play Reviewer", Asia/Kolkata, English;
* **one verified contact pointing at OUR inbox** (``--contact-email``): never a third party. The
  contact is marked accepted by the operator because the operator owns that inbox and consents
  for it; an address that is suppressed, or a contact row that declined, opted out or bounced, is
  refused instead of overridden. A public mail provider's domain is refused unless
  ``allow_public_contact`` (a typo in a Gmail address would point real alerts at a stranger);
* a two-stage plan (3 h grace: the contact is told; 24 h: the two instructions are shared);
* two **fictional** sample instructions, sealed with the vault like any other (so this runs as
  the API role with the KMS identity, like the ``kms`` commands);
* an **active daily schedule** (20:00 local). The engine treats the account like every other:
  if nobody checks in, it opens an incident, tells our inbox after the grace period and shares
  the samples with it after 24 hours. That is the honest demo of what the app does, and it is
  why ``reset`` refuses while an incident is open (close it with ``incident void``, which runs
  as the worker role and sends the all-clear, then reset).

The password is supplied by the caller (the command line generates one, or reads it from an
environment variable bound to a secret) and goes nowhere but the Argon2id hash: not to a log,
not to the audit row, not to an exception message.

``reset <user_id>`` only acts on an account that this command created (an
``operator.reviewer_account`` audit row names it): it can never be pointed at a real person's
account. It sets a new password, ends every session, restores the profile, the tier, the contact,
the plan, the two samples and the schedule, and removes (soft-deletes, as the app does) whatever
the reviewer added. Running it twice leaves the same state.

``--with-incident`` (an account already in a grace period) is deliberately NOT offered: only the
engine worker opens incidents (INV-1; this command runs as the API role, which cannot), and a
deadline written into the past would be a missed check-in that never happened, decided by an
operator instead of the database clock and the person's schedule (INV-3). The reviewer sees the
plan's timeline preview instead, and the real flow if the account is left without a check-in.

Concurrency: create works on a brand-new row nobody else can see. Reset takes the per-user lock
first (``SKIP LOCKED``: a busy account is refused, never waited for); the KMS is called before
the lock (``warm``), so a slow KMS never makes a check-in wait. Like every API-side module it
does not import ``app.engine`` (tests/engine/test_invariants.py).
"""

from __future__ import annotations

import secrets
import uuid
from dataclasses import dataclass
from datetime import datetime, time
from typing import Final

from pydantic_core import PydanticCustomError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.audit import writer as audit
from app.audit.models import AuditLog
from app.audit.writer import OPERATOR_TEXT_KEY, AuditEvent
from app.auth.models import User
from app.auth.repository import (
    AuthTokenRepository,
    CheckinBootstrapRepository,
    DeviceRepository,
    SessionRepository,
    UserRepository,
)
from app.checkins.models import CheckinConfiguration
from app.checkins.service import restart_clock
from app.contacts.models import TrustedContact
from app.contacts.repository import ContactRepository, SuppressionRepository
from app.contacts.tokens import suppression_hash_candidates
from app.core.logging import get_logger
from app.core.validation import clean_email, normalize_email
from app.incidents.repository import IncidentRepository
from app.instructions.models import Instruction
from app.instructions.repository import InstructionRepository
from app.notifications import outbox
from app.ops.admin import _safe_operator
from app.ops.users import UserCommandError, clean_reason
from app.plans.repository import PlanRepository
from app.plans.rules import StageDraft, plan_rules, validate_plan
from app.releases.repository import ReleaseRepository
from app.security.passwords import PasswordPolicyError, check_password_policy
from app.security.vault import InstructionVault, VaultUnavailableError
from app.users.entitlements import TIER_LIMITS
from app.users.repository import ProfileRepository

_log = get_logger("afterme.reviewer_account")

REVIEWER_NAME: Final = "Play Reviewer"
CONTACT_NAME: Final = "Review Team"  # a display name may not contain the brand (validation.py)
TIMEZONE: Final = "Asia/Kolkata"
COUNTRY: Final = "IN"
LOCALE: Final = "en"
TIER: Final = "premium"
INTERVAL_DAYS: Final = 1
DUE_LOCAL_TIME: Final = time(20, 0)
REMINDER_LEAD_MINUTES: Final = 60
GRACE_MINUTES: Final = 180  # stage 1: the contact is told
RELEASE_OFFSET_MINUTES: Final = 1_440  # stage 2: the samples are shared (the release minimum)
SAMPLES: Final = (
    (
        "home",
        "Spare key (sample)",
        "This is fictional sample content for app review.\n\n"
        "The spare house key is with the neighbour in flat 4B. The plants on the balcony need "
        "water twice a week.",
    ),
    (
        "documents",
        "Where the papers are (sample)",
        "This is fictional sample content for app review.\n\n"
        "The folder labelled 'Insurance' is in the second drawer of the desk. The landlord's "
        "number is on the fridge.",
    ),
)
REVOKE_REASON: Final = "operator"  # sessions: a value of auth.models.REVOKE_REASONS
TOKEN_PURPOSES: Final = ("email_change", "password_reset", "account_delete_web")

# Consumer mail domains: an alert must never be pointed at a mailbox we do not run because of a
# typo. Not a complete list (it does not need to be): the owner's own inbox is on afterme.app.
PUBLIC_MAIL_DOMAINS: Final = frozenset(
    {
        "gmail.com",
        "googlemail.com",
        "yahoo.com",
        "yahoo.co.in",
        "yahoo.co.uk",
        "ymail.com",
        "rocketmail.com",
        "outlook.com",
        "outlook.in",
        "hotmail.com",
        "hotmail.co.uk",
        "live.com",
        "live.in",
        "msn.com",
        "icloud.com",
        "me.com",
        "mac.com",
        "aol.com",
        "proton.me",
        "protonmail.com",
        "pm.me",
        "gmx.com",
        "gmx.de",
        "gmx.net",
        "web.de",
        "mail.com",
        "yandex.com",
        "yandex.ru",
        "mail.ru",
        "zoho.com",
        "zohomail.in",
        "rediffmail.com",
        "tutanota.com",
        "tuta.io",
        "fastmail.com",
        "hey.com",
        "qq.com",
        "163.com",
        "126.com",
    }
)

# 4 groups of 5 from 31 unambiguous characters (no 0/o, 1/l/i): about 99 bits, easy to type into
# Play Console and on a phone keyboard.
_PASSWORD_ALPHABET: Final = "abcdefghjkmnpqrstuvwxyz23456789"  # noqa: S105 - an alphabet
_PASSWORD_GROUPS: Final = 4
_PASSWORD_GROUP_LENGTH: Final = 5


class ReviewerCommandError(UserCommandError):
    """Refused; nothing was changed. The message holds no secret."""


@dataclass(frozen=True)
class ReviewerAccount:
    command: str  # create | reset
    user_id: uuid.UUID
    email: str
    contact_id: uuid.UUID
    sessions_revoked: int = 0
    contacts_removed: int = 0
    instructions_replaced: int = 0


def generate_password() -> str:
    groups = (
        "".join(secrets.choice(_PASSWORD_ALPHABET) for _ in range(_PASSWORD_GROUP_LENGTH))
        for _ in range(_PASSWORD_GROUPS)
    )
    return "-".join(groups)


def _email(value: str, flag: str) -> str:
    try:
        return clean_email(value)
    except PydanticCustomError:
        msg = f"{flag} is not a valid email address"
        raise ReviewerCommandError(msg) from None


def check_contact_email(contact_email: str, *, reviewer_email: str, allow_public: bool) -> str:
    """The cleaned contact address, or :class:`ReviewerCommandError`. The address is never part
    of the message (it may be a typo of a stranger's)."""
    contact = _email(contact_email, "--contact-email")
    normalized = normalize_email(contact)
    if normalized == normalize_email(reviewer_email):
        msg = "--contact-email must be a different inbox from the reviewer's login address"
        raise ReviewerCommandError(msg)
    domain = normalized.rsplit("@", 1)[-1]
    if domain in PUBLIC_MAIL_DOMAINS and not allow_public:
        msg = (
            f"--contact-email is on a public mail provider ({domain}): alerts and the sample "
            "instructions go to it. Use an inbox of ours (e.g. on afterme.app), or pass "
            "--allow-public-contact if this mailbox really is ours"
        )
        raise ReviewerCommandError(msg)
    return contact


def _password(password: str, email: str) -> None:
    try:
        check_password_policy(password, email=email)
    except PasswordPolicyError as exc:
        msg = f"the password does not meet the policy ({exc.code})"
        raise ReviewerCommandError(msg) from None


def _event(
    now: datetime, user_id: uuid.UUID, operator: str, reason: str, **metadata: str | int
) -> AuditEvent:
    return AuditEvent(
        action=audit.OPERATOR_REVIEWER_ACCOUNT,
        occurred_at=now,
        subject_user_id=user_id,
        actor_type="operator",
        resource_type="user",
        resource_id=user_id,
        metadata={
            "operator": operator[:40],
            "reason_length": len(reason),
            OPERATOR_TEXT_KEY: reason,
            **metadata,
        },
        user_visible=False,
    )


async def _refuse_if_suppressed(
    session: AsyncSession, services: AppServices, contact_normalized: str
) -> None:
    hashes = suppression_hash_candidates(services.pepper, contact_normalized)
    if await SuppressionRepository(session).is_suppressed(hashes):
        msg = (
            "--contact-email is on the global suppression list (it opted out of AfterMe, "
            "bounced or complained): it is never contacted again. Use another inbox of ours"
        )
        raise ReviewerCommandError(msg)


# ---------------------------------------------------------------------------------- seeding


async def _verified_contact(
    session: AsyncSession, user_id: uuid.UUID, contact: str, now: datetime
) -> TrustedContact:
    """Our inbox as the account's verified contact: the existing row if there is one."""
    repo = ContactRepository(session)
    normalized = normalize_email(contact)
    row = (
        await session.execute(
            select(TrustedContact)
            .where(
                TrustedContact.user_id == user_id,
                TrustedContact.email_normalized == normalized,
                TrustedContact.deleted_at.is_(None),
            )
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    ).scalar_one_or_none()
    if row is None:
        row = await repo.create(
            owner_id=user_id,
            display_name=CONTACT_NAME,
            relationship="other",
            relationship_label=None,
            email=normalized,
            phone_e164=None,
            priority=1,
            now=now,
        )
    elif row.verification_status not in ("pending", "verified"):
        msg = (
            f"the review inbox's contact row is '{row.verification_status}': its answer is not "
            "overridden. Find out why (an opt-out or a bounce of our own inbox), then use "
            "another inbox"
        )
        raise ReviewerCommandError(msg)
    await repo.invalidate_invitations(owner_id=user_id, contact_id=row.id, now=now)
    if row.verification_status != "verified":
        row.verification_status = "verified"
        row.status_changed_at = now
    row.verified_at = row.verified_at or now
    row.display_name = CONTACT_NAME
    row.relationship = "other"
    row.relationship_label = None
    row.phone_e164 = None
    row.priority = 1
    row.is_active = True
    row.updated_at = now
    await session.flush()
    return row


async def _seed(
    session: AsyncSession,
    services: AppServices,
    vault: InstructionVault,
    *,
    user_id: uuid.UUID,
    contact: str,
    now: datetime,
) -> uuid.UUID:
    """Contact, plan, samples and schedule, on an account that has no live instruction and no
    open incident (the caller made sure). Returns the contact id."""
    row = await _verified_contact(session, user_id, contact, now)

    # The plan: two stages, validated by the same rules as PUT /v1/plan (so a configuration that
    # would refuse them refuses this command instead of seeding a plan the API would not accept).
    limits = TIER_LIMITS[TIER]
    rules = plan_rules(
        services.settings, max_stages=limits.stages, custom_offsets=limits.custom_offsets
    )
    drafts = [
        StageDraft(None, GRACE_MINUTES, (row.id,)),
        StageDraft(None, RELEASE_OFFSET_MINUTES, (row.id,)),
    ]
    errors = validate_plan(grace_minutes=GRACE_MINUTES, stages=drafts, rules=rules)
    if errors or rules.release_offset_min > RELEASE_OFFSET_MINUTES:
        msg = "the sample plan does not satisfy this deployment's plan rules; nothing was changed"
        raise ReviewerCommandError(msg)
    plans = PlanRepository(session)
    await plans.ensure(owner_id=user_id, now=now)
    plan = await plans.get(owner_id=user_id, for_update=True)
    if plan is None:  # pragma: no cover - ensured just above
        msg = "the account has no plan"
        raise ReviewerCommandError(msg)
    old = await plans.steps(owner_id=user_id, plan_id=plan.id)
    await plans.delete_steps(owner_id=user_id, step_ids=[s.id for s in old])
    plan.grace_minutes = GRACE_MINUTES
    steps = []
    for position, draft in enumerate(drafts, start=1):
        step = await plans.add_step(
            owner_id=user_id,
            plan_id=plan.id,
            position=position,
            offset_minutes=draft.offset_minutes,
            now=now,
        )
        await plans.set_step_contacts(
            owner_id=user_id, step_id=step.id, contact_ids=list(draft.notify_contact_ids)
        )
        steps.append(step)
    plan.version += 1
    plan.updated_at = now

    # The samples, sealed like any instruction, shared with our inbox at stage 2.
    items = InstructionRepository(session)
    for category, title, body in SAMPLES:
        instruction_id = uuid.uuid4()
        try:
            ciphertext, key_version = await vault.seal(
                session, user_id=user_id, instruction_id=instruction_id, title=title, body=body
            )
        except VaultUnavailableError:
            msg = "the KMS is unavailable; nothing was changed (run the command again later)"
            raise ReviewerCommandError(msg) from None
        items.add(
            Instruction(
                id=instruction_id,
                user_id=user_id,
                category_id=category,
                status="active",
                content_ciphertext=ciphertext,
                content_key_version=key_version,
                created_at=now,
                updated_at=now,
            )
        )
        await session.flush()
        await items.replace_recipients(
            owner_id=user_id, instruction_id=instruction_id, wanted={row.id: steps[1].id}, now=now
        )

    # The schedule: on, daily at 20:00 local, counted from now.
    cfg = await session.get(CheckinConfiguration, user_id, populate_existing=True)
    if cfg is None:  # pragma: no cover - created with the account
        msg = "the account has no schedule"
        raise ReviewerCommandError(msg)
    cfg.interval_days = INTERVAL_DAYS
    cfg.due_local_time = DUE_LOCAL_TIME
    cfg.reminder_lead_minutes = REMINDER_LEAD_MINUTES
    cfg.status = "active"
    cfg.activated_at = now
    restart_clock(cfg, TIMEZONE, now)
    cfg.version += 1
    cfg.updated_at = now
    await session.flush()
    return row.id


async def _profile(session: AsyncSession, user_id: uuid.UUID, now: datetime) -> None:
    await ProfileRepository(session).upsert(
        owner_id=user_id,
        display_name=REVIEWER_NAME,
        timezone=TIMEZONE,
        locale=LOCALE,
        country_code=COUNTRY,
        now=now,
    )


# ---------------------------------------------------------------------------------- create


async def create(
    services: AppServices,
    *,
    operator: str,
    email: str,
    contact_email: str,
    reason: str,
    password: str,
    allow_public_contact: bool = False,
) -> ReviewerAccount:
    """A new reviewer account, all of it in ONE transaction: the KMS refusing, or anything else
    failing, leaves no account behind. Refuses an address that already has an account (it may
    be a real person's: ``reset`` takes an id, and only of an account made here)."""
    text = clean_reason(reason)
    operator = _safe_operator(operator)
    login = _email(email, "--email")
    contact = check_contact_email(
        contact_email, reviewer_email=login, allow_public=allow_public_contact
    )
    _password(password, login)
    password_hash = await services.passwords.hash(password)
    # Its own key cache, and no independent session: the key row is created in the same
    # transaction as the (still invisible) account, so a rollback takes both. The KMS call is
    # made while this transaction holds rows nobody else can see yet: it blocks no one.
    vault = InstructionVault(services.vault.kms)

    async with services.db.sessionmaker() as session, session.begin():
        now = await services.clock.now(session)
        await _refuse_if_suppressed(session, services, normalize_email(contact))
        users = UserRepository(session)
        existing = await users.get_by_email(normalize_email(login))
        if existing is not None:
            msg = (
                f"an account with this address already exists ({existing.id}); nothing was "
                "changed. If it is a reviewer account, use `reviewer-account reset <user_id>`"
            )
            raise ReviewerCommandError(msg)
        user_id = await users.insert_if_absent(
            email=login,
            email_normalized=normalize_email(login),
            password_hash=password_hash,
            now=now,
        )
        if user_id is None:  # pragma: no cover - registered between the two statements
            msg = "an account with this address was created meanwhile; nothing was changed"
            raise ReviewerCommandError(msg)
        user = await users.get(user_id, for_update=True)
        if user is None:  # pragma: no cover - inserted just above
            msg = "the account could not be read back"
            raise ReviewerCommandError(msg)
        user.email_verified_at = now
        user.tier = TIER
        user.updated_at = now
        await _profile(session, user_id, now)
        await CheckinBootstrapRepository(session).create_default(owner_id=user_id, now=now)
        await PlanRepository(session).ensure(owner_id=user_id, now=now)
        try:
            await vault.warm(session, user_id=user_id)
        except VaultUnavailableError:
            msg = "the KMS is unavailable; nothing was created (run the command again later)"
            raise ReviewerCommandError(msg) from None
        contact_id = await _seed(
            session, services, vault, user_id=user_id, contact=contact, now=now
        )
        await services.audit.record(
            session,
            _event(
                now,
                user_id,
                operator,
                text,
                command="create",
                contacts=1,
                instructions=len(SAMPLES),
                stages=2,
            ),
        )
    _log.warning("operator.reviewer_account_created", user_id=str(user_id), operator=operator)
    return ReviewerAccount("create", user_id, login, contact_id)


# ---------------------------------------------------------------------------------- reset


async def _is_reviewer_account(session: AsyncSession, user_id: uuid.UUID) -> bool:
    stmt = select(
        select(AuditLog.id)
        .where(
            AuditLog.action == audit.OPERATOR_REVIEWER_ACCOUNT,
            AuditLog.subject_user_id == user_id,
        )
        .exists()
    )
    return bool((await session.execute(stmt)).scalar_one())


async def _current_inbox(session: AsyncSession, user_id: uuid.UUID) -> str | None:
    """The one live, verified contact, when there is exactly one."""
    rows = list(
        (
            await session.execute(
                select(TrustedContact.email_normalized).where(
                    TrustedContact.user_id == user_id,
                    TrustedContact.deleted_at.is_(None),
                    TrustedContact.verification_status == "verified",
                )
            )
        ).scalars()
    )
    return rows[0] if len(rows) == 1 and rows[0] else None


async def _remove_contact(
    session: AsyncSession, user_id: uuid.UUID, contact_id: uuid.UUID, now: datetime
) -> None:
    """What ``DELETE /v1/contacts/{id}`` does, without the step-up (the operator is acting)."""
    await ContactRepository(session).invalidate_invitations(
        owner_id=user_id, contact_id=contact_id, now=now
    )
    await PlanRepository(session).remove_contact(owner_id=user_id, contact_id=contact_id)
    await InstructionRepository(session).remove_contact(owner_id=user_id, contact_id=contact_id)
    await ReleaseRepository(session).revoke_for_contact(
        owner_id=user_id, contact_id=contact_id, reason="contact_removed", now=now
    )
    await outbox.cancel_for_contact(
        session, owner_id=user_id, contact_id=contact_id, reason="contact_removed", now=now
    )
    await ContactRepository(session).soft_delete(owner_id=user_id, contact_id=contact_id, now=now)


async def _remove_instructions(session: AsyncSession, user_id: uuid.UUID, now: datetime) -> int:
    """What ``DELETE /v1/instructions/{id}`` does, for every live one: content wiped."""
    items = InstructionRepository(session)
    releases = ReleaseRepository(session)
    rows = list(
        (
            await session.execute(
                select(Instruction)
                .where(Instruction.user_id == user_id, Instruction.deleted_at.is_(None))
                .with_for_update()
                .execution_options(populate_existing=True)
            )
        ).scalars()
    )
    for row in rows:
        await items.clear_recipients(owner_id=user_id, instruction_id=row.id)
        await releases.revoke_for_instruction(
            owner_id=user_id, instruction_id=row.id, reason="instruction_removed", now=now
        )
        row.content_ciphertext = None
        row.status = "inactive"
        row.deleted_at = now
        row.updated_at = now
    await session.flush()
    return len(rows)


async def _lock_for_reset(
    session: AsyncSession, services: AppServices, user_id: uuid.UUID, contact: str
) -> User:
    """The per-user lock (never waited for), then the account row, then the refusals that must
    be judged under the lock."""
    # THE per-user lock (ESCALATION_ENGINE §6.2), SKIP LOCKED like EngineStore.lock_user: this
    # module is API-role tooling and does not import the engine (tests/engine/test_invariants.py).
    cfg = (
        await session.execute(
            select(CheckinConfiguration)
            .where(CheckinConfiguration.user_id == user_id)
            .with_for_update(skip_locked=True)
            .execution_options(populate_existing=True)
        )
    ).scalar_one_or_none()
    if cfg is None:
        msg = "the account is busy (a request or the engine holds it); try again"
        raise ReviewerCommandError(msg)
    user = await UserRepository(session).get(user_id, for_update=True)
    if user is None or user.status != "active":
        msg = "the account changed meanwhile; nothing was changed"
        raise ReviewerCommandError(msg)
    incident = await IncidentRepository(session).get_open(owner_id=user_id)
    if incident is not None:
        msg = (
            f"incident {incident.id} is open for this account; a reset never closes one by "
            f"itself. Close it deliberately with `incident void {incident.id}` (worker role; "
            "our inbox gets the withdrawn alert), then run reset again"
        )
        raise ReviewerCommandError(msg)
    if cfg.status == "incident_open":  # pragma: no cover - only with an open incident
        msg = "the schedule says an incident is open; investigate before resetting"
        raise ReviewerCommandError(msg)
    await _refuse_if_suppressed(session, services, normalize_email(contact))
    return user


async def _new_credentials(
    session: AsyncSession, user: User, password_hash: str, now: datetime
) -> int:
    """The new password, no lock-out, every session ended, every pending link or code void.
    Returns the sessions ended."""
    user.password_hash = password_hash
    user.password_changed_at = now
    user.failed_login_count = 0
    user.locked_until = None
    user.tier = TIER
    user.email_verified_at = user.email_verified_at or now
    user.updated_at = now
    revoked = await SessionRepository(session).revoke_all(
        owner_id=user.id, reason=REVOKE_REASON, now=now
    )
    await DeviceRepository(session).clear_all_push_tokens(owner_id=user.id, now=now)
    tokens = AuthTokenRepository(session)
    for purpose in TOKEN_PURPOSES:
        await tokens.invalidate_unused(owner_id=user.id, purpose=purpose, now=now)
    return revoked


async def reset(
    services: AppServices,
    *,
    operator: str,
    user_id: uuid.UUID,
    reason: str,
    password: str,
    contact_email: str | None = None,
    allow_public_contact: bool = False,
) -> ReviewerAccount:
    """Back to the state ``create`` made, with a new password and no session."""
    text = clean_reason(reason)
    operator = _safe_operator(operator)

    # 1. Who, and the checks that need no lock.
    async with services.db.sessionmaker() as session, session.begin():
        user = await UserRepository(session).get(user_id)
        if user is None:
            msg = "no such user"
            raise ReviewerCommandError(msg)
        if not await _is_reviewer_account(session, user_id):
            msg = (
                "this account was not made by `reviewer-account create` (no "
                "operator.reviewer_account record names it); it is never reset by this command"
            )
            raise ReviewerCommandError(msg)
        if user.status != "active":
            msg = (
                f"the account is {user.status}; it is not reset. Make a new reviewer account "
                "with another address (e.g. a +2 alias of the review inbox)"
            )
            raise ReviewerCommandError(msg)
        login = user.email
        inbox = (
            contact_email if contact_email is not None else await _current_inbox(session, user_id)
        )
    if inbox is None:
        msg = "the account has no single verified contact to keep: pass --contact-email"
        raise ReviewerCommandError(msg)
    contact = check_contact_email(inbox, reviewer_email=login, allow_public=allow_public_contact)
    _password(password, login)
    password_hash = await services.passwords.hash(password)

    # 2. The KMS, before the lock: a slow or failing KMS changes nothing and blocks no one.
    vault = InstructionVault(
        services.vault.kms, independent_session=services.db.independent_session
    )
    async with services.db.sessionmaker() as session, session.begin():
        try:
            await vault.warm(session, user_id=user_id)
        except VaultUnavailableError:
            msg = "the KMS is unavailable; nothing was changed (run the command again later)"
            raise ReviewerCommandError(msg) from None

    # 3. One transaction under the per-user lock.
    async with services.db.sessionmaker() as session, session.begin():
        now = await services.clock.now(session)
        user = await _lock_for_reset(session, services, user_id, contact)
        revoked = await _new_credentials(session, user, password_hash, now)
        await _profile(session, user_id, now)

        replaced = await _remove_instructions(session, user_id, now)
        keep = normalize_email(contact)
        others = [
            c.id
            for c in await ContactRepository(session).list(owner_id=user_id)
            if c.email_normalized != keep
        ]
        for contact_id in others:
            await _remove_contact(session, user_id, contact_id, now)
        contact_id = await _seed(
            session, services, vault, user_id=user_id, contact=contact, now=now
        )
        await services.audit.record(
            session,
            _event(
                now,
                user_id,
                operator,
                text,
                command="reset",
                sessions_revoked=revoked,
                contacts_removed=len(others),
                instructions_replaced=replaced,
            ),
        )
    _log.warning(
        "operator.reviewer_account_reset",
        user_id=str(user_id),
        operator=operator,
        sessions_revoked=revoked,
    )
    return ReviewerAccount(
        "reset",
        user_id,
        login,
        contact_id,
        sessions_revoked=revoked,
        contacts_removed=len(others),
        instructions_replaced=replaced,
    )
