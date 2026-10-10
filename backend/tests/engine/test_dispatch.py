"""The outbox dispatcher (ESCALATION_ENGINE §8; TEST_PLAN NOT-*, ENG-FS-06/07/12)."""

from __future__ import annotations

from datetime import timedelta
from typing import Any

from tests.world import Person, World, ist

DUE = ist("2026-10-09T20:00")
STAGE_1 = DUE + timedelta(minutes=180)


async def _escalated(world: World, **kwargs: Any) -> Person:
    person = await world.ready(**kwargs)
    await world.advance_to(STAGE_1)
    return person


# --- settle delay and "contacts messaged" -----------------------------------------------------


async def test_nothing_reaches_a_contact_before_the_settle_delay(world: World) -> None:
    person = await _escalated(world)
    assert world.notifications(person, template_key="contact_alert")[0]["status"] == "queued"
    assert world.mail.to(f"mom.{person.user_id[:6]}@example.com", "contact_alert") == []
    await world.advance_to(STAGE_1 + timedelta(seconds=299))
    assert world.mail.to(f"mom.{person.user_id[:6]}@example.com", "contact_alert") == []
    assert world.open_incident(person)["contacts_messaged_at"] is None  # type: ignore[index]


async def test_the_alert_is_sent_after_the_settle_delay_and_marks_the_contacts_as_told(
    world: World,
) -> None:
    person = await _escalated(world)
    await world.advance_to(STAGE_1 + timedelta(seconds=300))
    address = f"mom.{person.user_id[:6]}@example.com"
    (message,) = world.mail.to(address, "contact_alert")
    assert message.subject == "Test User hasn't checked in"
    assert "Hi Mom," in message.text
    assert "Friday 9 Oct, 8:00 PM IST" in message.text  # day, time and zone
    assert "AfterMe is not an emergency service." in message.text
    assert "/c/optout#oo_" in message.text  # the opt-out link every contact email carries
    assert "emergency services" in message.text
    incident = world.open_incident(person)
    assert incident is not None
    assert incident["contacts_messaged_at"] == STAGE_1 + timedelta(seconds=300)
    alert = world.notifications(person, template_key="contact_alert")[0]
    assert alert["status"] == "sent"
    assert alert["sent_at"] == STAGE_1 + timedelta(seconds=300)
    logs = world.db.execute(
        "SELECT * FROM notification_logs WHERE notification_id = %s", (alert["id"],)
    ).fetchall()
    assert [(log["outcome"], log["provider"]) for log in logs] == [("accepted", "recording")]
    audit = world.db.execute(
        "SELECT * FROM audit_logs WHERE action = 'notification.sent' AND subject_user_id = %s",
        (person.user_id,),
    ).fetchall()
    assert len(audit) == 1  # contact-facing only (SECURITY §9)
    assert audit[0]["metadata"] == {"template": "contact_alert"}


async def test_the_user_is_told_once_it_is_true_and_the_summary_names_who(world: World) -> None:
    person = await _escalated(world)
    assert world.mail.to(person.email, "stage_executed") == []  # not before the settle delay
    await world.advance_to(STAGE_1 + timedelta(seconds=300))
    summary = world.mail.to(person.email, "stage_executed")
    assert len(summary) == 1
    assert summary[0].subject == "Mom has been notified"
    assert "tap I'M SAFE" in summary[0].text


async def test_user_reminders_go_out_at_their_time(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE)
    missed = world.mail.to(person.email, "incident_missed")
    assert len(missed) == 1
    assert missed[0].subject == "You missed your 8:00 PM check-in"
    assert "Mom will be notified at 11:00 PM" in missed[0].text
    await world.advance_to(DUE + timedelta(minutes=165))
    assert len(world.mail.to(person.email, "incident_last_chance")) == 1
    assert world.mail.to(person.email, "incident_midpoint") == []  # push only


async def test_push_is_generic_and_carries_no_names(world: World) -> None:
    person = await world.ready()
    world.db.execute(
        "UPDATE devices SET push_token = 'fcm-token-for-the-test' WHERE id = "
        "(SELECT id FROM devices WHERE user_id = %s ORDER BY created_at, id LIMIT 1)",
        (person.user_id,),
    )
    await world.advance_to(DUE + timedelta(minutes=95))  # missed + midpoint
    messages = world.push.messages
    assert {m.type for m in messages} == {
        "checkin_pre_reminder",
        "incident_missed",
        "incident_midpoint",
    }
    incident_id = str(world.open_incident(person)["id"])  # type: ignore[index]
    for message in messages:
        if message.type != "checkin_pre_reminder":
            assert message.incident_id == incident_id
        assert message.token == "fcm-token-for-the-test"
        text = f"{message.title} {message.body}".lower()
        for forbidden in ("mom", "@", "test user", "pm", "am "):
            assert forbidden not in text, (forbidden, text)


async def test_the_outbox_and_its_log_hold_no_addresses_or_names(world: World) -> None:
    person = await _escalated(world)
    await world.advance_to(STAGE_1 + timedelta(minutes=10))
    dump = str(
        world.db.execute(
            "SELECT params, template_key, cancelled_reason, provider_message_id FROM notifications"
        ).fetchall()
        + world.db.execute(
            "SELECT provider, provider_message_id, error_code FROM notification_logs"
        ).fetchall()
    )
    for forbidden in ("@", "Mom", "Test User", person.email):
        assert forbidden not in dump


# --- the re-checks (§8.2) ---------------------------------------------------------------------


async def test_a_contact_who_opted_out_meanwhile_is_not_sent_the_alert(world: World) -> None:
    person = await _escalated(world)
    world.db.execute(
        "UPDATE trusted_contacts SET verification_status = 'opted_out' WHERE id = %s",
        (person.contacts["Mom"],),
    )
    await world.advance_to(STAGE_1 + timedelta(minutes=10))
    alert = world.notifications(person, template_key="contact_alert")[0]
    assert alert["status"] == "cancelled"
    assert alert["cancelled_reason"] == "contact_not_verified_opted_out"
    assert world.mail.to(f"mom.{person.user_id[:6]}@example.com", "contact_alert") == []
    assert world.open_incident(person)["contacts_messaged_at"] is None  # type: ignore[index]


async def test_an_address_suppressed_meanwhile_is_not_sent_the_alert(world: World) -> None:
    from app.contacts.tokens import suppression_hash_candidates

    person = await _escalated(world)
    row = world.db.execute(
        "SELECT email_normalized FROM trusted_contacts WHERE id = %s", (person.contacts["Mom"],)
    ).fetchone()
    [h] = suppression_hash_candidates(world.engine.services.pepper, row["email_normalized"])
    world.db.execute(
        "INSERT INTO email_suppressions (email_hash, reason) VALUES (%s, 'hard_bounce')", (h,)
    )
    await world.advance_to(STAGE_1 + timedelta(minutes=10))
    alert = world.notifications(person, template_key="contact_alert")[0]
    assert (alert["status"], alert["cancelled_reason"]) == ("cancelled", "contact_suppressed")


async def test_a_message_of_a_closed_incident_is_cancelled_not_sent(world: World) -> None:
    person = await _escalated(world)
    world.db.execute(
        "UPDATE escalation_incidents SET status = 'resolved', closed_at = now(), "
        "closed_by = 'user_checkin' WHERE user_id = %s",
        (person.user_id,),
    )
    await world.advance_to(STAGE_1 + timedelta(minutes=10))
    alert = world.notifications(person, template_key="contact_alert")[0]
    assert (alert["status"], alert["cancelled_reason"]) == ("cancelled", "incident_closed")
    assert world.mail.to(f"mom.{person.user_id[:6]}@example.com", "contact_alert") == []


async def test_nothing_contact_facing_is_sent_during_hold_but_the_user_still_hears(
    world: World,
) -> None:
    """INV-10: messages to the person continue; contact messages wait, and so does the summary
    "Mom has been notified": it is only true together with the alert it reports."""
    person = await _escalated(world)
    world.db.execute(
        "INSERT INTO system_holds (reason, started_at, detected_at, created_by) "
        "VALUES ('operator', %s, %s, 'test')",
        (STAGE_1 + timedelta(minutes=1), STAGE_1 + timedelta(minutes=1)),
    )
    world.db.execute(
        "INSERT INTO notifications (user_id, audience, category, channel, template_key, "
        "status, send_after, dedupe_key) VALUES (%s, 'user', 'user', 'email', "
        "'service_interruption', 'queued', %s, 'a-message-to-the-person')",
        (person.user_id, STAGE_1 + timedelta(minutes=2)),
    )
    await world.advance_to(STAGE_1 + timedelta(minutes=30))
    alert = world.notifications(person, template_key="contact_alert")[0]
    assert alert["status"] == "queued"
    assert world.mail.to(f"mom.{person.user_id[:6]}@example.com", "contact_alert") == []
    assert world.mail.to(person.email, "service_interruption")  # the person is still reached
    assert world.mail.to(person.email, "stage_executed") == []  # but not told Mom was notified


async def test_a_message_waits_while_the_user_lock_is_busy(world: World) -> None:
    import psycopg

    from tests.support import conninfo

    person = await _escalated(world)
    holder = psycopg.connect(conninfo("afterme_owner", "afterme_owner_dev", "afterme_test"))
    try:
        holder.execute(
            "SELECT 1 FROM checkin_configurations WHERE user_id = %s FOR UPDATE",
            (person.user_id,),
        )
        await world.advance_to(STAGE_1 + timedelta(minutes=10))
        assert world.notifications(person, template_key="contact_alert")[0]["status"] == "queued"
        assert world.last_dispatch.left_queued >= 1
    finally:
        holder.rollback()
        holder.close()
    await world.tick()
    assert world.notifications(person, template_key="contact_alert")[0]["status"] == "sent"


async def test_a_pre_reminder_for_an_old_deadline_is_not_sent(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE - timedelta(minutes=59))
    reminder = world.notifications(person, template_key="checkin_pre_reminder")[0]
    assert reminder["status"] == "sent"  # it was due and went out
    # a second one for a deadline that has since moved is superseded
    world.db.execute(
        "UPDATE notifications SET status = 'queued', sent_at = NULL WHERE id = %s",
        (reminder["id"],),
    )
    world.db.execute(
        "UPDATE checkin_configurations SET next_due_at = next_due_at + interval '1 day' "
        "WHERE user_id = %s",
        (person.user_id,),
    )
    await world.dispatch()
    again = world.db.execute(
        "SELECT * FROM notifications WHERE id = %s", (reminder["id"],)
    ).fetchone()
    assert (again["status"], again["cancelled_reason"]) == ("cancelled", "superseded")


# --- failure and recovery ---------------------------------------------------------------------


async def test_a_failing_provider_is_retried_with_backoff_and_then_succeeds(
    world: World,
) -> None:
    person = await _escalated(world)
    # the user's own summary goes out in the same pass; keep the failure for the contact alert
    world.db.execute(
        "UPDATE notifications SET status = 'sent' WHERE template_key = 'stage_executed'"
    )
    world.mail.fail_next = True
    send_at = STAGE_1 + timedelta(seconds=300)
    await world.advance_to(send_at)
    alert = world.notifications(person, template_key="contact_alert")[0]
    assert (alert["status"], alert["attempt_count"]) == ("queued", 1)
    assert alert["next_attempt_at"] == send_at + timedelta(minutes=1)
    # "messaged" was recorded at the first attempt, even though the provider failed (§8.2)
    assert world.open_incident(person)["contacts_messaged_at"] == send_at  # type: ignore[index]
    logs = world.db.execute(
        "SELECT outcome, error_code FROM notification_logs WHERE notification_id = %s ORDER BY id",
        (alert["id"],),
    ).fetchall()
    assert [(r["outcome"], r["error_code"]) for r in logs] == [("error", "ConnectionError")]

    await world.advance_to(send_at + timedelta(minutes=1))
    alert = world.notifications(person, template_key="contact_alert")[0]
    assert alert["status"] == "sent"
    assert alert["attempt_count"] == 2


async def test_the_retry_ladder(world: World) -> None:
    from app.engine.dispatcher import retry_delay

    assert [retry_delay(n).total_seconds() / 60 for n in range(1, 11)] == [
        1,
        2,
        4,
        8,
        16,
        32,
        60,
        60,
        60,
        60,
    ]


async def test_after_a_day_of_failures_it_is_given_up_and_audited(world: World) -> None:
    person = await _escalated(world)
    world.db.execute(
        "UPDATE notifications SET status = 'sent' WHERE template_key = 'stage_executed'"
    )
    world.mail.fail_next = True
    await world.advance_to(STAGE_1 + timedelta(seconds=300))  # the first attempt
    # ... a day ago, as far as the log is concerned: the limit counts from the first attempt
    world.db.execute(
        "UPDATE notification_logs SET attempted_at = attempted_at - interval '25 hours'"
    )
    world.mail.fail_next = True
    await world.advance_to(STAGE_1 + timedelta(minutes=10))
    alert = world.notifications(person, template_key="contact_alert")[0]
    assert alert["status"] == "failed"
    audit = world.db.execute(
        "SELECT metadata FROM audit_logs WHERE action = 'notification.failed'"
    ).fetchall()
    assert audit[0]["metadata"]["error_class"] == "ConnectionError"


async def test_a_send_that_was_left_in_flight_is_put_back_in_the_queue(world: World) -> None:
    person = await _escalated(world)
    world.db.execute(
        "UPDATE notifications SET status = 'sending', updated_at = %s "
        "WHERE template_key = 'contact_alert'",
        (STAGE_1 - timedelta(minutes=30),),
    )
    report = await world.dispatch()
    assert report.recovered == 1
    # recovered, then it is subject to the same re-checks (and, here, is after the settle delay)
    await world.advance_to(STAGE_1 + timedelta(minutes=10))
    assert world.notifications(person, template_key="contact_alert")[0]["status"] == "sent"
