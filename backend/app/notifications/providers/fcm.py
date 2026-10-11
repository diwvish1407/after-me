"""Firebase Cloud Messaging, HTTP v1 (ARCHITECTURE §4.7, §5.7; DEPLOYMENT §4).

Authentication is OAuth2 with a service account, from one of two places:

* ``FCM_CREDENTIALS_JSON``: the service-account key (development and staging). The adapter
  signs a short-lived JWT with it and exchanges it for an access token.
* the metadata server (production on Google Cloud, Workload Identity): no key file at all.

A push carries a type, an incident id and **generic** text: nothing that names a person or a
time, nothing from an instruction (FR-NOT-04). ``visibility: PRIVATE`` keeps even that off a
locked screen on phones that hide sensitive content.
"""

from __future__ import annotations

import asyncio
import json
import time
from collections.abc import Callable
from typing import Any, Final, Protocol

import httpx
import jwt

from app.core.logging import get_logger
from app.notifications.email import ProviderResult
from app.notifications.errors import (
    InvalidPushTokenError,
    PermanentDeliveryError,
    ProviderUnavailableError,
    TransientProviderError,
)
from app.notifications.providers.http import new_client, post, retry_after
from app.notifications.push import PAYLOAD_VERSION, PushMessage

_log = get_logger("afterme.fcm")

SCOPE: Final = "https://www.googleapis.com/auth/firebase.messaging"
DEFAULT_TOKEN_URI: Final = "https://oauth2.googleapis.com/token"  # noqa: S105
_METADATA: Final = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts"
METADATA_URL: Final = f"{_METADATA}/default/token"
SEND_URL: Final = "https://fcm.googleapis.com/v1/projects/{project}/messages:send"
_REFRESH_MARGIN: Final = 300.0
# Only FCM's explicit "this registration is gone". A plain 404 NOT_FOUND is what a wrong project
# id answers for *every* send, and SENDER_ID_MISMATCH is what a configuration pointing at another
# project answers for every token: neither may be read as "forget this phone".
_TOKEN_ERRORS: Final = frozenset({"UNREGISTERED"})
_TRANSIENT: Final = frozenset({"QUOTA_EXCEEDED", "UNAVAILABLE", "INTERNAL"})
_UNAVAILABLE: Final = frozenset({"UNAUTHENTICATED", "PERMISSION_DENIED", "THIRD_PARTY_AUTH_ERROR"})


class AccessTokenSource(Protocol):
    async def token(self, *, force: bool = False) -> str: ...


class _Cached:
    """An access token and when to fetch the next one; one fetch at a time."""

    def __init__(self, clock: Callable[[], float]) -> None:
        self._clock = clock
        self._token: str | None = None
        self._expires_at = 0.0
        self._lock = asyncio.Lock()

    async def get(self, fetch: Callable[[], Any], *, force: bool) -> str:
        async with self._lock:
            if force or self._token is None or self._clock() >= self._expires_at - _REFRESH_MARGIN:
                token, lifetime = await fetch()
                self._token = token
                self._expires_at = self._clock() + lifetime
            assert self._token is not None  # noqa: S101
            return self._token


class ServiceAccountTokens:
    """OAuth2 JWT-bearer flow for a service-account key."""

    def __init__(
        self,
        info: dict[str, Any],
        client: httpx.AsyncClient,
        *,
        clock: Callable[[], float] = time.time,
    ) -> None:
        for key in ("client_email", "private_key"):
            if not isinstance(info.get(key), str) or not info[key]:
                msg = f"the service-account key has no {key}"
                raise ValueError(msg)
        self._email: str = info["client_email"]
        self._key: str = info["private_key"]
        self._uri: str = str(info.get("token_uri") or DEFAULT_TOKEN_URI)
        self._client = client
        self._clock = clock
        self._cache = _Cached(clock)

    async def token(self, *, force: bool = False) -> str:
        return await self._cache.get(self._fetch, force=force)

    async def _fetch(self) -> tuple[str, float]:
        now = int(self._clock())
        assertion = jwt.encode(
            {"iss": self._email, "scope": SCOPE, "aud": self._uri, "iat": now, "exp": now + 3600},
            self._key,
            algorithm="RS256",
        )
        response = await post(
            self._client,
            self._uri,
            data={
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": assertion,
            },
        )
        return _read_token(response)


class MetadataServerTokens:
    """Google Cloud's metadata server (Workload Identity): no key to hold."""

    def __init__(
        self, client: httpx.AsyncClient, *, clock: Callable[[], float] = time.time
    ) -> None:
        self._client = client
        self._cache = _Cached(clock)

    async def token(self, *, force: bool = False) -> str:
        return await self._cache.get(self._fetch, force=force)

    async def _fetch(self) -> tuple[str, float]:
        try:
            response = await self._client.get(METADATA_URL, headers={"Metadata-Flavor": "Google"})
        except httpx.HTTPError:
            raise ProviderUnavailableError("fcm_metadata_unreachable") from None
        return _read_token(response)


def _read_token(response: httpx.Response) -> tuple[str, float]:
    if response.status_code != httpx.codes.OK:
        # Bad credentials do not heal by themselves: the whole provider is unusable.
        raise ProviderUnavailableError(f"fcm_token_{response.status_code}")
    try:
        body = response.json()
        return str(body["access_token"]), float(body.get("expires_in", 3000))
    except (ValueError, KeyError, TypeError):
        raise ProviderUnavailableError("fcm_token_unreadable") from None


def fcm_payload(msg: PushMessage) -> dict[str, Any]:
    """The ``message`` object sent to FCM, without the token (used by the golden fixture)."""
    data = {"type": msg.type, "v": PAYLOAD_VERSION}
    if msg.incident_id is not None:
        data["incident_id"] = msg.incident_id
    return {
        "notification": {"title": msg.title, "body": msg.body},
        "data": data,
        "android": {
            "priority": "HIGH",
            "ttl": f"{msg.ttl_seconds}s",
            "notification": {
                "channel_id": msg.channel,
                "tag": msg.type,
                "visibility": "PRIVATE",
                "notification_priority": "PRIORITY_HIGH",
            },
        },
    }


class FcmPushProvider:
    name = "fcm"

    def __init__(
        self,
        *,
        project_id: str,
        tokens: AccessTokenSource,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._url = SEND_URL.format(project=project_id)
        self._tokens = tokens
        self._client = client or new_client()

    async def send(self, msg: PushMessage, *, idempotency_key: str) -> ProviderResult:
        # FCM has no idempotency key; a duplicate is prevented upstream (the outbox row is
        # claimed once) and a repeated push replaces itself through its ``tag``.
        body = {"message": {"token": msg.token, **fcm_payload(msg)}}
        response = await self._post(body, force_token=False)
        if response.status_code == httpx.codes.UNAUTHORIZED:
            response = await self._post(body, force_token=True)
        if response.status_code == httpx.codes.OK:
            return ProviderResult(provider=self.name, message_id=_message_id(response))
        raise _classify(response)

    async def _post(self, body: dict[str, Any], *, force_token: bool) -> httpx.Response:
        access = await self._tokens.token(force=force_token)
        return await post(
            self._client,
            self._url,
            json=body,
            headers={"Authorization": f"Bearer {access}"},
        )


def _message_id(response: httpx.Response) -> str:
    try:
        return str(response.json().get("name", "")).rsplit("/", 1)[-1] or "fcm"
    except (ValueError, AttributeError):
        return "fcm"


def _error_code(response: httpx.Response) -> tuple[str, str]:
    """``(FCM error code or status, human message)``; both empty when the body is not JSON."""
    try:
        error = response.json().get("error", {})
        code = ""
        for detail in error.get("details", []) or []:
            if isinstance(detail, dict) and detail.get("errorCode"):
                code = str(detail["errorCode"])
                break
        return code or str(error.get("status", "")), str(error.get("message", ""))
    except (ValueError, AttributeError, TypeError):
        return "", ""


def _classify(response: httpx.Response) -> Exception:
    code, message = _error_code(response)
    status = response.status_code
    if code in _TOKEN_ERRORS:
        return InvalidPushTokenError("unregistered")
    if status == httpx.codes.NOT_FOUND or code in ("NOT_FOUND", "SENDER_ID_MISMATCH"):
        # The project, the URL or the sender is wrong: the whole provider is unusable until a
        # person fixes the configuration, and no token should be touched.
        return ProviderUnavailableError(f"fcm_{(code or '404').lower()}"[:48])
    if code == "INVALID_ARGUMENT":
        # "The registration token is not a valid FCM registration token" is the token's fault;
        # anything else is our payload's, which no retry will fix.
        if "registration token" in message.lower():
            return InvalidPushTokenError("invalid_token")
        return PermanentDeliveryError("invalid_argument")
    if code in _UNAVAILABLE or status in (httpx.codes.UNAUTHORIZED, httpx.codes.FORBIDDEN):
        return ProviderUnavailableError(f"fcm_{(code or str(status)).lower()}"[:48])
    # Anything not explicitly final is retried: "we do not recognise this answer" must never
    # silently end a message.
    return TransientProviderError(
        f"fcm_{(code or str(status)).lower()}"[:48], retry_after=retry_after(response)
    )


def load_service_account(raw: str) -> dict[str, Any]:
    """Parse ``FCM_CREDENTIALS_JSON``; the error never echoes the value."""
    try:
        info = json.loads(raw)
    except ValueError:
        msg = "FCM_CREDENTIALS_JSON is not valid JSON"
        raise ValueError(msg) from None
    if not isinstance(info, dict):
        msg = "FCM_CREDENTIALS_JSON must be a JSON object"
        raise ValueError(msg)
    return info
