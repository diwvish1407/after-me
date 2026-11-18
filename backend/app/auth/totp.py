"""Time-based one-time passwords (RFC 6238, HMAC-SHA1, 6 digits, 30 s) and recovery codes.

Pure functions; no I/O. The secret is generated here and stored wrapped by the KMS
(``users.totp_secret_wrapped``). A code is accepted for the current step and one step either
side (clock drift), and never twice: the caller stores the accepted step and refuses any step
that is not newer.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
import struct
from datetime import datetime
from typing import Final
from urllib.parse import quote, urlencode

STEP_SECONDS: Final = 30
DIGITS: Final = 6
DRIFT_STEPS: Final = 1
SECRET_BYTES: Final = 20
RECOVERY_CODE_COUNT: Final = 8
ISSUER: Final = "AfterMe"
# The HMAC context of stored recovery-code digests (app/security/hashing.py ``Pepper``).
RECOVERY_CONTEXT: Final = "totp_recovery"


def new_secret() -> bytes:
    return secrets.token_bytes(SECRET_BYTES)


def b32(secret: bytes) -> str:
    """The secret as authenticator apps expect it (base32, no padding)."""
    return base64.b32encode(secret).decode("ascii").rstrip("=")


def otpauth_uri(secret: bytes, account: str) -> str:
    label = quote(f"{ISSUER}:{account}")
    query = urlencode(
        {"secret": b32(secret), "issuer": ISSUER, "digits": DIGITS, "period": STEP_SECONDS}
    )
    return f"otpauth://totp/{label}?{query}"


def step_of(now: datetime) -> int:
    return int(now.timestamp()) // STEP_SECONDS


def code_at(secret: bytes, step: int) -> str:
    digest = hmac.new(secret, struct.pack(">Q", step), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF
    return str(value % (10**DIGITS)).zfill(DIGITS)


def _normalise(code: str) -> str:
    return "".join(ch for ch in code if ch.isdigit())


def matching_step(
    secret: bytes, code: str, now: datetime, *, after_step: int | None = None
) -> int | None:
    """The step a six-digit ``code`` belongs to (now ± drift), or ``None``. A step at or before
    ``after_step`` (already used) never matches."""
    digits = _normalise(code)
    if len(digits) != DIGITS:
        return None
    current = step_of(now)
    for step in range(current - DRIFT_STEPS, current + DRIFT_STEPS + 1):
        if after_step is not None and step <= after_step:
            continue
        if hmac.compare_digest(code_at(secret, step), digits):
            return step
    return None


def new_recovery_codes() -> list[str]:
    """Eight one-use codes such as ``7K3Q-9XMD`` (shown once)."""
    alphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
    codes = []
    for _ in range(RECOVERY_CODE_COUNT):
        raw = "".join(secrets.choice(alphabet) for _ in range(8))
        codes.append(f"{raw[:4]}-{raw[4:]}")
    return codes


def normal_recovery(code: str) -> str:
    return "".join(ch for ch in code.upper() if ch.isalnum())


def looks_like_recovery_code(code: str) -> bool:
    normal = normal_recovery(code)
    return len(normal) == 8 and not normal.isdigit()  # noqa: PLR2004
