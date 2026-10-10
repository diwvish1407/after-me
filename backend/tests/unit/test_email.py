from __future__ import annotations

import io
import logging
import stat
from collections.abc import Iterator
from pathlib import Path

import pytest

from app.core.logging import build_formatter, configure_logging
from app.notifications.email import (
    ConsoleEmailProvider,
    EmailMessage,
    RecordingEmailProvider,
)
from app.notifications.mailer import EmailTemplate, Mailer
from tests.support import make_settings

pytestmark = pytest.mark.no_db


@pytest.fixture
def log_output() -> Iterator[io.StringIO]:
    configure_logging(make_settings(log_level="DEBUG"))
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(build_formatter(json=True))
    logging.getLogger().addHandler(handler)
    try:
        yield stream
    finally:
        logging.getLogger().removeHandler(handler)


def test_templates_render_plain_text() -> None:
    mailer = Mailer(RecordingEmailProvider(), sender="AfterMe <no-reply@afterme.test>")
    message = mailer.render(
        EmailTemplate.SIGNUP_CODE,
        to="user@example.com",
        display_name="<b>Asha</b>",
        code="482913",
        expires_minutes=15,
    )
    assert message.subject == "Your AfterMe code"
    assert "482913" in message.text
    assert "15 minutes" in message.text
    assert "<b>Asha</b>" in message.text  # plain text: nothing to escape, nothing interpreted
    assert message.sender == "AfterMe <no-reply@afterme.test>"
    exists = mailer.render(EmailTemplate.ACCOUNT_EXISTS, to="user@example.com")
    assert "sign in or reset your password" in exists.text
    locked = mailer.render(EmailTemplate.ACCOUNT_LOCKED, to="user@example.com", lock_minutes=15)
    assert "15 minutes" in locked.text


def test_missing_template_variables_fail_loudly() -> None:
    mailer = Mailer(RecordingEmailProvider(), sender="x@afterme.test")
    with pytest.raises(Exception, match="undefined"):
        mailer.render(EmailTemplate.SIGNUP_CODE, to="user@example.com")


async def test_console_provider_writes_private_file_and_logs_only_the_path(
    tmp_path: Path, log_output: io.StringIO
) -> None:
    provider = ConsoleEmailProvider(tmp_path / "mail")
    message = EmailMessage(
        to="private.person@example.com",
        subject="s",
        text="code 482913",
        template="signup_code",
        sender="AfterMe <no-reply@afterme.test>",
    )
    result = await provider.send(message, idempotency_key="abcdef0123456789")
    written = list((tmp_path / "mail").iterdir())
    assert len(written) == 1
    assert written[0].name == result.message_id
    assert "482913" in written[0].read_text()
    assert stat.S_IMODE(written[0].stat().st_mode) == 0o600
    assert stat.S_IMODE((tmp_path / "mail").stat().st_mode) == 0o700
    output = log_output.getvalue()
    assert written[0].name in output
    assert "private.person" not in output
    assert "482913" not in output


async def test_mailer_swallows_provider_failures_without_logging_addresses(
    log_output: io.StringIO,
) -> None:
    provider = RecordingEmailProvider(fail_next=True)
    mailer = Mailer(provider, sender="x@afterme.test")
    first = mailer.render(EmailTemplate.ACCOUNT_EXISTS, to="first@example.com")
    second = mailer.render(EmailTemplate.ACCOUNT_EXISTS, to="second@example.com")
    await mailer.deliver([first, second])
    assert [m.to for m in provider.messages] == ["second@example.com"]
    output = log_output.getvalue()
    assert "email.send_failed" in output
    assert "ConnectionError" in output
    assert "first@example.com" not in output
    provider.clear()
    assert provider.to("second@example.com") == []
