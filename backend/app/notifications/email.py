"""Email provider interface and the development/test providers (ARCHITECTURE §4.7).

Phase 1 sends transactional email directly after the request transaction commits. Phase 8 moves
all sending to the outbox and dispatcher; the provider interface stays the same.
"""

from __future__ import annotations

import asyncio
import os
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Protocol

from app.core.logging import get_logger

_log = get_logger("afterme.email")


@dataclass(frozen=True)
class EmailMessage:
    # ``to``, ``text`` and ``html`` are kept out of ``repr``: an address and a message body
    # (which can hold a code or a link) must not reach a log line through a stray ``{msg!r}``.
    to: str = field(repr=False)
    subject: str
    text: str = field(repr=False)
    template: str
    sender: str
    # The same copy as ``text``, for mail clients that show HTML (generated from it; never
    # different words). ``None`` for providers and tests that only want text.
    html: str | None = field(default=None, repr=False)
    # Who this message is about, so that a bounce or complaint reported later by the provider
    # can be tied to the contact (see ``app.notifications.receipts``). Never sent to a provider.
    contact_id: uuid.UUID | None = field(default=None, repr=False)
    owner_id: uuid.UUID | None = field(default=None, repr=False)


@dataclass(frozen=True)
class ProviderResult:
    provider: str
    message_id: str


class EmailProvider(Protocol):
    name: str

    async def send(self, msg: EmailMessage, *, idempotency_key: str) -> ProviderResult: ...


class ConsoleEmailProvider:
    """Development only: writes each message to a file under ``backend/.dev_mail/``.

    Only the file path is logged; the address and the contents (which may hold a code) are not.
    Configuration refuses this provider in staging and production.
    """

    name = "console"

    def __init__(self, directory: Path) -> None:
        self._directory = directory

    def _write(self, msg: EmailMessage, idempotency_key: str) -> Path:
        self._directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
        path = self._directory / f"{stamp}.{msg.template}.{idempotency_key[:12]}.txt"
        content = (
            f"From: {msg.sender}\nTo: {msg.to}\nSubject: {msg.subject}\n"
            f"X-Template: {msg.template}\n\n{msg.text}"
        )
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        return path

    async def send(self, msg: EmailMessage, *, idempotency_key: str) -> ProviderResult:
        path = await asyncio.to_thread(self._write, msg, idempotency_key)
        _log.info("email.written_to_file", template=msg.template, path=str(path))
        return ProviderResult(provider=self.name, message_id=path.name)


@dataclass
class RecordingEmailProvider:
    """Tests: keeps every message in memory."""

    name: str = "recording"
    messages: list[EmailMessage] = field(default_factory=list)
    keys: list[str] = field(default_factory=list)  # the idempotency key of each accepted send
    fail_next: bool = False

    async def send(self, msg: EmailMessage, *, idempotency_key: str) -> ProviderResult:
        if self.fail_next:
            self.fail_next = False
            msg_text = "simulated provider failure"
            raise ConnectionError(msg_text)
        self.messages.append(msg)
        self.keys.append(idempotency_key)
        return ProviderResult(provider=self.name, message_id=idempotency_key)

    def to(self, address: str, template: str | None = None) -> list[EmailMessage]:
        return [
            m
            for m in self.messages
            if m.to.lower() == address.lower() and (template is None or m.template == template)
        ]

    def clear(self) -> None:
        self.messages.clear()
        self.keys.clear()


def new_idempotency_key() -> str:
    return uuid.uuid4().hex
