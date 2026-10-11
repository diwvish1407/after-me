"""``afterme-admin email-test`` and ``push-test``: proving a provider configuration by kind."""

from __future__ import annotations

import pytest

from app.notifications.email import EmailMessage, ProviderResult
from app.notifications.errors import ProviderUnavailableError
from app.notifications.push import PushMessage
from cli import admin
from tests.support import make_settings

pytestmark = pytest.mark.no_db


class _Email:
    name = "resend"

    def __init__(self, failure: Exception | None = None) -> None:
        self.failure = failure
        self.seen: list[EmailMessage] = []

    async def send(self, msg: EmailMessage, *, idempotency_key: str) -> ProviderResult:
        self.seen.append(msg)
        if self.failure is not None:
            raise self.failure
        return ProviderResult(provider=self.name, message_id="m-1")


async def test_email_test_reports_success_and_sends_only_the_given_address(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    provider = _Email()
    monkeypatch.setattr(admin, "load_settings", make_settings)
    monkeypatch.setattr(admin, "build_email_provider", lambda _: provider)
    assert await admin.run(["email-test", "--to", "me@example.com"]) == 0
    assert "ok: provider=resend message_id=m-1" in capsys.readouterr().out
    assert [m.to for m in provider.seen] == ["me@example.com"]
    assert provider.seen[0].template == "operator_test"


async def test_email_test_names_the_kind_of_failure_not_the_address(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(admin, "load_settings", make_settings)
    monkeypatch.setattr(
        admin, "build_email_provider", lambda _: _Email(ProviderUnavailableError("resend_403"))
    )
    assert await admin.run(["email-test", "--to", "me@example.com"]) == 1
    out = capsys.readouterr().out
    assert "ProviderUnavailableError code=resend_403" in out
    assert "me@example.com" not in out


async def test_push_test_uses_the_configured_push_provider(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    sent: list[PushMessage] = []

    class _Push:
        name = "fcm"

        async def send(self, msg: PushMessage, *, idempotency_key: str) -> ProviderResult:
            sent.append(msg)
            return ProviderResult(provider="fcm", message_id="0:1")

    monkeypatch.setattr(admin, "load_settings", make_settings)
    monkeypatch.setattr(admin, "build_push_provider", lambda _: _Push())
    assert await admin.run(["push-test", "--token", "t" * 40]) == 0
    assert "ok: provider=fcm" in capsys.readouterr().out
    assert sent[0].token == "t" * 40
