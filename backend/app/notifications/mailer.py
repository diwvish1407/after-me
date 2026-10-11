"""Render transactional emails and send them after the request transaction commits.

Known Phase 1 limitation: a crash between COMMIT and the send loses that email (the user can ask
for a new code). Phase 8 replaces this with the transactional outbox and dispatcher.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Sequence
from enum import StrEnum
from pathlib import Path
from typing import Any, Final

from jinja2 import Environment, FileSystemLoader, StrictUndefined, select_autoescape

from app.core.logging import get_logger
from app.notifications.email import (
    EmailMessage,
    EmailProvider,
    ProviderResult,
    new_idempotency_key,
)
from app.notifications.html import text_to_html

_TEMPLATE_DIR: Final = Path(__file__).with_name("templates") / "email"
_log = get_logger("afterme.email")


class EmailTemplate(StrEnum):
    SIGNUP_CODE = "signup_code"
    ACCOUNT_EXISTS = "account_exists"
    ACCOUNT_LOCKED = "account_locked"
    REFRESH_REUSE_DETECTED = "refresh_reuse_detected"
    SESSIONS_REVOKED = "sessions_revoked"
    NEW_DEVICE_LOGIN = "new_device_login"
    PASSWORD_RESET_LINK = "password_reset_link"  # noqa: S105
    PASSWORD_RESET_COMPLETED = "password_reset_completed"  # noqa: S105
    PASSWORD_CHANGED = "password_changed"  # noqa: S105
    EMAIL_CHANGE_CODE = "email_change_code"
    EMAIL_CHANGE_REQUESTED = "email_change_requested"
    EMAIL_CHANGED = "email_changed"
    CONTACT_INVITATION = "contact_invitation"
    CONTACT_ACCEPTED = "contact_accepted"
    CONTACT_DECLINED = "contact_declined"
    CONTACT_OPTED_OUT = "contact_opted_out"
    # Phase 5: the escalation engine's messages (to the user and to a contact).
    CHECKIN_PRE_REMINDER = "checkin_pre_reminder"
    INCIDENT_MISSED = "incident_missed"
    INCIDENT_MIDPOINT = "incident_midpoint"
    INCIDENT_LAST_CHANCE = "incident_last_chance"
    INCIDENT_DELAYED = "incident_delayed"
    STAGE_EXECUTED = "stage_executed"
    RELEASE_FINAL_WARNING = "release_final_warning"
    ALL_CLEAR_CONFIRMATION = "all_clear_confirmation"
    SERVICE_INTERRUPTION = "service_interruption"
    CONTACT_ALERT = "contact_alert"
    CONTACT_ALERT_WITH_RELEASE = "contact_alert_with_release"
    CONTACT_RELEASE = "contact_release"
    CONTACT_ALL_CLEAR = "contact_all_clear"
    CONTACT_ALERT_WITHDRAWN = "contact_alert_withdrawn"
    ALERT_WITHDRAWN_NOTICE = "alert_withdrawn_notice"
    CONTACT_UNREACHABLE = "contact_unreachable"
    PORTAL_CODE = "portal_code"
    # Phase 7: account deletion.
    ACCOUNT_DELETION_LINK = "account_deletion_link"
    ACCOUNT_DELETION_REQUESTED = "account_deletion_requested"
    WEB_LOGIN_NOTICE = "web_login_notice"


_SUBJECTS: Final[dict[EmailTemplate, str]] = {
    EmailTemplate.SIGNUP_CODE: "Your AfterMe code",
    EmailTemplate.ACCOUNT_EXISTS: "Someone tried to create an AfterMe account with your email",
    EmailTemplate.ACCOUNT_LOCKED: "Sign-in to AfterMe is paused for {lock_minutes} minutes",
    EmailTemplate.REFRESH_REUSE_DETECTED: "A session on your AfterMe account was signed out",
    EmailTemplate.SESSIONS_REVOKED: "All sessions on your AfterMe account were signed out",
    EmailTemplate.NEW_DEVICE_LOGIN: "New sign-in to your AfterMe account",
    EmailTemplate.PASSWORD_RESET_LINK: "Reset your AfterMe password",
    EmailTemplate.PASSWORD_RESET_COMPLETED: "Your AfterMe password was reset",
    EmailTemplate.PASSWORD_CHANGED: "Your AfterMe password was changed",
    EmailTemplate.EMAIL_CHANGE_CODE: "Your AfterMe code",
    EmailTemplate.EMAIL_CHANGE_REQUESTED: "A change of your AfterMe email address was requested",
    EmailTemplate.EMAIL_CHANGED: "The email address of your AfterMe account was changed",
    EmailTemplate.CONTACT_INVITATION: "{inviter_name} added you as a trusted contact on AfterMe",
    EmailTemplate.CONTACT_ACCEPTED: "{contact_name} accepted your AfterMe invitation",
    EmailTemplate.CONTACT_DECLINED: "{contact_name} declined your AfterMe invitation",
    EmailTemplate.CONTACT_OPTED_OUT: "{contact_name} asked not to be contacted through AfterMe",
    EmailTemplate.CHECKIN_PRE_REMINDER: "Check-in due at {due_at}",
    EmailTemplate.INCIDENT_MISSED: "You missed your {due_time} check-in",
    EmailTemplate.INCIDENT_MIDPOINT: "Still waiting for your check-in",
    EmailTemplate.INCIDENT_LAST_CHANCE: "{who} will be notified in 15 minutes",
    EmailTemplate.INCIDENT_DELAYED: "We gave you more time to check in",
    EmailTemplate.STAGE_EXECUTED: "{notified_phrase}",
    EmailTemplate.RELEASE_FINAL_WARNING: "In 1 hour, information will be shared with {names}",
    EmailTemplate.ALL_CLEAR_CONFIRMATION: "All clear sent",
    EmailTemplate.SERVICE_INTERRUPTION: "We had a service interruption. Please check in",
    EmailTemplate.CONTACT_ALERT: "{user_name} hasn't checked in",
    EmailTemplate.CONTACT_ALERT_WITH_RELEASE: "{user_name} hasn't checked in",
    EmailTemplate.CONTACT_RELEASE: "{user_name} left information for you",
    EmailTemplate.PORTAL_CODE: "Your AfterMe code",
    EmailTemplate.CONTACT_ALL_CLEAR: "{user_name} has checked in. All clear.",
    EmailTemplate.CONTACT_ALERT_WITHDRAWN: "The earlier alert about {user_name} is withdrawn",
    EmailTemplate.ALERT_WITHDRAWN_NOTICE: "We withdrew an alert about you. Please check in",
    EmailTemplate.CONTACT_UNREACHABLE: "We couldn't reach {contact_name}",
    EmailTemplate.ACCOUNT_DELETION_LINK: "Confirm the deletion of your AfterMe account",
    EmailTemplate.ACCOUNT_DELETION_REQUESTED: "Your AfterMe account is scheduled for deletion",
    EmailTemplate.WEB_LOGIN_NOTICE: "Your AfterMe account was signed in on the web",
}


# The address a deleted account is given: it cannot receive mail, and nothing should be sent
# to it. ``Mailer.deliver`` drops anything addressed here.
DELETED_ADDRESS_SUFFIX: Final = "@deleted.invalid"


def mask_email(address: str) -> str:
    """``alice@example.com`` -> ``a***@example.com``: enough for the owner to recognise it, not
    enough for a reader of the notice to learn the whole address."""
    local, _, domain = address.strip().partition("@")
    return f"{local[:1]}***@{domain}" if domain else "***"


# Called with each message the provider accepted and its result: used to remember who a
# contact-bound direct message was about (``email_receipts``). Must not raise into the caller.
ReceiptSink = Callable[[EmailMessage, ProviderResult], Awaitable[None]]


class Mailer:
    def __init__(
        self, provider: EmailProvider, *, sender: str, receipts: ReceiptSink | None = None
    ) -> None:
        self.provider = provider
        self._receipts = receipts
        self._sender = sender
        self._env = Environment(
            loader=FileSystemLoader(_TEMPLATE_DIR),
            # Plain-text templates; HTML templates (Phase 8) are escaped automatically.
            autoescape=select_autoescape(["html", "htm", "xml"]),
            undefined=StrictUndefined,
            keep_trailing_newline=True,
        )

    def render(self, template: EmailTemplate, *, to: str, **context: Any) -> EmailMessage:
        body = self._env.get_template(f"{template.value}.txt.j2").render(**context)
        return EmailMessage(
            to=to,
            subject=_SUBJECTS[template].format(**context),
            text=body,
            template=template.value,
            sender=self._sender,
            html=text_to_html(body),
        )

    async def deliver(self, messages: Sequence[EmailMessage]) -> None:
        """Send after COMMIT. A failure is logged (template and error class only) and swallowed:
        the request already succeeded and must not fail because of email."""
        for message in messages:
            if message.to.lower().endswith(DELETED_ADDRESS_SUFFIX):
                continue  # the account was closed: there is nobody to tell
            try:
                result = await self.provider.send(message, idempotency_key=new_idempotency_key())
                if self._receipts is not None and message.contact_id is not None:
                    try:
                        await self._receipts(message, result)
                    except Exception as exc:  # a receipt is a convenience, never a failure
                        _log.warning("email.receipt_failed", error_class=type(exc).__name__)
            except Exception as exc:  # provider failures must not fail the request
                _log.warning(
                    "email.send_failed",
                    template=message.template,
                    provider=self.provider.name,
                    error_class=type(exc).__name__,
                )
