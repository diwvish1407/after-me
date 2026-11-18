"""Verifying Google ID tokens (Sign in with Google).

The token's RS256 signature is checked against Google's published keys (fetched over HTTPS and
cached for an hour), then the issuer, the audience (one of ``google_client_ids``), the expiry and
``email_verified``. Nothing from an unverified token is ever used.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, Final

import httpx
import jwt

JWKS_URL: Final = "https://www.googleapis.com/oauth2/v3/certs"
ISSUERS: Final = ("accounts.google.com", "https://accounts.google.com")
_CACHE_SECONDS: Final = 3600


class GoogleTokenError(Exception):
    pass


@dataclass(frozen=True, slots=True)
class GoogleIdentity:
    sub: str
    email: str
    name: str | None


class GoogleVerifier:
    def __init__(self, client_ids: list[str], *, jwks: dict[str, Any] | None = None) -> None:
        self._client_ids = [c for c in client_ids if c]
        self._jwks = jwks
        self._fetched = time.monotonic() if jwks is not None else 0.0
        self._fixed = jwks is not None  # tests pass the keys in

    @property
    def enabled(self) -> bool:
        return bool(self._client_ids)

    async def _keys(self) -> dict[str, Any]:
        stale = time.monotonic() - self._fetched > _CACHE_SECONDS
        if self._jwks is None or (stale and not self._fixed):
            async with httpx.AsyncClient(timeout=5.0) as client:
                response = await client.get(JWKS_URL)
                response.raise_for_status()
                self._jwks = response.json()
                self._fetched = time.monotonic()
        return self._jwks or {}

    async def verify(self, token: str) -> GoogleIdentity:
        if not self.enabled:
            raise GoogleTokenError("not_configured")
        try:
            kid = jwt.get_unverified_header(token).get("kid")
            keys = (await self._keys()).get("keys", [])
            match = next((k for k in keys if k.get("kid") == kid), None)
            if match is None:
                raise GoogleTokenError("unknown_key")
            key = jwt.PyJWK(match).key
            claims = jwt.decode(
                token,
                key=key,
                algorithms=["RS256"],
                audience=self._client_ids,
                options={"require": ["exp", "iat", "iss", "aud", "sub"]},
                leeway=30,
            )
        except GoogleTokenError:
            raise
        except (jwt.PyJWTError, httpx.HTTPError, ValueError, KeyError) as exc:
            raise GoogleTokenError("invalid") from exc
        if claims.get("iss") not in ISSUERS:
            raise GoogleTokenError("issuer")
        email = claims.get("email")
        if not isinstance(email, str) or claims.get("email_verified") is not True:
            raise GoogleTokenError("email_unverified")
        name = claims.get("name")
        return GoogleIdentity(
            sub=str(claims["sub"]), email=email, name=name if isinstance(name, str) else None
        )
