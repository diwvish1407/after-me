"""Postmark (https://postmarkapp.com): one HTTPS call per message on a transactional stream.

Postmark has no idempotency header; the outbox claims a row once and a crashed claim is
recovered at-least-once (ESCALATION_ENGINE §8.4), so in the rare crash window a contact can
receive the same message twice, which is the safe direction for an alert.
"""

from __future__ import annotations

import contextlib
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

URL: Final = "https://api.postmarkapp.com/email"
# The only ErrorCode that says "this recipient will never work": 406 (inactive recipient: a hard
# bounce or a spam complaint already put the address on Postmark's suppression list). Every other
# refusal is about our account, our sender signature or our request (400 sender signature not
# found, 401 not confirmed, 405 not allowed to send, 412 account blocked, 300 invalid request, ...)
# and must never be read as a verdict on the contact: it would suppress a good address.
_RECIPIENT_CODES: Final = frozenset({406})


class PostmarkEmailProvider:
    name = "postmark"

    def __init__(
        self,
        *,
        api_key: str,
        message_stream: str = "outbound",
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._api_key = api_key
        self._stream = message_stream
        self._client = client or new_client()

    async def send(self, msg: EmailMessage, *, idempotency_key: str) -> ProviderResult:
        body: dict[str, object] = {
            "From": msg.sender,
            "To": msg.to,
            "Subject": msg.subject,
            "TextBody": msg.text,
            "MessageStream": self._stream,
            "Tag": msg.template,
            "Metadata": {"notification_id": idempotency_key},
            "TrackOpens": False,
            "TrackLinks": "None",
            "Headers": [
                {"Name": "X-Entity-Ref-ID", "Value": idempotency_key},
                {"Name": "Auto-Submitted", "Value": "auto-generated"},
            ],
        }
        if msg.html is not None:
            body["HtmlBody"] = msg.html
        response = await post(
            self._client,
            URL,
            json=body,
            headers={
                "X-Postmark-Server-Token": self._api_key,
                "Accept": "application/json",
            },
        )
        if response.status_code == httpx.codes.OK:
            try:
                payload = response.json()
                if int(payload.get("ErrorCode", 0)) == 0:
                    return ProviderResult(provider=self.name, message_id=str(payload["MessageID"]))
            except (ValueError, KeyError, TypeError):
                raise TransientProviderError("postmark_unreadable") from None
        raise _classify(response)


def _classify(response: httpx.Response) -> ProviderError:
    status = response.status_code
    error_code = -1
    with contextlib.suppress(ValueError, AttributeError, TypeError):
        error_code = int(response.json().get("ErrorCode", -1))
    code = f"postmark_{error_code if error_code >= 0 else status}"[:48]
    if status == httpx.codes.TOO_MANY_REQUESTS or status >= httpx.codes.INTERNAL_SERVER_ERROR:
        return TransientProviderError(code, retry_after=retry_after(response))
    if error_code in _RECIPIENT_CODES:
        return PermanentDeliveryError(code)
    # Our configuration or request: the provider cannot be used for this message right now.
    # A fallback may; a person has to look at the status page.
    return ProviderUnavailableError(code)
