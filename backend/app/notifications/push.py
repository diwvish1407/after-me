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


@dataclass(frozen=True)
class PushMessage:
    token: str
    type: str  # the template key
    title: str
    body: str
    incident_id: str | None = None


class PushProvider(Protocol):
    name: str

    async def send(self, msg: PushMessage, *, idempotency_key: str) -> ProviderResult: ...


class LogOnlyPushProvider:
    """Development: nothing leaves the process; only the template type is logged (never the
    token). The FCM provider arrives with Phase 8."""

    name = "log"

    async def send(self, msg: PushMessage, *, idempotency_key: str) -> ProviderResult:
        _log.info("push.logged", type=msg.type)
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
