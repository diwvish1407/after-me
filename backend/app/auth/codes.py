"""Emailed 6-digit verification codes (PRD FR-AUTH-03; SECURITY T17).

Codes come from the CSPRNG and are stored as ``HMAC(pepper, "code" | user_id | purpose | code)``.
They expire after 15 minutes and allow 5 attempts; issuing a new code invalidates earlier ones.
"""

from __future__ import annotations

import secrets
import uuid
from datetime import timedelta
from typing import Final

from app.security.hashing import Pepper

CODE_TTL: Final = timedelta(minutes=15)
CODE_MAX_ATTEMPTS: Final = 5
CODE_RESEND_INTERVAL: Final = timedelta(seconds=60)
_CODE_CONTEXT: Final = "auth_code"


def generate_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


def hash_code(pepper: Pepper, *, user_id: uuid.UUID, purpose: str, code: str) -> bytes:
    return pepper.hmac(_CODE_CONTEXT, str(user_id), purpose, code)


def code_matches(
    pepper: Pepper, stored_hash: bytes, *, user_id: uuid.UUID, purpose: str, code: str
) -> bool:
    """Constant-time comparison (current and previous pepper)."""
    return pepper.verify(stored_hash, _CODE_CONTEXT, str(user_id), purpose, code)
