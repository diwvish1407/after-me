"""Provider webhooks: delivery, bounce and complaint events (API_SPEC §14; TEST_PLAN NOT-*).

Signatures are real (Svix HMAC for Resend, Basic auth for Postmark); the messages are the ones the
engine really sent. What an event may change: a log row, a suppressed address, a contact's
status, a notice to the person. Nothing else.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
from datetime import timedelta
from typing import Any

import pytest

from tests.engine.test_release import address
from tests.world import Person, World, ist

DUE = ist("2026-10-09T20:00")
STAGE_1 = DUE + timedelta(minutes=180)

WHSEC = "whsec_" + base64.b64encode(b"0123456789abcdef0123456789abcdef").decode()
POSTMARK_SECRET = "postmark-webhook-password-123"

PROVIDERS = pytest.mark.settings(
    email_provider="resend",
    email_api_key="re_test_key_00000000",
    email_webhook_secret=WHSEC,
    email_fallback_provider="postmark",
    email_fallback_api_key="pm_test_key_00000000",
    email_fallback_webhook_secret=POSTMARK_SECRET,
)


def svix(world: World, body: dict[str, Any], *, msg_id: str, age: int = 0, secret: str = WHSEC):
    raw = json.dumps(body).encode()
    stamp = int(world.clock.current.timestamp()) - age
    key = base64.b64decode(secret.removeprefix("whsec_"))
    signed = f"{msg_id}.{stamp}.".encode() + raw
    signature = base64.b64encode(hmac.new(key, signed, hashlib.sha256).digest()).decode()
    return raw, {
        "content-type": "application/json",
        "svix-id": msg_id,
        "svix-timestamp": str(stamp),
        "svix-signature": f"v1,{signature}",
    }


def resend_event(kind: str, email_id: str, **data: Any) -> dict[str, Any]:
    return {
        "type": kind,
        "created_at": "2026-10-09T14:36:00Z",
        "data": {"email_id": email_id, **data},
    }


async def _post(world: World, path: str, raw: bytes, headers: dict[str, str]) -> Any:
    return await world.h.client.post(path, content=raw, headers=headers)


async def _alerted(world: World) -> tuple[Person, str, str]:
    """A person whose first stage ran. Returns the person, the alert's notification id and a
    provider message id recorded against it as if Resend had accepted it."""
    person = await world.ready()
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    row = world.db.execute(
        "SELECT id FROM notifications WHERE user_id = %s AND template_key = 'contact_alert'",
        (person.user_id,),
    ).fetchone()
    assert row is not None
    message_id = "re_alert_0001"
    world.db.execute(
        "UPDATE notifications SET provider = 'resend', provider_message_id = %s WHERE id = %s",
        (message_id, row["id"]),
    )
    return person, str(row["id"]), message_id


def _logs(world: World, notification_id: str) -> list[dict[str, Any]]:
    return [
        dict(r)
        for r in world.db.execute(
            "SELECT outcome, error_code, provider, provider_event_id FROM notification_logs "
            "WHERE notification_id = %s AND provider_event_id IS NOT NULL ORDER BY id",
            (notification_id,),
        ).fetchall()
    ]


# --- who may call -----------------------------------------------------------------------------


async def test_an_unconfigured_provider_is_a_bare_404(world: World) -> None:
    for provider in ("resend", "postmark", "sendgrid"):
        response = await _post(world, f"/webhooks/email/{provider}", b"{}", {})
        assert response.status_code == 404, provider
        assert response.content == b""


@PROVIDERS
async def test_a_bad_signature_a_stale_timestamp_and_a_wrong_password_change_nothing(
    world: World,
) -> None:
    person, notification_id, message_id = await _alerted(world)
    body = resend_event("email.bounced", message_id, bounce={"type": "Permanent"})

    raw, headers = svix(world, body, msg_id="msg_1")
    headers["svix-signature"] = "v1," + base64.b64encode(b"x" * 32).decode()
    assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 401

    raw, headers = svix(world, body, msg_id="msg_2", age=3600)
    assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 401

    raw, headers = svix(
        world, body, msg_id="msg_3", secret="whsec_" + base64.b64encode(b"y" * 32).decode()
    )
    assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 401

    wrong = base64.b64encode(b"postmark:not-the-password").decode()
    assert (
        await _post(
            world,
            "/webhooks/email/postmark",
            b"{}",
            {"authorization": f"Basic {wrong}"},
        )
    ).status_code == 401
    assert (await _post(world, "/webhooks/email/postmark", b"{}", {})).status_code == 401

    assert _logs(world, notification_id) == []
    contact = world.db.execute(
        "SELECT verification_status FROM trusted_contacts WHERE id = %s", (person.contacts["Mom"],)
    ).fetchone()
    assert contact == {"verification_status": "verified"}


# --- what a good event does -------------------------------------------------------------------


@PROVIDERS
async def test_delivery_is_logged_once_however_often_the_webhook_is_delivered(
    world: World,
) -> None:
    _, notification_id, message_id = await _alerted(world)
    raw, headers = svix(world, resend_event("email.delivered", message_id), msg_id="msg_d1")
    for _ in range(3):
        assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 204
    assert _logs(world, notification_id) == [
        {
            "outcome": "delivered",
            "error_code": None,
            "provider": "resend",
            "provider_event_id": "msg_d1",
        }
    ]


@PROVIDERS
async def test_a_hard_bounce_suppresses_the_address_marks_the_contact_and_tells_the_person(
    world: World,
) -> None:
    person, notification_id, message_id = await _alerted(world)
    # a later message to the same contact is still waiting
    world.db.execute(
        "INSERT INTO notifications (user_id, audience, category, contact_id, channel, "
        "template_key, send_after, dedupe_key) VALUES (%s, 'contact', 'contact_other', %s, "
        "'email', 'contact_all_clear', now() + interval '1 day', 'queued-later-1')",
        (person.user_id, person.contacts["Mom"]),
    )
    raw, headers = svix(
        world,
        resend_event(
            "email.bounced", message_id, bounce={"type": "Permanent", "subType": "General"}
        ),
        msg_id="msg_b1",
    )
    assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 204

    assert _logs(world, notification_id)[0]["outcome"] == "bounced"
    contact = world.db.execute(
        "SELECT verification_status FROM trusted_contacts WHERE id = %s", (person.contacts["Mom"],)
    ).fetchone()
    assert contact == {"verification_status": "bounced"}
    assert world.db.execute("SELECT reason FROM email_suppressions").fetchall() == [
        {"reason": "hard_bounce"}
    ]
    later = world.db.execute(
        "SELECT status, cancelled_reason FROM notifications WHERE dedupe_key = 'queued-later-1'"
    ).fetchone()
    assert later == {"status": "cancelled", "cancelled_reason": "contact_unreachable"}

    await world.advance(minutes=5)  # the dispatcher sends the notice
    [notice] = world.mail.to(person.email, "contact_unreachable")
    assert "message came back as undeliverable" in notice.text
    row = world.db.execute(
        "SELECT user_visible FROM audit_logs WHERE action = 'contact.bounced'"
    ).fetchone()
    assert row == {"user_visible": True}

    # a repeat of the same event does not tell the person twice
    assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 204
    await world.advance(minutes=5)
    assert len(world.mail.to(person.email, "contact_unreachable")) == 1


@PROVIDERS
async def test_a_soft_bounce_and_unrelated_events_are_logged_or_ignored_not_acted_on(
    world: World,
) -> None:
    person, notification_id, message_id = await _alerted(world)
    soft = resend_event("email.bounced", message_id, bounce={"type": "Transient"})
    raw, headers = svix(world, soft, msg_id="msg_s1")
    assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 204
    assert _logs(world, notification_id)[0]["outcome"] == "error"
    assert _logs(world, notification_id)[0]["error_code"] == "bounce_transient"

    for kind, msg_id in (("email.opened", "msg_o"), ("email.sent", "msg_sent")):
        raw, headers = svix(world, resend_event(kind, message_id), msg_id=msg_id)
        assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 204

    raw, headers = svix(world, resend_event("email.delivered", "re_unknown"), msg_id="msg_u")
    assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 204

    assert len(_logs(world, notification_id)) == 1
    contact = world.db.execute(
        "SELECT verification_status FROM trusted_contacts WHERE id = %s", (person.contacts["Mom"],)
    ).fetchone()
    assert contact == {"verification_status": "verified"}
    assert world.db.execute("SELECT 1 FROM email_suppressions").fetchall() == []


@PROVIDERS
async def test_a_complaint_blocks_the_address_everywhere_and_tells_every_owner(
    world: World,
) -> None:
    person, notification_id, message_id = await _alerted(world)
    # another account lists the same person
    other = await world.person("other.owner@example.com")
    shared = address(person, "Mom")
    created = await world.h.client.post(
        "/v1/contacts",
        json={"display_name": "Her", "relationship": "friend", "email": shared},
        headers=other.headers,
    )
    assert created.status_code == 201, created.text

    raw, headers = svix(world, resend_event("email.complained", message_id), msg_id="msg_c1")
    assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 204

    statuses = world.db.execute(
        "SELECT verification_status FROM trusted_contacts WHERE email_normalized IS NULL OR "
        "deleted_at IS NULL ORDER BY created_at"
    ).fetchall()
    assert {r["verification_status"] for r in statuses} == {"opted_out"}
    assert world.db.execute("SELECT reason FROM email_suppressions").fetchall() == [
        {"reason": "complaint"}
    ]
    assert _logs(world, notification_id)[0]["outcome"] == "complained"
    await world.advance(minutes=5)
    assert len(world.mail.to(person.email, "contact_unreachable")) == 1
    assert len(world.mail.to(other.email, "contact_unreachable")) == 1


@PROVIDERS
async def test_a_bounce_of_the_persons_own_reminder_is_only_logged(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=1))
    row = world.db.execute(
        "SELECT id FROM notifications WHERE user_id = %s AND template_key = 'incident_missed' "
        "AND channel = 'email'",
        (person.user_id,),
    ).fetchone()
    assert row is not None
    world.db.execute(
        "UPDATE notifications SET provider = 'resend', provider_message_id = 're_user_1' "
        "WHERE id = %s",
        (row["id"],),
    )
    raw, headers = svix(
        world,
        resend_event("email.bounced", "re_user_1", bounce={"type": "Permanent"}),
        msg_id="msg_user",
    )
    assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 204
    assert _logs(world, str(row["id"]))[0]["outcome"] == "bounced"
    assert world.mail.to(person.email, "contact_unreachable") == []


@PROVIDERS
async def test_postmark_events_arrive_with_basic_auth_and_find_their_message(
    world: World,
) -> None:
    person, notification_id, _ = await _alerted(world)
    world.db.execute(
        "UPDATE notifications SET provider = 'postmark', provider_message_id = 'pm-0001' "
        "WHERE id = %s",
        (notification_id,),
    )
    auth = base64.b64encode(f"postmark:{POSTMARK_SECRET}".encode()).decode()
    headers = {"authorization": f"Basic {auth}", "content-type": "application/json"}
    bounce = {
        "RecordType": "Bounce",
        "ID": 4323372036854775807,
        "Type": "HardBounce",
        "MessageID": "pm-0001",
        "Email": address(person, "Mom"),
    }
    response = await world.h.client.post(
        "/webhooks/email/postmark", content=json.dumps(bounce).encode(), headers=headers
    )
    assert response.status_code == 204
    contact = world.db.execute(
        "SELECT verification_status FROM trusted_contacts WHERE id = %s", (person.contacts["Mom"],)
    ).fetchone()
    assert contact == {"verification_status": "bounced"}
    assert _logs(world, notification_id)[0]["provider"] == "postmark"

    garbled = await world.h.client.post(
        "/webhooks/email/postmark", content=b"not json", headers=headers
    )
    assert garbled.status_code == 400


@PROVIDERS
async def test_a_block_by_the_receiving_isp_is_not_a_verdict_on_the_contact(world: World) -> None:
    person, notification_id, _ = await _alerted(world)
    world.db.execute(
        "UPDATE notifications SET provider = 'postmark', provider_message_id = 'pm-block' "
        "WHERE id = %s",
        (notification_id,),
    )
    auth = base64.b64encode(f"postmark:{POSTMARK_SECRET}".encode()).decode()
    blocked = {"RecordType": "Bounce", "ID": 91, "Type": "Blocked", "MessageID": "pm-block"}
    response = await world.h.client.post(
        "/webhooks/email/postmark",
        content=json.dumps(blocked).encode(),
        headers={"authorization": f"Basic {auth}", "content-type": "application/json"},
    )
    assert response.status_code == 204
    contact = world.db.execute(
        "SELECT verification_status FROM trusted_contacts WHERE id = %s", (person.contacts["Mom"],)
    ).fetchone()
    assert contact == {"verification_status": "verified"}
    assert world.db.execute("SELECT 1 FROM email_suppressions").fetchall() == []
    assert _logs(world, notification_id)[0]["outcome"] == "error"


# --- the review's cases ----------------------------------------------------------------------


@PROVIDERS
async def test_a_hard_bounce_marks_every_account_that_lists_the_address(world: World) -> None:
    person, _, message_id = await _alerted(world)
    other = await world.person("other.owner@example.com")
    shared = address(person, "Mom")
    created = await world.h.client.post(
        "/v1/contacts",
        json={"display_name": "Her", "relationship": "friend", "email": shared},
        headers=other.headers,
    )
    assert created.status_code == 201, created.text
    raw, headers = svix(
        world,
        resend_event("email.bounced", message_id, to=[shared], bounce={"type": "Permanent"}),
        msg_id="msg_all",
    )
    assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 204
    rows = world.db.execute(
        "SELECT verification_status FROM trusted_contacts WHERE email_normalized = %s", (shared,)
    ).fetchall()
    assert {r["verification_status"] for r in rows} == {"bounced"}
    await world.advance(minutes=5)
    assert len(world.mail.to(person.email, "contact_unreachable")) == 1
    assert len(world.mail.to(other.email, "contact_unreachable")) == 1


@PROVIDERS
async def test_a_late_event_about_an_address_the_contact_no_longer_has_changes_nothing(
    world: World,
) -> None:
    person, _, message_id = await _alerted(world)
    old_address = address(person, "Mom")
    world.db.execute(
        "UPDATE trusted_contacts SET email = 'fixed@example.com', "
        "email_normalized = 'fixed@example.com', verification_status = 'pending' WHERE id = %s",
        (person.contacts["Mom"],),
    )
    raw, headers = svix(
        world,
        resend_event("email.bounced", message_id, to=[old_address], bounce={"type": "Permanent"}),
        msg_id="msg_late",
    )
    assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 204
    contact = world.db.execute(
        "SELECT verification_status FROM trusted_contacts WHERE id = %s", (person.contacts["Mom"],)
    ).fetchone()
    assert contact == {"verification_status": "pending"}  # not marked bounced
    assert world.db.execute("SELECT 1 FROM email_suppressions").fetchall() == []
    await world.advance(minutes=5)
    assert world.mail.to(person.email, "contact_unreachable") == []


@PROVIDERS
async def test_an_event_that_outran_the_message_id_is_found_by_the_notification_id_tag(
    world: World,
) -> None:
    person, notification_id, _ = await _alerted(world)
    world.db.execute(
        "UPDATE notifications SET provider_message_id = NULL WHERE id = %s", (notification_id,)
    )
    raw, headers = svix(
        world,
        resend_event(
            "email.bounced",
            "re_not_stored_yet",
            to=[address(person, "Mom")],
            bounce={"type": "Permanent"},
            tags={"notification_id": notification_id},
        ),
        msg_id="msg_early",
    )
    assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 204
    assert _logs(world, notification_id)[0]["outcome"] == "bounced"
    contact = world.db.execute(
        "SELECT verification_status FROM trusted_contacts WHERE id = %s", (person.contacts["Mom"],)
    ).fetchone()
    assert contact == {"verification_status": "bounced"}


@PROVIDERS
async def test_a_provider_that_gave_up_or_suppressed_is_reported_to_the_person(
    world: World,
) -> None:
    """Accepted by the provider is not delivered: a failure after acceptance is not silent."""
    person, _, message_id = await _alerted(world)
    for kind, msg_id in (("email.failed", "msg_f"), ("email.suppressed", "msg_s")):
        raw, headers = svix(world, resend_event(kind, message_id), msg_id=msg_id)
        assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 204
    await world.advance(minutes=5)
    [notice] = world.mail.to(person.email, "contact_unreachable")  # once per contact and day
    assert "could not be delivered" in notice.text
    contact = world.db.execute(
        "SELECT verification_status FROM trusted_contacts WHERE id = %s", (person.contacts["Mom"],)
    ).fetchone()
    assert contact == {"verification_status": "verified"}  # the contact is not blamed


@PROVIDERS
async def test_a_soft_bounce_reaches_the_person_but_leaves_the_contact(world: World) -> None:
    person, _, message_id = await _alerted(world)
    raw, headers = svix(
        world,
        resend_event("email.bounced", message_id, bounce={"type": "Transient"}),
        msg_id="msg_soft",
    )
    assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 204
    await world.advance(minutes=5)
    assert len(world.mail.to(person.email, "contact_unreachable")) == 1
    assert world.db.execute("SELECT 1 FROM email_suppressions").fetchall() == []


@PROVIDERS
async def test_a_bounce_of_an_invitation_marks_the_contact_through_its_receipt(
    world: World,
) -> None:
    person = await world.person("inviter@example.com")
    contact = await world.contact(person, "Mom")
    row = world.db.execute(
        "SELECT user_id FROM trusted_contacts WHERE id = %s", (contact,)
    ).fetchone()
    assert row is not None
    world.db.execute(
        "INSERT INTO email_receipts (user_id, contact_id, template_key, provider, "
        "provider_message_id) VALUES (%s, %s, 'contact_invitation', 'resend', 're_invite_1')",
        (person.user_id, person.contacts["Mom"]),
    )
    raw, headers = svix(
        world,
        resend_event("email.bounced", "re_invite_1", bounce={"type": "Permanent"}),
        msg_id="msg_inv",
    )
    assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 204
    status = world.db.execute(
        "SELECT verification_status FROM trusted_contacts WHERE id = %s", (person.contacts["Mom"],)
    ).fetchone()
    assert status == {"verification_status": "bounced"}
    # a repeat changes nothing and tells nobody twice
    assert (await _post(world, "/webhooks/email/resend", raw, headers)).status_code == 204
    await world.advance(minutes=5)
    assert len(world.mail.to(person.email, "contact_unreachable")) == 1


@PROVIDERS
async def test_a_non_ascii_signature_is_a_401_not_a_500(world: World) -> None:
    raw = b"{}"
    stamp = str(int(world.clock.current.timestamp()))
    response = await world.h.client.post(
        "/webhooks/email/resend",
        content=raw,
        headers=[
            (b"svix-id", b"msg_x"),
            (b"svix-timestamp", stamp.encode()),
            (b"svix-signature", "v1,éè".encode()),
        ],
    )
    assert response.status_code == 401
