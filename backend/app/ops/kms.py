"""Key maintenance (``python -m cli.admin kms ...``; SECURITY §6.2, DEPLOYMENT §9).

Two kinds of rotation exist and they are different jobs:

* **KEK rotation** is Cloud KMS's own: a new key *version* becomes primary (automatically every
  90 days) and new wraps use it; old ciphertext keeps decrypting. Nothing in the application has
  to change. What the application adds is :func:`rewrap`, which rewrites each
  ``user_keys.wrapped_dek`` under the current primary version (so that an old version can be
  disabled and later destroyed without orphaning anyone's key). The DEK, and so every
  instruction ciphertext, is untouched.
* **DEK rotation** is :func:`rotate_user`: a new random DEK for one user, every instruction of
  theirs re-encrypted under it, ``dek_version`` +1. For a suspected exposure of one account's
  key, not for routine use: ``instruction_aad`` binds a ciphertext to ``dek_version``, so
  ``open()`` needs the current version (it does not bind ``content_version``, so an edit does
  not change what a ciphertext is bound to).

Both run as the **API role** (``DATABASE_URL``): it is the only role that may read keys and
content (the worker has nothing on ``user_keys``, migration 0006); migration 0012 gives it
column-level UPDATE on ``user_keys`` and a guard that a version moves forward by one.

Concurrency and interruption
----------------------------
One user, one transaction; killing the process at any point leaves each user either wholly
before or wholly after, and re-running the command continues (a key that is already current is
skipped). The order is:

1. **Outside any transaction or lock**: read the key row, unwrap it, (for rotation) make the new
   DEK, wrap it. These are the KMS calls, up to 3 s each; nothing is held while they run, so a
   slow or failing KMS can never make a check-in, which takes the same user lock, wait.
2. **Short transaction**: the per-user lock first (the user's ``checkin_configurations`` row,
   ``FOR UPDATE SKIP LOCKED``: the first lock in config -> incident -> actions -> notifications,
   and the only one this job needs), then ``user_keys FOR UPDATE``, then a compare-and-swap: the
   row must still hold exactly the wrapped key, key id and version read in step 1, otherwise the
   user is reported as ``changed`` and left for the next run. Only CPU (AES-GCM) and updates run
   under the lock. A locked user (an API request or the engine holds the lock) is skipped as
   ``busy``, never waited for.

An API process that holds the old DEK in its cache after ``rotate-user`` is handled by the
vault (``app/security/vault.py``): ``seal`` confirms ``dek_version`` in the database under the
user's lock before it uses a cached key, and ``open`` that meets a ciphertext one version ahead
of its cached key looks again once; anything else fails closed. So the cache TTL (5 minutes)
bounds how long a process may *hold* a retired key in memory, not whether it is ever *used*.

Nothing here logs or prints a key, a wrapped value, a key name or a response body: ids, counts,
versions and KMS error codes only.
"""

from __future__ import annotations

import secrets
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from typing import Final

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.audit import writer as audit
from app.audit.writer import AuditEvent
from app.auth.models import User
from app.checkins.models import CheckinConfiguration
from app.core.logging import get_logger
from app.engine.store import EngineStore
from app.instructions.models import Instruction
from app.ops.admin import _safe_operator
from app.ops.users import UserCommandError, clean_reason
from app.security import envelope
from app.security.kms import KmsError, KmsProvider
from app.security.models import UserKey

_log = get_logger("afterme.kms_admin")

BATCH: Final = 100
ABORT_AFTER_CONSECUTIVE_FAILURES: Final = 5
NIL_USER: Final = uuid.UUID(int=0)


class Outcome(StrEnum):
    REWRAPPED = "rewrapped"
    WOULD_REWRAP = "would_rewrap"
    CURRENT = "current"
    BUSY = "busy"
    CHANGED = "changed"
    FAILED = "failed"


@dataclass
class RewrapReport:
    dry_run: bool
    examined: int = 0
    rewrapped: int = 0
    would_rewrap: int = 0
    current: int = 0
    busy: int = 0
    changed: int = 0
    failed: int = 0
    failure_codes: dict[str, int] = field(default_factory=dict)
    aborted: bool = False  # the KMS failed repeatedly: stopped early, safe to rerun
    stopped_by_limit: bool = False

    @property
    def complete(self) -> bool:
        """Every key was looked at and none is left to a rerun."""
        return not (
            self.aborted or self.stopped_by_limit or self.busy or self.changed or self.failed
        )

    def as_dict(self) -> dict[str, object]:
        return {
            "dry_run": self.dry_run,
            "examined": self.examined,
            "rewrapped": self.rewrapped,
            "would_rewrap": self.would_rewrap,
            "already_current": self.current,
            "busy_retry_later": self.busy,
            "changed_concurrently_retry": self.changed,
            "failed": self.failed,
            "failure_codes": dict(sorted(self.failure_codes.items())),
            "aborted_kms_unavailable": self.aborted,
            "stopped_by_limit": self.stopped_by_limit,
            "complete": self.complete,
        }


@dataclass(frozen=True)
class Rotation:
    user_id: uuid.UUID
    from_version: int
    to_version: int
    instructions: int


@dataclass(frozen=True)
class _Row:
    user_id: uuid.UUID
    wrapped_dek: bytes
    kek_id: str
    dek_version: int


class KeyBusyError(UserCommandError):
    """The user's lock is held by a request or the engine; nothing was changed."""


class KeyChangedError(UserCommandError):
    """The key changed between reading it and locking it; nothing was changed."""


# ---------------------------------------------------------------------------------- helpers


async def _lock_user(session: AsyncSession, user_id: uuid.UUID) -> None:
    """The per-user lock, without waiting. :class:`KeyBusyError` when somebody holds it."""
    if await EngineStore.lock_user(session, user_id) is not None:
        return
    has_schedule = (
        await session.execute(
            select(CheckinConfiguration.user_id).where(CheckinConfiguration.user_id == user_id)
        )
    ).scalar_one_or_none() is not None
    if has_schedule:
        msg = "the account is busy (a request or the engine holds it); try again"
        raise KeyBusyError(msg)
    # No schedule, so no request can be creating or editing instructions for it: nothing to lock.


async def _locked_key(session: AsyncSession, seen: _Row) -> UserKey:
    """The key row under ``FOR UPDATE``, if it is still what was read (compare-and-swap)."""
    row = (
        await session.execute(
            select(UserKey)
            .where(UserKey.user_id == seen.user_id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    ).scalar_one_or_none()
    if (
        row is None
        or row.wrapped_dek != seen.wrapped_dek
        or row.kek_id != seen.kek_id
        or row.dek_version != seen.dek_version
    ):
        msg = "the key changed while it was being processed; run the command again"
        raise KeyChangedError(msg)
    return row


async def _read_key(services: AppServices, user_id: uuid.UUID) -> _Row | None:
    async with services.db.sessionmaker() as session, session.begin():
        row = (
            await session.execute(select(UserKey).where(UserKey.user_id == user_id))
        ).scalar_one_or_none()
        return (
            None
            if row is None
            else _Row(row.user_id, bytes(row.wrapped_dek), row.kek_id, row.dek_version)
        )


def _event(
    action: str, now: datetime, user_id: uuid.UUID, operator: str, **metadata: str | int
) -> AuditEvent:
    return AuditEvent(
        action=action,
        occurred_at=now,
        subject_user_id=user_id,
        actor_type="operator",
        resource_type="user_key",
        resource_id=user_id,
        metadata={"operator": operator[:40], **metadata},
        user_visible=False,
    )


# ---------------------------------------------------------------------------------- rewrap


async def _rewrap_one(
    services: AppServices, kms: KmsProvider, seen: _Row, *, operator: str, dry_run: bool
) -> tuple[Outcome, str]:
    """Returns ``(outcome, kms error code or "")``."""
    try:
        unwrapped = await kms.unwrap_status(
            seen.wrapped_dek, user_id=seen.user_id, key_id=seen.kek_id
        )
    except KmsError as exc:
        return Outcome.FAILED, exc.code
    if unwrapped.current:
        return Outcome.CURRENT, ""
    if dry_run:
        return Outcome.WOULD_REWRAP, ""
    try:
        wrapped, key_id = await kms.wrap(unwrapped.dek, user_id=seen.user_id)
    except KmsError as exc:
        return Outcome.FAILED, exc.code
    try:
        async with services.db.sessionmaker() as session, session.begin():
            now = await services.clock.now(session)
            await _lock_user(session, seen.user_id)
            row = await _locked_key(session, seen)
            row.wrapped_dek = wrapped
            row.kek_id = key_id
            await services.audit.record(
                session,
                _event(
                    audit.OPERATOR_KMS_REWRAP,
                    now,
                    seen.user_id,
                    operator,
                    dek_version=seen.dek_version,
                ),
            )
    except KeyBusyError:
        return Outcome.BUSY, ""
    except KeyChangedError:
        return Outcome.CHANGED, ""
    return Outcome.REWRAPPED, ""


async def rewrap(
    services: AppServices,
    *,
    operator: str,
    dry_run: bool = False,
    limit: int | None = None,
    batch: int = BATCH,
) -> RewrapReport:
    """Rewrite every wrapped DEK that is not under the KMS's current key, at most ``limit`` of
    them (``None``: all). Safe to interrupt and to run again; ``dry_run`` only reads (and asks
    the KMS to decrypt, which is how it learns whether a key is current)."""
    operator = _safe_operator(operator)
    kms = services.vault.kms
    report = RewrapReport(dry_run=dry_run)
    after = uuid.UUID(int=0)
    consecutive_failures = 0
    while True:
        async with services.db.sessionmaker() as session, session.begin():
            rows = [
                _Row(r.user_id, bytes(r.wrapped_dek), r.kek_id, r.dek_version)
                for r in (
                    await session.execute(
                        select(UserKey)
                        .where(UserKey.user_id > after)
                        .order_by(UserKey.user_id)
                        .limit(batch)
                    )
                ).scalars()
            ]
        if not rows:
            return report
        for seen in rows:
            after = seen.user_id
            if limit is not None and report.rewrapped + report.would_rewrap >= limit:
                report.stopped_by_limit = True
                return report
            outcome, code = await _rewrap_one(
                services, kms, seen, operator=operator, dry_run=dry_run
            )
            report.examined += 1
            match outcome:
                case Outcome.REWRAPPED:
                    report.rewrapped += 1
                case Outcome.WOULD_REWRAP:
                    report.would_rewrap += 1
                case Outcome.CURRENT:
                    report.current += 1
                case Outcome.BUSY:
                    report.busy += 1
                case Outcome.CHANGED:
                    report.changed += 1
                case Outcome.FAILED:
                    report.failed += 1
                    report.failure_codes[code] = report.failure_codes.get(code, 0) + 1
            consecutive_failures = consecutive_failures + 1 if outcome is Outcome.FAILED else 0
            if consecutive_failures >= ABORT_AFTER_CONSECUTIVE_FAILURES:
                report.aborted = True
                _log.error("kms.rewrap_aborted", examined=report.examined, failed=report.failed)
                return report


# ---------------------------------------------------------------------------------- rotate


async def rotate_user(
    services: AppServices, *, operator: str, user_id: uuid.UUID, reason: str
) -> Rotation:
    """A new DEK for one user. Every instruction they have is re-encrypted under it in the same
    transaction as the new wrapped key, or none is: a failure leaves the user exactly as they
    were. Raises :class:`UserCommandError` (refused, nothing changed)."""
    text = clean_reason(reason)
    operator = _safe_operator(operator)
    kms = services.vault.kms

    # 1. Outside any lock: who, which key, and the KMS work.
    async with services.db.sessionmaker() as session, session.begin():
        status = (
            await session.execute(select(User.status).where(User.id == user_id))
        ).scalar_one_or_none()
    if status is None:
        msg = "no such user"
        raise UserCommandError(msg)
    if status == "pending_deletion":
        msg = "the account is closed (pending deletion); nothing can be changed"
        raise UserCommandError(msg)
    seen = await _read_key(services, user_id)
    if seen is None:
        msg = "this account has no key (it has never stored an instruction); nothing to rotate"
        raise UserCommandError(msg)
    try:
        old_dek = await kms.unwrap(seen.wrapped_dek, user_id=user_id, key_id=seen.kek_id)
        new_dek = envelope.new_key()
        wrapped, key_id = await kms.wrap(new_dek, user_id=user_id)
    except KmsError as exc:
        msg = f"the KMS refused ({exc.code}); nothing was changed"
        raise UserCommandError(msg) from None

    # 2. One short transaction: the lock, the compare-and-swap, the re-encryption, the audit row.
    new_version = seen.dek_version + 1
    async with services.db.sessionmaker() as session, session.begin():
        now = await services.clock.now(session)
        await _lock_user(session, user_id)
        row = await _locked_key(session, seen)
        count = await _reencrypt(session, user_id, old_dek, new_dek, seen.dek_version, new_version)
        row.wrapped_dek = wrapped
        row.kek_id = key_id
        row.dek_version = new_version
        row.rotated_at = now
        await services.audit.record(
            session,
            _event(
                audit.OPERATOR_KMS_ROTATE_USER,
                now,
                user_id,
                operator,
                reason_length=len(text),
                from_version=seen.dek_version,
                to_version=new_version,
                instructions=count,
                **{audit.OPERATOR_TEXT_KEY: text},
            ),
        )
    services.vault.forget(user_id)  # this process: the others are bounded by the vault's checks
    _log.warning(
        "operator.kms_rotated_user",
        user_id=str(user_id),
        operator=operator,
        from_version=seen.dek_version,
        to_version=new_version,
        instructions=count,
    )
    return Rotation(user_id, seen.dek_version, new_version, count)


async def _reencrypt(
    session: AsyncSession,
    user_id: uuid.UUID,
    old_dek: bytes,
    new_dek: bytes,
    old_version: int,
    new_version: int,
) -> int:
    rows = (
        await session.execute(
            select(Instruction)
            .where(Instruction.user_id == user_id, Instruction.content_ciphertext.is_not(None))
            .order_by(Instruction.id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    ).scalars()
    count = 0
    for row in rows:
        blob = row.content_ciphertext
        if blob is None or row.content_key_version != old_version:
            msg = (
                f"instruction {row.id} is sealed under key version {row.content_key_version}, "
                f"not {old_version}; nothing was changed (investigate before rotating)"
            )
            raise UserCommandError(msg)
        try:
            plaintext = envelope.decrypt(
                old_dek, bytes(blob), aad=envelope.instruction_aad(user_id, row.id, old_version)
            )
        except envelope.DecryptionError:
            msg = f"instruction {row.id} cannot be opened with the current key; nothing was changed"
            raise UserCommandError(msg) from None
        row.content_ciphertext = envelope.encrypt(
            new_dek, plaintext, aad=envelope.instruction_aad(user_id, row.id, new_version)
        )
        row.content_key_version = new_version
        count += 1
    return count


# ---------------------------------------------------------------------------------- check


async def check(kms: KmsProvider) -> tuple[bool, str]:
    """The owner's one-line proof that the configured KMS works: wrap and unwrap 32 random
    bytes for the nil user, and prove that another user's identity is refused (the AAD is
    enforced). Returns ``(ok, what to print)``; nothing secret is in the text."""
    probe = secrets.token_bytes(envelope.KEY_BYTES)
    try:
        wrapped, key_id = await kms.wrap(probe, user_id=NIL_USER)
        unwrapped = await kms.unwrap_status(wrapped, user_id=NIL_USER, key_id=key_id)
    except KmsError as exc:
        return False, f"failed: code={exc.code}"
    if unwrapped.dek != probe:
        return False, "failed: code=roundtrip_mismatch"
    try:
        await kms.unwrap(wrapped, user_id=uuid.UUID(int=1), key_id=key_id)
    except KmsError:
        pass
    else:
        return False, "failed: code=aad_not_enforced"
    return True, f"ok: wrapped and unwrapped 32 random bytes; current_version={unwrapped.current}"
