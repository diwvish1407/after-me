"""SEC-25 over the whole product lifecycle (SECURITY §10; TEST_PLAN §5.2).

``test_log_leak.py`` covers sign-up, contacts, the recipient pages and check-ins one flow at a
time. This runs one person through everything that came after: a phone registering its push
token, the lost-phone pages, a missed check-in, an alert and a release, a contact reading the
instruction with a one-time code, a provider's bounce webhook (signed, replayed and forged), I'M
SAFE, the export, the deletion and the purge. Every record is rendered by the production JSON
formatter at DEBUG level, third-party loggers included, and nothing a person would be harmed by
may be in it. The tables that are read by operators are held to the same standard.
"""

from __future__ import annotations

import io
import logging
import re
from collections.abc import Iterator
from datetime import timedelta

import pytest

from app.core.logging import build_formatter
from app.maintenance.accounts import purge_due_accounts
from tests.engine.test_deletion import _as_owner, _delete
from tests.engine.test_release import BODY, TITLE, Portal, _link_token, _setup, address
from tests.engine.test_web_checkin import _sign_in
from tests.engine.test_webhooks import (
    POSTMARK_SECRET,
    PROVIDERS,
    WHSEC,
    resend_event,
    svix,
)
from tests.support import DEVICE, PASSWORD
from tests.world import World, ist

DUE = ist("2026-10-09T20:00")
STAGE_2 = DUE + timedelta(minutes=1440)
PUSH_TOKEN = "fcm-lifecycle-token-0123456789abcdefXYZ"
EMAIL_ADDRESS = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")


@pytest.fixture
def captured_logs() -> Iterator[io.StringIO]:
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(build_formatter(json=True))
    handler.setLevel(logging.DEBUG)
    root = logging.getLogger()
    previous_level = root.level
    root.addHandler(handler)
    root.setLevel(logging.DEBUG)
    try:
        yield stream
    finally:
        root.removeHandler(handler)
        root.setLevel(previous_level)


def _standalone(value: str) -> re.Pattern[str]:
    return re.compile(rf"(?<![\w.:+-]){re.escape(value)}(?![\w])")


def _stored_text(world: World) -> str:
    """Everything an operator can read without decrypting anything."""
    queries = (
        "SELECT metadata, request_id FROM audit_logs",
        "SELECT params, template_key, cancelled_reason FROM notifications",
        "SELECT error_code, provider_event_id FROM notification_logs",
        "SELECT key FROM rate_limit_counters",
        "SELECT reason FROM email_suppressions",
    )
    return "\n".join(str(world.db.execute(q).fetchall()) for q in queries)


@PROVIDERS
async def test_a_whole_lifecycle_leaks_nothing_to_the_logs_or_the_operator_tables(
    world: World, captured_logs: io.StringIO
) -> None:
    person = await _setup(world)
    mom, brother = address(person, "Mom"), address(person, "Brother")
    seen_tokens: list[str] = []

    def remember() -> None:
        seen_tokens.extend([person.tokens["access_token"], person.tokens["refresh_token"]])

    await world.login(person)
    remember()

    # the phone registers its push token; the lost-phone pages are used from a browser
    registered = await world.h.client.put(
        "/v1/devices/current", json={**DEVICE, "push_token": PUSH_TOKEN}, headers=person.headers
    )
    assert registered.status_code == 200, registered.text
    assert (await _sign_in(world, person)).status_code == 303
    assert (await world.h.client.get("/a/checkin")).status_code == 200
    web_values = [
        cookie.value
        for cookie in world.h.client.cookies.jar
        if cookie.name.startswith("__Host-afterme_")
    ]
    assert web_values, "the lost-phone sign-in set no cookie"
    world.h.client.cookies.clear()

    # the person misses everything; the first contact is told, then the instruction is released
    await world.advance_to(STAGE_2 + timedelta(minutes=6))
    alert = world.db.execute(
        "SELECT id FROM notifications WHERE user_id = %s AND template_key = 'contact_alert'",
        (person.user_id,),
    ).fetchone()
    assert alert is not None
    world.db.execute(
        "UPDATE notifications SET provider = 'resend', provider_message_id = 're_lifecycle_0001' "
        "WHERE id = %s",
        (alert["id"],),
    )

    # the contact reads it with a one-time code
    portal = Portal(world)
    link_token = _link_token(world, person)
    shown = await portal.reach_content(person)
    assert TITLE in shown.text
    code = portal.last_code(person)

    # the provider reports a hard bounce: signed, replayed, forged
    raw, headers = svix(
        world,
        resend_event("email.bounced", "re_lifecycle_0001", bounce={"type": "Permanent"}),
        msg_id="msg_lifecycle_0001",
    )
    first = await world.h.client.post("/webhooks/email/resend", content=raw, headers=headers)
    assert first.status_code == 204, first.text
    replay = await world.h.client.post("/webhooks/email/resend", content=raw, headers=headers)
    assert replay.status_code == 204
    forged = await world.h.client.post(
        "/webhooks/email/resend",
        content=raw,
        headers={**headers, "svix-signature": "v1,AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="},
    )
    assert forged.status_code == 401
    await world.tick()

    # the person comes back: I'M SAFE, then the export, then the deletion
    incident = world.open_incident(person)
    assert incident is not None
    await world.safe(person, str(incident["id"]))
    remember()
    await world.tick()
    exported = await world.call(person, "POST", "/v1/me/export")
    assert exported.status_code == 403  # no fresh password yet: the refusal is logged too
    assert (await world.h.reauth(person.tokens)).status_code == 204
    exported = await world.h.client.post("/v1/me/export", headers=person.headers)
    assert exported.status_code == 200, exported.text
    assert (await _delete(world, person)).status_code == 202
    remember()
    await world.advance(minutes=10)
    stored_before_purge = _stored_text(world)
    async with _as_owner(world) as session:
        removed = await purge_due_accounts(
            session,
            world.engine.services.audit,
            now=world.clock.current + timedelta(days=30, minutes=1),
            retention_days=30,
        )
    assert [str(i) for i in removed] == [person.user_id]

    output = captured_logs.getvalue()
    assert "http.request" in output  # the capture really saw the access log
    assert "incident.opened" in output
    assert person.user_id in output  # positive control: identifiers are what logs are for
    # a sanity floor (httpx's own per-request line is no longer logged: it carried the URL)
    assert output.count("\n") >= 30

    web_ids = [v for v in web_values if len(v) >= 16]
    forbidden = [
        PASSWORD,
        person.email,
        mom,
        brother,
        TITLE,
        "Sharma",
        "spare key",
        BODY.splitlines()[0],
        PUSH_TOKEN,
        link_token,
        link_token.removeprefix("rt_"),
        WHSEC,
        WHSEC.removeprefix("whsec_"),
        POSTMARK_SECRET,
        "re_test_key_00000000",
        "pm_test_key_00000000",
        headers["svix-signature"],
        headers["svix-signature"].removeprefix("v1,"),
        *seen_tokens,
        *web_ids,
    ]
    for value in forbidden:
        assert value not in output, f"sensitive value leaked into logs: {value[:12]}…"
    assert not _standalone(code).search(output), "the one-time code leaked into logs"
    for label in ("Mom", "Brother"):
        assert not _standalone(label).search(output), f"contact name leaked: {label}"
    assert "Bearer " not in output
    assert not re.search(r"eyJ[A-Za-z0-9_-]{10,}\.", output), "a JWT reached the logs"
    assert not re.search(r"\b(?:rt|ci|oo|pr|ad|rf)_[A-Za-z0-9_-]{20,}", output), "a link token"
    assert "svix-signature" not in output.lower()
    assert "set-cookie" not in output.lower()
    assert "__Host-afterme_web" not in output

    # the only address that may appear is the one AfterMe sends from
    sender = world.h.settings.email_from.lower()
    for found in EMAIL_ADDRESS.findall(output):
        assert found.lower() in sender, f"an address reached the logs: {found[:6]}…"

    # what an operator can read: identifiers, reason codes and counts, never content
    stored = stored_before_purge + "\n" + _stored_text(world)
    for value in (
        PASSWORD,
        TITLE,
        "Sharma",
        PUSH_TOKEN,
        link_token,
        code,
        mom,
        brother,
        person.email,
    ):
        assert value not in stored, f"sensitive value in an operator table: {value[:12]}…"
    assert "@" not in stored
