"""Opening instruction text for its owner (SECURITY §6.2).

Used where the owner is shown their own instructions outside the instruction screens: the
incident's releases, the Activity feed and the export. A text that cannot be opened (no key, a
ciphertext that fails authentication, a deleted instruction) is ``None``; the caller carries on
without it, so one bad row never hides the rest of a page.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterable

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.instructions.models import Instruction
from app.security.envelope import DecryptionError
from app.security.vault import InstructionVault, VaultUnavailableError


async def open_texts(
    session: AsyncSession,
    vault: InstructionVault,
    *,
    owner_id: uuid.UUID,
    instruction_ids: Iterable[uuid.UUID],
) -> dict[uuid.UUID, tuple[str, str] | None]:
    """``instruction id -> (title, body)``, or ``None`` when it cannot be opened. Ids that are not
    the owner's are absent."""
    wanted = set(instruction_ids)
    if not wanted:
        return {}
    rows = (
        await session.execute(
            select(Instruction).where(Instruction.user_id == owner_id, Instruction.id.in_(wanted))
        )
    ).scalars()
    opened: dict[uuid.UUID, tuple[str, str] | None] = {}
    for row in rows:
        if row.content_ciphertext is None:
            opened[row.id] = None
            continue
        try:
            opened[row.id] = await vault.open(
                session,
                user_id=owner_id,
                instruction_id=row.id,
                ciphertext=row.content_ciphertext,
                key_version=row.content_key_version,
            )
        except (DecryptionError, VaultUnavailableError):
            opened[row.id] = None
    return opened
