"""The Cloud KMS adapter (``KMS_PROVIDER=gcp_kms``; SECURITY §6.2, DEPLOYMENT §3).

Wraps and unwraps a user's data-encryption key (DEK) with a Cloud KMS CryptoKey, over the REST
API (``POST https://cloudkms.googleapis.com/v1/{name}:encrypt`` and ``:decrypt``). There is no
Google client library: the request is a JSON body over ``httpx`` and the credential is an OAuth
access token from the same two sources the FCM adapter uses (``providers/fcm.py``):

* the metadata server (Cloud Run, Workload Identity: no key anywhere), the production identity;
* ``KMS_CREDENTIALS_JSON``, a service-account key, for development and CI only. It works in any
  environment but is the non-preferred identity: a key file is a long-lived secret.

What the KMS is asked
---------------------
The DEK is the ``plaintext``. The additional authenticated data is
``envelope.dek_aad(user_id, key_id)``: exactly what ``LocalKms`` binds, so a wrapped DEK copied
to another account (or presented under another key id) fails to decrypt, here inside the KMS.
Both are sent with their CRC32C checksums, and the checksums in the answer are verified, as
Google recommends: a flipped bit between us and the KMS must not become a DEK that "works" and
encrypts a user's instructions under the wrong key.

The key id stored beside each wrapped DEK
-----------------------------------------
``gcp:<CryptoKey resource name>``, **not** a key *version* name. Cloud KMS records the version
inside the ciphertext and picks it on decrypt, so the stored id does not need it, and it must not
carry it: the id is part of the AAD, which must be reproduced exactly at unwrap time, whereas the
primary version changes every 90 days (automatic rotation) and is only known *after* a wrap. An
id with a version in it would either need an extra call (racing the rotation) or would fail to
decrypt after the very rotation it is meant to describe. What the id does tell us is *which key*
wrapped a DEK (a key moved to another CryptoKey is refused, not silently attempted). *Which
version* is answered on demand: a decrypt response says ``usedPrimary``, which is what
``cli.admin kms rewrap`` uses to find the DEKs still wrapped by an old version.

Failure behaviour (fail-safe, not fail-trigger)
-----------------------------------------------
Every call has a hard 3 s ceiling (token fetch included) and at most 2 retries, for timeouts,
network errors, ``429`` and ``5xx`` only. Everything ends in :class:`KmsError` carrying a short,
fixed, non-secret code; the key name, the response body, the DEK and the wrapped bytes never
reach an exception message or a log. After a call has failed all its attempts, calls fail
immediately for ``breaker_seconds`` rather than each waiting out 3 s: a KMS outage must not turn
into a pile of slow requests. Callers treat :class:`KmsError` as "this content is temporarily
unavailable" (``VaultUnavailableError``); check-ins, I'M SAFE, the engine and every page that
does not decrypt never call this module.

Every :class:`KmsError` that leaves ``wrap`` or ``unwrap_status`` (an HTTP error, a refused
checksum, an unreadable answer, a foreign key, the breaker's fast failure) is logged once as
``kms.call_failed`` with its code (:func:`app.security.kms.log_failure`): the KMS alert counts
those lines, and a failure that is not logged cannot page.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import time
import uuid
from collections.abc import Awaitable, Callable
from typing import Any, Final

import httpx

from app.core.config import KMS_KEY_NAME_RE, Settings
from app.notifications.errors import ProviderError
from app.notifications.providers.fcm import (
    AccessTokenSource,
    MetadataServerTokens,
    ServiceAccountTokens,
)
from app.security import envelope
from app.security.kms import KmsError, Unwrapped, log_failure

API_ROOT: Final = "https://cloudkms.googleapis.com/v1"
SCOPE: Final = "https://www.googleapis.com/auth/cloud-platform"
KEY_ID_PREFIX: Final = "gcp:"
CALL_TIMEOUT_SECONDS: Final = 3.0
MAX_RETRIES: Final = 2
RETRY_DELAYS: Final = (0.2, 0.5)
MAX_RETRY_AFTER: Final = 1.0
BREAKER_SECONDS: Final = 10.0

_HTTP_ERRORS: Final = {
    400: "invalid_argument",  # also: the AAD or the ciphertext does not match
    401: "unauthenticated",
    403: "permission_denied",
    404: "not_found",
}
_TOO_MANY_REQUESTS: Final = 429
_SERVER_ERROR: Final = 500

# --- CRC32C (Castagnoli), the checksum Cloud KMS uses ---------------------------------------


def _crc_table() -> tuple[int, ...]:
    table = []
    for byte in range(256):
        crc = byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0x82F63B78 if crc & 1 else crc >> 1
        table.append(crc)
    return tuple(table)


_TABLE: Final = _crc_table()


def crc32c(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc = _TABLE[(crc ^ byte) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFF


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def _unb64(value: object) -> bytes:
    if not isinstance(value, str):
        raise KmsError("bad_response")
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        raise KmsError("bad_response") from None


def _int64(value: object) -> int | None:
    """Proto3 JSON writes an int64 as a string; ``None`` when the field is absent."""
    if value is None:
        return None
    try:
        return int(str(value))
    except ValueError:
        raise KmsError("bad_response") from None


def key_id_for(key_name: str) -> str:
    return KEY_ID_PREFIX + key_name


class GcpKms:
    def __init__(
        self,
        key_name: str,
        tokens: AccessTokenSource,
        *,
        client: httpx.AsyncClient | None = None,
        timeout: float = CALL_TIMEOUT_SECONDS,
        max_retries: int = MAX_RETRIES,
        retry_delays: tuple[float, ...] = RETRY_DELAYS,
        breaker_seconds: float = BREAKER_SECONDS,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        if not KMS_KEY_NAME_RE.fullmatch(key_name):
            msg = "the KMS key name must be a CryptoKey resource name"
            raise ValueError(msg)
        self._key_name = key_name
        self._key_id = key_id_for(key_name)
        self._tokens = tokens
        self._client = client or httpx.AsyncClient(
            timeout=httpx.Timeout(timeout), follow_redirects=False
        )
        self._timeout = timeout
        self._max_retries = max_retries
        self._delays = retry_delays
        self._breaker_seconds = breaker_seconds
        self._sleep = sleep
        self._monotonic = monotonic
        self._open_until = 0.0

    @property
    def active_key_id(self) -> str:
        return self._key_id

    # ------------------------------------------------------------------ the KmsProvider API

    async def wrap(self, dek: bytes, *, user_id: uuid.UUID) -> tuple[bytes, str]:
        try:
            return await self._wrap(dek, user_id=user_id)
        except KmsError as exc:
            log_failure(exc, "encrypt")
            raise

    async def unwrap(self, wrapped: bytes, *, user_id: uuid.UUID, key_id: str) -> bytes:
        return (await self.unwrap_status(wrapped, user_id=user_id, key_id=key_id)).dek

    async def unwrap_status(self, wrapped: bytes, *, user_id: uuid.UUID, key_id: str) -> Unwrapped:
        try:
            return await self._unwrap_status(wrapped, user_id=user_id, key_id=key_id)
        except KmsError as exc:
            log_failure(exc, "decrypt")
            raise

    async def _wrap(self, dek: bytes, *, user_id: uuid.UUID) -> tuple[bytes, str]:
        aad = envelope.dek_aad(user_id, self._key_id)
        answer = await self._call(
            "encrypt",
            {
                "plaintext": _b64(dek),
                "additionalAuthenticatedData": _b64(aad),
                "plaintextCrc32c": str(crc32c(dek)),
                "additionalAuthenticatedDataCrc32c": str(crc32c(aad)),
            },
        )
        # Absent checksums are tolerated (an emulator); a checksum that is present must agree.
        if (
            answer.get("verifiedPlaintextCrc32c") is False
            or answer.get("verifiedAdditionalAuthenticatedDataCrc32c") is False
        ):
            raise KmsError("integrity")
        ciphertext = _unb64(answer.get("ciphertext"))
        reported = _int64(answer.get("ciphertextCrc32c"))
        if not ciphertext or (reported is not None and reported != crc32c(ciphertext)):
            raise KmsError("integrity")
        name = answer.get("name")
        if isinstance(name, str) and not name.startswith(self._key_name + "/cryptoKeyVersions/"):
            raise KmsError("key_mismatch")
        return ciphertext, self._key_id

    async def _unwrap_status(self, wrapped: bytes, *, user_id: uuid.UUID, key_id: str) -> Unwrapped:
        if key_id != self._key_id:
            # Wrapped by another key than the one this process is configured with: never
            # attempted (the database does not get to choose which key we call).
            raise KmsError("unknown_key")
        aad = envelope.dek_aad(user_id, key_id)
        answer = await self._call(
            "decrypt",
            {
                "ciphertext": _b64(wrapped),
                "additionalAuthenticatedData": _b64(aad),
                "ciphertextCrc32c": str(crc32c(wrapped)),
                "additionalAuthenticatedDataCrc32c": str(crc32c(aad)),
            },
        )
        dek = _unb64(answer.get("plaintext"))
        reported = _int64(answer.get("plaintextCrc32c"))
        if len(dek) != envelope.KEY_BYTES or (reported is not None and reported != crc32c(dek)):
            raise KmsError("integrity")
        return Unwrapped(dek, current=answer.get("usedPrimary") is True)

    # ------------------------------------------------------------------ the HTTP call

    async def _call(self, operation: str, body: dict[str, str]) -> dict[str, Any]:
        if self._monotonic() < self._open_until:
            raise KmsError("recently_unavailable")
        code = "unavailable"
        refreshed = False
        for attempt in range(self._max_retries + 1):
            delay = self._delays[min(attempt, len(self._delays) - 1)] if self._delays else 0.0
            try:
                async with asyncio.timeout(self._timeout):
                    response = await self._send(operation, body, force_token=False)
                    if response.status_code == httpx.codes.UNAUTHORIZED and not refreshed:
                        refreshed = True  # the cached token may simply have expired
                        response = await self._send(operation, body, force_token=True)
            except (TimeoutError, httpx.TimeoutException):
                code = "timeout"
            except ProviderError:
                code = "token_unavailable"
            except httpx.HTTPError:
                code = "network"
            else:
                status = response.status_code
                if status == httpx.codes.OK:
                    return self._json(response)
                if status == _TOO_MANY_REQUESTS or status >= _SERVER_ERROR:
                    code = "rate_limited" if status == _TOO_MANY_REQUESTS else "unavailable"
                    delay = max(delay, self._retry_after(response))
                else:
                    raise self._failed(operation, _HTTP_ERRORS.get(status, f"http_{status}"))
            if attempt < self._max_retries:
                await self._sleep(delay)
        self._open_until = self._monotonic() + self._breaker_seconds
        raise self._failed(operation, code)

    async def _send(self, operation: str, body: dict[str, str], *, force_token: bool) -> Any:
        token = await self._tokens.token(force=force_token)
        return await self._client.post(
            f"{API_ROOT}/{self._key_name}:{operation}",
            json=body,
            headers={"Authorization": f"Bearer {token}"},
        )

    @staticmethod
    def _json(response: httpx.Response) -> dict[str, Any]:
        try:
            answer = response.json()
        except ValueError:
            raise KmsError("bad_response") from None
        if not isinstance(answer, dict):
            raise KmsError("bad_response")
        return answer

    @staticmethod
    def _retry_after(response: httpx.Response) -> float:
        try:
            return min(max(float(response.headers.get("retry-after", 0)), 0.0), MAX_RETRY_AFTER)
        except ValueError:
            return 0.0

    @staticmethod
    def _failed(operation: str, code: str) -> KmsError:
        # The operation and the code, nothing else: no key name, no body, no bytes.
        return log_failure(KmsError(code), operation)


def load_credentials(raw: str) -> dict[str, Any]:
    """Parse ``KMS_CREDENTIALS_JSON``; the error never echoes the value."""
    try:
        info = json.loads(raw)
    except ValueError:
        msg = "KMS_CREDENTIALS_JSON is not valid JSON"
        raise ValueError(msg) from None
    if not isinstance(info, dict):
        msg = "KMS_CREDENTIALS_JSON must be a JSON object"
        raise ValueError(msg)
    return info


def build_gcp_kms(settings: Settings, *, client: httpx.AsyncClient | None = None) -> GcpKms:
    """The configured Cloud KMS adapter. Its HTTP client has the 3 s ceiling; the identity is
    the key in ``KMS_CREDENTIALS_JSON`` when given, otherwise the metadata server's."""
    if not settings.kms_key_name:  # pragma: no cover - Settings already refuses this
        msg = "KMS_KEY_NAME is required"
        raise ValueError(msg)
    http = client or httpx.AsyncClient(
        timeout=httpx.Timeout(CALL_TIMEOUT_SECONDS), follow_redirects=False
    )
    tokens: AccessTokenSource
    if settings.kms_credentials_json is not None:
        info = load_credentials(settings.kms_credentials_json.get_secret_value())
        tokens = ServiceAccountTokens(info, http, scope=SCOPE)
    else:
        tokens = MetadataServerTokens(http)
    return GcpKms(settings.kms_key_name, tokens, client=http)
