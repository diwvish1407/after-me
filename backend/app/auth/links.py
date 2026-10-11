"""Emailed one-time links (SECURITY §6.3, §12; API_SPEC §2.4).

A password-reset link carries ``pr_`` + 256 bits of CSPRNG output in the URL *fragment*, so the
token never reaches a server, proxy or load-balancer log. Only its SHA-256 is stored.
"""

from __future__ import annotations

import re
import secrets
from datetime import timedelta
from typing import Final

from app.security.hashing import sha256

RESET_TOKEN_PREFIX: Final = "pr_"  # noqa: S105
RESET_LINK_TTL: Final = timedelta(minutes=30)
RESET_PURPOSE: Final = "password_reset"

# token_urlsafe(32) is 43 characters of [A-Za-z0-9_-].
_RESET_TOKEN_RE: Final = re.compile(r"^pr_[A-Za-z0-9_-]{43}$")


def new_reset_token() -> str:
    return RESET_TOKEN_PREFIX + secrets.token_urlsafe(32)


def hash_link_token(token: str) -> bytes:
    return sha256(token)


def looks_like_reset_token(token: str) -> bool:
    """Cheap shape check before touching the database; no secret comparison happens here."""
    return _RESET_TOKEN_RE.fullmatch(token) is not None


def reset_link(public_base_url: str, token: str) -> str:
    return f"{public_base_url}/a/reset#{token}"


# Account deletion from the web (Play Store requirement): the same shape as a reset link, with
# its own prefix and purpose so one kind of link can never be used as the other.
DELETE_TOKEN_PREFIX: Final = "ad_"  # noqa: S105
DELETE_LINK_TTL: Final = timedelta(minutes=30)
DELETE_PURPOSE: Final = "account_delete_web"
_DELETE_TOKEN_RE: Final = re.compile(r"^ad_[A-Za-z0-9_-]{43}$")


def new_delete_token() -> str:
    return DELETE_TOKEN_PREFIX + secrets.token_urlsafe(32)


def looks_like_delete_token(token: str) -> bool:
    return _DELETE_TOKEN_RE.fullmatch(token) is not None


def delete_link(public_base_url: str, token: str) -> str:
    return f"{public_base_url}/a/delete/confirm#{token}"
