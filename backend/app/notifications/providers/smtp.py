"""Plain SMTP with STARTTLS or implicit TLS: the lowest common denominator.

Any provider (SES, Mailgun, SendGrid, Postmark, a relay) speaks it. There is no idempotency
header and no delivery feedback beyond acceptance; bounces need that provider's own webhook,
which this adapter does not parse. The standard library is used on a worker thread so nothing
blocks the event loop.
"""

from __future__ import annotations

import asyncio
import re
import smtplib
import ssl
import uuid
from email.message import EmailMessage as MimeMessage
from email.utils import formatdate, make_msgid, parseaddr
from typing import Final

from app.notifications.email import EmailMessage, ProviderResult
from app.notifications.errors import (
    PermanentDeliveryError,
    ProviderUnavailableError,
    TransientProviderError,
)

_TIMEOUT: Final = 15.0
# "This mailbox does not exist" (RFC 3463 5.1.x) and its plain-text forms. A bare 550 can also
# be "relay denied", "sender blocked" or a policy about *us*: not a verdict on the contact.
_MAILBOX_GONE: Final = re.compile(
    rb"\b5\.1\.[1236]\b|no such user|user unknown|unknown user|does not exist|"
    rb"mailbox (?:not found|unavailable)|recipient (?:not found|unknown)",
    re.IGNORECASE,
)


class SmtpEmailProvider:
    name = "smtp"

    def __init__(
        self,
        *,
        host: str,
        port: int,
        username: str | None,
        password: str | None,
        implicit_tls: bool = False,
    ) -> None:
        self._host = host
        self._port = port
        self._username = username
        self._password = password
        self._implicit_tls = implicit_tls

    def _build(self, msg: EmailMessage, idempotency_key: str) -> tuple[MimeMessage, str]:
        mime = MimeMessage()
        domain = parseaddr(msg.sender)[1].rpartition("@")[2] or "afterme.invalid"
        message_id = make_msgid(idstring=uuid.uuid4().hex[:12], domain=domain)
        mime["From"] = msg.sender
        mime["To"] = msg.to
        mime["Subject"] = msg.subject
        mime["Date"] = formatdate(localtime=False)
        mime["Message-ID"] = message_id
        mime["Auto-Submitted"] = "auto-generated"
        mime["X-Entity-Ref-ID"] = idempotency_key
        mime.set_content(msg.text)
        if msg.html is not None:
            mime.add_alternative(msg.html, subtype="html")
        return mime, message_id

    def _send_sync(self, mime: MimeMessage) -> None:
        context = ssl.create_default_context()
        if self._implicit_tls:
            server: smtplib.SMTP = smtplib.SMTP_SSL(
                self._host, self._port, timeout=_TIMEOUT, context=context
            )
        else:
            server = smtplib.SMTP(self._host, self._port, timeout=_TIMEOUT)
        with server:
            if not self._implicit_tls:
                server.starttls(context=context)
            if self._username:
                server.login(self._username, self._password or "")
            server.send_message(mime)

    async def send(self, msg: EmailMessage, *, idempotency_key: str) -> ProviderResult:
        mime, message_id = self._build(msg, idempotency_key)
        try:
            await asyncio.to_thread(self._send_sync, mime)
        except smtplib.SMTPAuthenticationError:
            raise ProviderUnavailableError("smtp_auth") from None
        except smtplib.SMTPRecipientsRefused as exc:
            replies = list(exc.recipients.values())
            gone = bool(replies) and all(
                500 <= code < 600 and _MAILBOX_GONE.search(_as_bytes(reason))  # noqa: PLR2004
                for code, reason in replies
            )
            if gone:
                raise PermanentDeliveryError("smtp_mailbox_gone") from None
            if replies and all(500 <= code < 600 for code, _ in replies):  # noqa: PLR2004
                raise ProviderUnavailableError("smtp_recipient_refused") from None
            raise TransientProviderError("smtp_recipient_deferred") from None
        except smtplib.SMTPResponseException as exc:
            # A reply that is not about one named recipient (550 relay denied, 554 transaction
            # failed, 5.7.x policy) says nothing about the contact's address: never a verdict.
            raise ProviderUnavailableError(f"smtp_{exc.smtp_code}") from None
        except (smtplib.SMTPException, OSError, TimeoutError):
            raise TransientProviderError("smtp_unreachable") from None
        return ProviderResult(provider=self.name, message_id=message_id)


def _as_bytes(value: object) -> bytes:
    return value if isinstance(value, bytes) else str(value).encode()
