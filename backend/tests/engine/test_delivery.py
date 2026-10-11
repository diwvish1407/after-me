"""Delivery against real provider behaviour (TEST_PLAN NOT-01…15, OPS-03).

The dispatcher decides by the *kind* of failure (``app.notifications.errors``). These tests give
it scripted providers and watch what happens to the message, the contact and the person.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import timedelta
from typing import Any

from app.notifications.email import EmailMessage, ProviderResult, RecordingEmailProvider
from app.notifications.errors import (
    InvalidPushTokenError,
    PermanentDeliveryError,
    ProviderUnavailableError,
    TransientProviderError,
)
from app.notifications.providers.chain import FallbackEmailProvider
from app.notifications.push import PushMessage
from tests.engine.test_release import BODY, TITLE, _released, address
from tests.world import Person, World, ist

DUE = ist("2026-10-09T20:00")
STAGE_1 = DUE + timedelta(minutes=180)
Rule = Callable[[EmailMessage], Exception | None]


class RuleEmail:
    """An email provider whose answer is decided per message."""

    def __init__(self, rule: Rule, name: str = "scripted") -> None:
        self.name = name
        self.rule = rule
        self.sent: list[EmailMessage] = []
        self.attempts: list[EmailMessage] = []

    async def send(self, msg: EmailMessage, *, idempotency_key: str) -> ProviderResult:
        self.attempts.append(msg)
        failure = self.rule(msg)
        if failure is not None:
            raise failure
        self.sent.append(msg)
        return ProviderResult(provider=self.name, message_id=f"{self.name}-{len(self.sent)}")

    def to(self, address_: str, template: str | None = None) -> list[EmailMessage]:
        return [
            m
            for m in self.sent
            if m.to == address_ and (template is None or m.template == template)
        ]


def _notification(world: World, person: Person, template: str) -> dict[str, Any]:
    row = world.db.execute(
        "SELECT * FROM notifications WHERE user_id = %s AND template_key = %s "
        "ORDER BY created_at LIMIT 1",
        (person.user_id, template),
    ).fetchone()
    assert row is not None, template
    return dict(row)


def _contact(world: World, person: Person, label: str = "Mom") -> dict[str, Any]:
    row = world.db.execute(
        "SELECT * FROM trusted_contacts WHERE id = %s", (person.contacts[label],)
    ).fetchone()
    assert row is not None
    return dict(row)


# --- transient failures -----------------------------------------------------------------------


async def test_a_provider_outage_is_retried_and_honours_its_retry_after(world: World) -> None:
    person = await world.ready()
    mom = address(person, "Mom")
    down = [True]

    def rule(message: EmailMessage) -> Exception | None:
        if message.to == mom and down[0]:
            return TransientProviderError("timeout", retry_after=1200)
        return None

    provider = RuleEmail(rule)
    world.dispatcher.email = provider
    await world.advance_to(STAGE_1 + timedelta(minutes=6))

    row = _notification(world, person, "contact_alert")
    assert row["status"] == "queued"
    assert row["attempt_count"] == 1
    # the provider asked for 20 minutes; an alert does not wait that long: capped at 5, which is
    # more than the 1-minute backoff would have been
    assert row["next_attempt_at"] - row["updated_at"] == timedelta(minutes=5)
    assert provider.to(mom) == []

    down[0] = False
    await world.advance(minutes=30)
    assert len(provider.to(mom, "contact_alert")) == 1  # exactly once
    assert _notification(world, person, "contact_alert")["status"] == "sent"


async def test_a_message_given_up_on_after_a_day_tells_the_person_and_leaves_the_contact(
    world: World,
) -> None:
    person = await world.ready()
    mom = address(person, "Mom")
    provider = RuleEmail(
        lambda m: TransientProviderError("timeout") if m.to == mom else None, name="resend"
    )
    world.dispatcher.email = provider
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    await world.advance(hours=25)

    assert _notification(world, person, "contact_alert")["status"] == "failed"
    assert _contact(world, person)["verification_status"] == "verified"  # not their fault
    notices = provider.to(person.email, "contact_unreachable")
    assert len(notices) == 1
    assert "couldn't reach Mom" in notices[0].subject
    assert "could not be delivered" in notices[0].text
    assert "will try again" in notices[0].text
    audit = world.db.execute(
        "SELECT action FROM audit_logs WHERE subject_user_id = %s AND action = %s",
        (person.user_id, "notification.failed"),
    ).fetchall()
    assert len(audit) == 1


# --- permanent failures and bounces -----------------------------------------------------------


async def test_a_refused_address_marks_the_contact_bounced_and_tells_the_person(
    world: World,
) -> None:
    person = await world.ready()
    mom = address(person, "Mom")
    world.db.execute(
        "UPDATE devices SET push_token = 'fcm-token-for-the-test' WHERE id = "
        "(SELECT id FROM devices WHERE user_id = %s ORDER BY created_at, id LIMIT 1)",
        (person.user_id,),
    )
    provider = RuleEmail(
        lambda m: PermanentDeliveryError("postmark_406") if m.to == mom else None,
        name="postmark",
    )
    world.dispatcher.email = provider
    await world.advance_to(STAGE_1 + timedelta(minutes=6))

    assert _notification(world, person, "contact_alert")["status"] == "failed"
    assert _contact(world, person)["verification_status"] == "bounced"
    # a provider's refusal is its own list, not a fact about the mailbox: nothing is suppressed
    # for everyone (a bounce webhook, which is the mailbox's own answer, does that)
    assert world.db.execute("SELECT reason FROM email_suppressions").fetchall() == []
    log = world.db.execute(
        "SELECT outcome, error_code FROM notification_logs WHERE notification_id = %s",
        (_notification(world, person, "contact_alert")["id"],),
    ).fetchall()
    assert [dict(r) for r in log] == [{"outcome": "rejected", "error_code": "postmark_406"}]

    [notice] = provider.to(person.email, "contact_unreachable")
    assert "message came back as undeliverable" in notice.text
    assert "Mom" in notice.text  # the email may name her: it is the person's own inbox
    pushes = [m for m in world.push.messages if m.type == "contact_unreachable"]
    assert len(pushes) == 1
    assert "Mom" not in pushes[0].title + pushes[0].body  # the lock screen must not
    assert pushes[0].channel == "account"
    visible = world.db.execute(
        "SELECT user_visible FROM audit_logs WHERE action = 'contact.bounced'"
    ).fetchone()
    assert visible == {"user_visible": True}


async def test_nothing_is_sent_again_to_an_address_that_bounced(world: World) -> None:
    person = await world.ready(
        stages=((180, ("Mom",)), (1440, ("Mom",))),
    )
    mom = address(person, "Mom")
    provider = RuleEmail(lambda m: PermanentDeliveryError("bounce") if m.to == mom else None)
    world.dispatcher.email = provider
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    assert _contact(world, person)["verification_status"] == "bounced"
    attempts_after_first = len([m for m in provider.attempts if m.to == mom])
    await world.advance(days=2)
    assert len([m for m in provider.attempts if m.to == mom]) == attempts_after_first


# --- push -------------------------------------------------------------------------------------


async def test_a_dead_push_token_is_forgotten_and_the_reminder_still_arrives_by_email(
    world: World,
) -> None:
    person = await world.ready()
    world.db.execute(
        "UPDATE devices SET push_token = 'fcm-token-for-the-test' WHERE id = "
        "(SELECT id FROM devices WHERE user_id = %s ORDER BY created_at, id LIMIT 1)",
        (person.user_id,),
    )

    class DeadToken:
        name = "fcm"

        async def send(self, msg: PushMessage, *, idempotency_key: str) -> ProviderResult:
            raise InvalidPushTokenError("unregistered")

    world.dispatcher.push = DeadToken()
    await world.advance_to(DUE + timedelta(minutes=2))

    token = world.db.execute(
        "SELECT push_token FROM devices WHERE user_id = %s", (person.user_id,)
    ).fetchall()
    assert token
    assert all(r["push_token"] is None for r in token)
    cancelled = world.db.execute(
        "SELECT cancelled_reason FROM notifications WHERE user_id = %s AND channel = 'push' "
        "AND status = 'cancelled'",
        (person.user_id,),
    ).fetchall()
    assert cancelled
    assert {r["cancelled_reason"] for r in cancelled} == {"push_token_invalid"}
    assert len(world.mail.to(person.email, "incident_missed")) == 1


# --- the fallback provider --------------------------------------------------------------------


async def test_the_fallback_provider_carries_the_alert_while_the_primary_is_down(
    world: World,
) -> None:
    person = await world.ready()
    mom = address(person, "Mom")
    primary = RuleEmail(lambda _: ProviderUnavailableError("resend_401"), name="resend")
    fallback = RuleEmail(lambda _: None, name="postmark")
    world.dispatcher.email = FallbackEmailProvider(primary, fallback)
    await world.advance_to(STAGE_1 + timedelta(minutes=6))

    assert len(fallback.to(mom, "contact_alert")) == 1
    assert primary.sent == []
    row = _notification(world, person, "contact_alert")
    assert (row["status"], row["provider"]) == ("sent", "postmark")
    assert row["attempt_count"] == 1  # the chain's switch is not a second attempt


# --- what never appears in a message ----------------------------------------------------------


async def test_no_email_or_push_of_a_whole_released_incident_holds_instruction_content(
    world: World,
) -> None:
    person = await _released(world)
    world.db.execute(
        "UPDATE devices SET push_token = 'fcm-token-for-the-test' WHERE id = "
        "(SELECT id FROM devices WHERE user_id = %s ORDER BY created_at, id LIMIT 1)",
        (person.user_id,),
    )
    await world.advance(hours=2)
    assert world.mail.messages
    for email in world.mail.messages:
        text = f"{email.subject}\n{email.text}\n{email.html or ''}"
        assert TITLE not in text, email.template
        assert "Sharma" not in text, email.template
        assert BODY.split("\n")[0] not in text, email.template
    for push in world.push.messages:
        assert TITLE not in push.title + push.body
        assert "Sharma" not in push.title + push.body


async def test_every_email_of_a_lifecycle_carries_its_html_twin(world: World) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    assert isinstance(world.mail, RecordingEmailProvider)
    assert world.mail.messages
    for email in world.mail.messages:
        assert email.html is not None, email.template
        assert email.html.startswith("<!doctype html>")
        assert "<script" not in email.html
    _ = person


async def test_a_message_every_provider_refuses_is_the_only_one_marked_bounced(
    world: World,
) -> None:
    """One provider's "inactive recipient" is not final: the other is asked first."""
    person = await world.ready()
    mom = address(person, "Mom")
    primary = RuleEmail(
        lambda m: PermanentDeliveryError("postmark_406") if m.to == mom else None, name="postmark"
    )
    fallback = RuleEmail(lambda _: None, name="resend")
    world.dispatcher.email = FallbackEmailProvider(primary, fallback)
    await world.advance_to(STAGE_1 + timedelta(minutes=6))

    assert len(fallback.to(mom, "contact_alert")) == 1  # delivered by the second provider
    assert _contact(world, person)["verification_status"] == "verified"
    assert world.mail.to(person.email, "contact_unreachable") == []


async def test_a_failure_to_tell_the_person_never_causes_the_alert_to_be_sent_again(
    world: World, monkeypatch: Any
) -> None:
    """The message's own state commits whatever its side effects do (review S2-7)."""
    from app.notifications import unreachable

    async def broken(*_: Any, **__: Any) -> bool:
        raise RuntimeError("a statement that cannot run")

    monkeypatch.setattr(unreachable, "contact_unreachable", broken)
    person = await world.ready()
    mom = address(person, "Mom")
    provider = RuleEmail(lambda m: PermanentDeliveryError("postmark_406") if m.to == mom else None)
    world.dispatcher.email = provider
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    await world.advance(minutes=30)  # the stuck-row recovery would have re-sent by now

    row = _notification(world, person, "contact_alert")
    assert row["status"] == "failed"  # recorded, once
    assert len([m for m in provider.attempts if m.to == mom]) == 1


async def test_a_provider_that_hangs_costs_a_deadline_not_the_whole_pass(
    world: World, monkeypatch: Any
) -> None:
    import asyncio

    from app.engine import dispatcher as dispatcher_module

    monkeypatch.setattr(dispatcher_module, "SEND_DEADLINE_SECONDS", 0.05)
    person = await world.ready()
    mom = address(person, "Mom")

    class Hangs(RuleEmail):
        async def send(self, msg: EmailMessage, *, idempotency_key: str) -> ProviderResult:
            if msg.to == mom:
                await asyncio.sleep(5)
            return await super().send(msg, idempotency_key=idempotency_key)

    provider = Hangs(lambda _: None)
    world.dispatcher.email = provider
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    row = _notification(world, person, "contact_alert")
    assert row["status"] == "queued"  # retried later: a deadline is a transient failure
    assert row["attempt_count"] >= 1
    # the person's own mail was not held behind it
    assert provider.to(person.email)


async def test_a_reminder_that_is_no_longer_true_is_dropped_not_delivered_late(
    world: World,
) -> None:
    person = await world.ready()
    world.db.execute(
        "UPDATE devices SET push_token = 'fcm-token-for-the-test' WHERE id = "
        "(SELECT id FROM devices WHERE user_id = %s ORDER BY created_at, id LIMIT 1)",
        (person.user_id,),
    )
    down = [True]

    class Down:
        name = "fcm"

        async def send(self, msg: PushMessage, *, idempotency_key: str) -> ProviderResult:
            if down[0]:
                raise TransientProviderError("fcm_unavailable")
            return ProviderResult(provider="fcm", message_id="1")

    world.dispatcher.push = Down()
    await world.advance_to(DUE + timedelta(minutes=166))  # "notified in 15 minutes" queued
    down[0] = False
    await world.advance(minutes=60)
    rows = world.db.execute(
        "SELECT status, cancelled_reason FROM notifications WHERE user_id = %s "
        "AND template_key = 'incident_last_chance' AND channel = 'push'",
        (person.user_id,),
    ).fetchall()
    assert rows
    assert {(r["status"], r["cancelled_reason"]) for r in rows} <= {
        ("cancelled", "expired"),
        ("cancelled", "incident_closed"),
        ("sent", None),
    }
