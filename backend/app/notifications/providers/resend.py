"""Resend (https://resend.com): one HTTPS call per message, with a native ``Idempotency-Key``.

The notification id is the idempotency key, so a retry after a lost answer is the *same*
message to Resend, not a second email to the contact.
"""

from __future__ import annotations

import contextlib
import hashlib
from typing import Final

import httpx

from app.notifications.email import EmailMessage, ProviderResult
from app.notifications.errors import (
    PermanentDeliveryError,
    ProviderError,
    ProviderUnavailableError,
    TransientProviderError,
)
from app.notifications.providers.http import new_client, post, retry_after

URL: Final = "https://api.resend.com/emails"
# The only error name that is about the recipient rather than about us.
_BAD_RECIPIENT: Final = "invalid_to_address"


def _body_digest(msg: EmailMessage) -> str:
    material = "\x1f".join((msg.to, msg.subject, msg.text, msg.html or ""))
    return hashlib.sha256(material.encode()).hexdigest()[:16]


class ResendEmailProvider:
    name = "resend"

    def __init__(self, *, api_key: str, client: httpx.AsyncClient | None = None) -> None:
        self._api_key = api_key
        self._client = client or new_client()

    async def send(self, msg: EmailMessage, *, idempotency_key: str) -> ProviderResult:
        body: dict[str, object] = {
            "from": msg.sender,
            "to": [msg.to],
            "subject": msg.subject,
            "text": msg.text,
            "headers": {"X-Entity-Ref-ID": idempotency_key, "Auto-Submitted": "auto-generated"},
            "tags": [
                {"name": "template", "value": msg.template},
                # echoed in every webhook event: an event can find its message even if it
                # arrives before the dispatcher has written the provider's message id
                {"name": "notification_id", "value": idempotency_key[:64]},
            ],
        }
        if msg.html is not None:
            body["html"] = msg.html
        response = await post(
            self._client,
            URL,
            json=body,
            headers={
                "Authorization": f"Bearer {self._api_key}",
                # The same message again is the same key (a retry after a lost answer is not a
                # second email); a message whose body changed since (a fresh portal link) is a
                # new key, because Resend refuses one key with two bodies for 24 hours.
                "Idempotency-Key": f"{idempotency_key}-{_body_digest(msg)}"[:256],
            },
        )
        if response.status_code == httpx.codes.OK:
            try:
                return ProviderResult(provider=self.name, message_id=str(response.json()["id"]))
            except (ValueError, KeyError, TypeError):
                raise TransientProviderError("resend_unreadable") from None
        raise _classify(response)


def _classify(response: httpx.Response) -> ProviderError:
    status = response.status_code
    name = ""
    with contextlib.suppress(ValueError, AttributeError):
        name = str(response.json().get("name", ""))
    code = f"resend_{name or status}"[:48]
    if status == httpx.codes.TOO_MANY_REQUESTS or status >= httpx.codes.INTERNAL_SERVER_ERROR:
        return TransientProviderError(code, retry_after=retry_after(response))
    if (
        status == httpx.codes.CONFLICT
    ):  # the same idempotency key is in flight: the answer will come
        return TransientProviderError(code, retry_after=retry_after(response))
    if name == _BAD_RECIPIENT:
        return PermanentDeliveryError(code)  # this address will never work
    # An API key that is missing or restricted, a sending domain that is not verified, a sender
    # address that is invalid, a malformed request: all ours. Never a verdict on the contact.
    return ProviderUnavailableError(code)
