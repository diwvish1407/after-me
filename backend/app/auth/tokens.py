"""Access tokens (EdDSA JWT) and opaque refresh tokens (SECURITY §6.3, §7; ADR-05).

* Access token: Ed25519-signed JWT with ``kid`` header; claims ``iss aud sub sid iat exp jti``.
  The algorithm allow-list is ``["EdDSA"]``. Several keys can be active for rotation.
* Expiry is compared against the :class:`~app.core.clock.Clock`, not the host clock: PyJWT's own
  ``exp``/``iat``/``nbf`` checks are disabled and done here explicitly. Signature, ``iss`` and
  ``aud`` are still verified by PyJWT, and every claim is required.
* Refresh token: ``rt_`` + 256 random bits, stored only as SHA-256.
"""

from __future__ import annotations

import secrets
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Final, TypeIs

import jwt
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)

from app.core.errors import TokenExpired, Unauthenticated
from app.security.hashing import sha256

ALGORITHM: Final = "EdDSA"
REQUIRED_CLAIMS: Final = ("exp", "iat", "sub", "sid", "iss", "aud", "jti")
IAT_LEEWAY_SECONDS: Final = 60
REFRESH_TOKEN_PREFIX: Final = "rt_"  # noqa: S105 - a public prefix, not a secret
_REFRESH_TOKEN_MAX_LENGTH: Final = 128


@dataclass(frozen=True)
class AccessClaims:
    user_id: uuid.UUID
    session_id: uuid.UUID
    issued_at: int
    expires_at: int
    jti: str


@dataclass(frozen=True)
class IssuedAccessToken:
    token: str
    expires_at: datetime


class AccessTokenService:
    def __init__(
        self,
        *,
        signing_keys: Mapping[str, Ed25519PrivateKey],
        active_kid: str,
        issuer: str,
        audience: str,
        ttl_seconds: int,
    ) -> None:
        if active_kid not in signing_keys:
            msg = "active kid has no signing key"
            raise ValueError(msg)
        self._signing_key = signing_keys[active_kid]
        self._active_kid = active_kid
        self._public_keys: dict[str, Ed25519PublicKey] = {
            kid: key.public_key() for kid, key in signing_keys.items()
        }
        self._issuer = issuer
        self._audience = audience
        self.ttl_seconds = ttl_seconds

    def issue(
        self, *, user_id: uuid.UUID, session_id: uuid.UUID, now: datetime
    ) -> IssuedAccessToken:
        issued_at = int(now.timestamp())
        expires_at = issued_at + self.ttl_seconds
        payload: dict[str, Any] = {
            "iss": self._issuer,
            "aud": self._audience,
            "sub": str(user_id),
            "sid": str(session_id),
            "iat": issued_at,
            "exp": expires_at,
            "jti": uuid.uuid4().hex,
        }
        token = jwt.encode(
            payload,
            self._signing_key,
            algorithm=ALGORITHM,
            headers={"kid": self._active_kid, "typ": "JWT"},
        )
        return IssuedAccessToken(token=token, expires_at=datetime.fromtimestamp(expires_at, UTC))

    def decode(self, token: str, *, now: datetime) -> AccessClaims:
        """Verify ``token``. Raises ``Unauthenticated`` or ``TokenExpired``."""
        try:
            header = jwt.get_unverified_header(token)
        except jwt.PyJWTError:
            raise Unauthenticated from None
        kid = header.get("kid")
        if header.get("alg") != ALGORITHM or not isinstance(kid, str):
            raise Unauthenticated
        public_key = self._public_keys.get(kid)
        if public_key is None:
            raise Unauthenticated
        try:
            claims = jwt.decode(
                token,
                public_key,
                algorithms=[ALGORITHM],
                audience=self._audience,
                issuer=self._issuer,
                options={
                    "verify_signature": True,
                    "verify_exp": False,  # checked below against the Clock
                    "verify_iat": False,
                    "verify_nbf": False,
                    "verify_aud": True,
                    "verify_iss": True,
                    "require": list(REQUIRED_CLAIMS),
                    "strict_aud": True,
                },
            )
        except jwt.PyJWTError:
            raise Unauthenticated from None

        exp, iat, jti = claims.get("exp"), claims.get("iat"), claims.get("jti")
        if not _is_int(exp) or not _is_int(iat) or not isinstance(jti, str):
            raise Unauthenticated
        try:
            user_id = uuid.UUID(str(claims["sub"]))
            session_id = uuid.UUID(str(claims["sid"]))
        except ValueError:
            raise Unauthenticated from None

        now_ts = now.timestamp()
        if iat > now_ts + IAT_LEEWAY_SECONDS:
            raise Unauthenticated
        if now_ts >= exp:
            raise TokenExpired
        return AccessClaims(
            user_id=user_id, session_id=session_id, issued_at=iat, expires_at=exp, jti=jti
        )


def _is_int(value: object) -> TypeIs[int]:
    return isinstance(value, int) and not isinstance(value, bool)


def new_refresh_token() -> str:
    return REFRESH_TOKEN_PREFIX + secrets.token_urlsafe(32)


def hash_refresh_token(token: str) -> bytes:
    return sha256(token)


def looks_like_refresh_token(token: str) -> bool:
    return token.startswith(REFRESH_TOKEN_PREFIX) and len(token) <= _REFRESH_TOKEN_MAX_LENGTH
