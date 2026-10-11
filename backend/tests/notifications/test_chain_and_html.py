"""The email fallback chain and the HTML twin of every message."""

from __future__ import annotations

import pytest

from app.notifications.email import EmailMessage, ProviderResult
from app.notifications.errors import (
    PermanentDeliveryError,
    ProviderUnavailableError,
    TransientProviderError,
)
from app.notifications.html import text_to_html
from app.notifications.providers.chain import (
    COOL_DOWN_SECONDS,
    FAILURES_BEFORE_SKIP,
    FallbackEmailProvider,
)

pytestmark = pytest.mark.no_db

MESSAGE = EmailMessage(
    to="a@example.com", subject="s", text="t", template="contact_alert", sender="x@y.z"
)


class _Provider:
    def __init__(self, name: str, *, fail: Exception | None = None) -> None:
        self.name = name
        self.fail = fail
        self.calls = 0

    async def send(self, msg: EmailMessage, *, idempotency_key: str) -> ProviderResult:
        self.calls += 1
        if self.fail is not None:
            raise self.fail
        return ProviderResult(provider=self.name, message_id=f"{self.name}-{idempotency_key}")


async def test_the_primary_is_used_while_it_works() -> None:
    primary, fallback = _Provider("resend"), _Provider("postmark")
    chain = FallbackEmailProvider(primary, fallback)
    result = await chain.send(MESSAGE, idempotency_key="1")
    assert result.provider == "resend"
    assert (primary.calls, fallback.calls) == (1, 0)
    assert not chain.degraded


async def test_the_fallback_takes_over_when_the_provider_cannot_be_used() -> None:
    for failure in (ProviderUnavailableError("auth"), TransientProviderError("timeout")):
        primary = _Provider("resend", fail=failure)
        fallback = _Provider("postmark")
        chain = FallbackEmailProvider(primary, fallback)
        result = await chain.send(MESSAGE, idempotency_key="1")
        assert result.provider == "postmark"
        assert (primary.calls, fallback.calls) == (1, 1)


async def test_one_providers_refusal_is_not_final_the_other_is_asked() -> None:
    primary = _Provider("postmark", fail=PermanentDeliveryError("inactive_recipient"))
    fallback = _Provider("resend")
    chain = FallbackEmailProvider(primary, fallback)
    result = await chain.send(MESSAGE, idempotency_key="1")
    assert result.provider == "resend"
    assert (primary.calls, fallback.calls) == (1, 1)


async def test_when_every_provider_refuses_the_refusal_is_final() -> None:
    chain = FallbackEmailProvider(
        _Provider("postmark", fail=PermanentDeliveryError("inactive_recipient")),
        _Provider("resend", fail=PermanentDeliveryError("invalid_to_address")),
    )
    with pytest.raises(PermanentDeliveryError):
        await chain.send(MESSAGE, idempotency_key="1")


async def test_a_refusal_and_an_outage_is_retried_not_final() -> None:
    chain = FallbackEmailProvider(
        _Provider("postmark", fail=PermanentDeliveryError("inactive_recipient")),
        _Provider("resend", fail=ProviderUnavailableError("down")),
    )
    with pytest.raises(TransientProviderError):  # the second provider has not answered
        await chain.send(MESSAGE, idempotency_key="1")


async def test_when_both_fail_the_failure_is_transient_so_the_message_is_retried() -> None:
    chain = FallbackEmailProvider(
        _Provider("resend", fail=ProviderUnavailableError("a")),
        _Provider("postmark", fail=TransientProviderError("b")),
    )
    with pytest.raises(TransientProviderError):
        await chain.send(MESSAGE, idempotency_key="1")
    chain = FallbackEmailProvider(
        _Provider("resend", fail=ConnectionError("x")),
        _Provider("postmark", fail=RuntimeError("y")),
    )
    with pytest.raises(TransientProviderError):  # unknown failures are never final
        await chain.send(MESSAGE, idempotency_key="1")


async def test_a_failing_provider_is_skipped_for_a_while_then_tried_again() -> None:
    now = [1000.0]
    primary = _Provider("resend", fail=ProviderUnavailableError("down"))
    fallback = _Provider("postmark")
    chain = FallbackEmailProvider(primary, fallback, clock=lambda: now[0])
    for _ in range(FAILURES_BEFORE_SKIP):
        await chain.send(MESSAGE, idempotency_key="1")
    assert primary.calls == FAILURES_BEFORE_SKIP
    assert chain.degraded

    await chain.send(MESSAGE, idempotency_key="2")  # skipped: no new timeout is paid
    assert primary.calls == FAILURES_BEFORE_SKIP

    now[0] += COOL_DOWN_SECONDS + 1
    primary.fail = None  # recovered
    result = await chain.send(MESSAGE, idempotency_key="3")
    assert result.provider == "resend"
    assert not chain.degraded


async def test_with_everything_cooling_down_it_still_tries_rather_than_sending_nothing() -> None:
    now = [0.0]
    primary = _Provider("resend", fail=ProviderUnavailableError("down"))
    fallback = _Provider("postmark", fail=ProviderUnavailableError("down"))
    chain = FallbackEmailProvider(primary, fallback, clock=lambda: now[0])
    for _ in range(FAILURES_BEFORE_SKIP):
        with pytest.raises(TransientProviderError):
            await chain.send(MESSAGE, idempotency_key="1")
    fallback.fail = None
    result = await chain.send(MESSAGE, idempotency_key="2")
    assert result.provider == "postmark"


# --- the HTML twin ----------------------------------------------------------------------------


def test_html_is_derived_from_the_text_and_escapes_everything() -> None:
    html = text_to_html(
        "Hi <b>Mom</b>,\n\nOpen https://afterme.example/c/open#ci_abc.\n\n- one\n- two"
    )
    assert "&lt;b&gt;Mom&lt;/b&gt;" in html
    assert "<b>" not in html
    assert '<a href="https://afterme.example/c/open#ci_abc"' in html
    assert ">https://afterme.example/c/open#ci_abc</a>." in html  # the full stop is outside
    assert "<ul" in html
    assert html.count("<li>") == 2
    assert html.startswith("<!doctype html>")


def test_html_never_makes_an_unsafe_link_or_runs_markup() -> None:
    html = text_to_html('javascript:alert(1) <script>x</script> "quoted" https://a.example/?q="x"')
    assert "<script>" not in html
    assert 'href="javascript' not in html
    assert "&lt;script&gt;" in html
    assert '"x"' not in html.split("href=")[1].split(">")[0] or "&quot;" in html
