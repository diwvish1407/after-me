"""Push provider interface and the development/test providers (ARCHITECTURE §4.7, §5.7).

A push payload carries a type, an optional incident ID and **generic** text only: no names, no
times, no content (FR-NOT-04; SECURITY T21). The app fetches the details over the API and shows
nothing it was not told by the server.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol

from app.core.logging import get_logger
from app.notifications.email import ProviderResult

_log = get_logger("afterme.push")


# The Android notification channels the app creates (ARCHITECTURE §5.7). A message names its
# channel so the person can silence reminders without silencing alerts.
CHANNEL_REMINDERS = "reminders"
CHANNEL_INCIDENTS = "incidents"
CHANNEL_ACCOUNT = "account"
PAYLOAD_VERSION = "1"


@dataclass(frozen=True)
class PushMessage:
    token: str = field(repr=False)
    type: str  # the template key
    title: str
    body: str
    incident_id: str | None = None
    channel: str = CHANNEL_INCIDENTS
    # How long the push is still worth showing if the phone is off: a reminder an hour late is
    # noise, a "your contacts were notified" is still true tomorrow.
    ttl_seconds: int = 86_400


class PushProvider(Protocol):
    name: str

    async def send(self, msg: PushMessage, *, idempotency_key: str) -> ProviderResult: ...


class LogOnlyPushProvider:
    """Development: nothing leaves the process; only the template type is logged (never the
    token). Real pushes need ``PUSH_PROVIDER=fcm`` (``providers/fcm.py``)."""

    name = "log"

    async def send(self, msg: PushMessage, *, idempotency_key: str) -> ProviderResult:
        _log.info("push.logged", type=msg.type)
        return ProviderResult(provider=self.name, message_id=idempotency_key)


class NoopPushProvider:
    """Tests that do not care about push: accepts every message and keeps nothing."""

    name = "noop"

    async def send(self, msg: PushMessage, *, idempotency_key: str) -> ProviderResult:
        return ProviderResult(provider=self.name, message_id=idempotency_key)


@dataclass
class RecordingPushProvider:
    """Tests: keeps every message in memory."""

    name: str = "recording"
    messages: list[PushMessage] = field(default_factory=list)
    fail_next: int = 0

    async def send(self, msg: PushMessage, *, idempotency_key: str) -> ProviderResult:
        if self.fail_next > 0:
            self.fail_next -= 1
            error = "simulated push failure"
            raise ConnectionError(error)
        self.messages.append(msg)
        return ProviderResult(provider=self.name, message_id=idempotency_key)

    def of_type(self, template: str) -> list[PushMessage]:
        return [m for m in self.messages if m.type == template]
