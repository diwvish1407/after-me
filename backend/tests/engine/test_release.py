"""Release and the recipient portal, end to end (TEST_PLAN ENG-LC-08, REL-01…15, SEC-12…16).

The real API, the real engine and dispatcher and the real ``/c/release`` pages, on the frozen
clock: an instruction is assigned to a contact at a late stage; the person misses their
check-ins; the stage releases it; the contact opens the link, gets a code and reads it; the
person returns and it disappears.
"""

from __future__ import annotations

import re
from datetime import timedelta
from typing import Any

import pytest

from tests.world import Person, World, ist

DUE = ist("2026-10-09T20:00")
STAGE_1 = DUE + timedelta(minutes=180)
STAGE_2 = DUE + timedelta(minutes=1440)
TITLE = "House emergency"
BODY = "The spare key is with Mrs. Sharma at flat 3B.\nCall her before you go."


def address(person: Person, label: str) -> str:
    return f"{label.lower()}.{person.user_id[:6]}@example.com"


async def _setup(world: World, *, to: tuple[str, ...] = ("Brother",), **extra: Any) -> Person:
    person = await world.ready(
        contacts=("Mom", "Brother"),
        stages=((180, ("Mom",)), (1440, ("Brother",))),
    )
    await world.login(person)
    # routing an instruction to someone, while check-ins are on, asks for the password
    assert (await world.h.reauth(person.tokens)).status_code == 204
    plan = await world.h.client.get("/v1/plan", headers=person.headers)
    stage_2 = plan.json()["stages"][1]["id"]
    made = await world.h.client.post(
        "/v1/instructions",
        json={
            "category": "home",
            "title": TITLE,
            "body": BODY,
            "recipients": [
                {"contact_id": person.contacts[label], "release_stage_id": stage_2} for label in to
            ],
            **extra,
        },
        headers=person.headers,
    )
    assert made.status_code == 201, made.text
    person.contacts["_instruction"] = made.json()["id"]
    return person


def _link_token(world: World, person: Person, label: str = "Brother") -> str:
    """The token in the newest release email sent to this contact."""
    to = address(person, label)
    mails = [
        m
        for m in world.mail.messages
        if m.to == to and m.template in ("contact_alert_with_release", "contact_release")
    ]
    assert mails, "no release email was sent"
    found = re.search(r"/c/release#(rt_[A-Za-z0-9_-]{43})", mails[-1].text)
    assert found is not None, mails[-1].text
    return found[1]


class Portal:
    def __init__(self, world: World) -> None:
        self.world = world
        self.client = world.h.client

    async def csrf(self) -> str:
        return await self.world.h.portal_csrf("/c/release")

    async def post(self, path: str, **fields: str) -> Any:
        value = fields.pop("csrf", None) or await self.csrf()
        return await self.client.post(path, data={"csrf": value, **fields})

    async def open(self, token: str) -> Any:
        return await self.post("/c/release/session", token=token)

    async def code(self) -> Any:
        return await self.post("/c/release/code")

    def last_code(self, person: Person, label: str = "Brother") -> str:
        mails = self.world.mail.to(address(person, label), "portal_code")
        found = re.search(r"Your code is (\d{6})", mails[-1].text)
        assert found is not None
        return found[1]

    async def verify(self, code: str) -> Any:
        return await self.post("/c/release/verify", code=code)

    async def reach_content(self, person: Person, label: str = "Brother") -> Any:
        opened = await self.open(_link_token(self.world, person, label))
        assert opened.status_code == 200, opened.text
        assert (await self.code()).status_code == 200
        return await self.verify(self.last_code(person, label))


async def _released(world: World) -> Person:
    person = await _setup(world)
    await world.advance_to(STAGE_2 + timedelta(minutes=6))
    return person


# --- the lifecycle with a real release view (ENG-LC-08) ---------------------------------------


async def test_a_released_instruction_is_read_by_the_contact_and_taken_back_on_i_am_safe(
    world: World,
) -> None:
    person = await _setup(world)
    await world.advance_to(STAGE_2 + timedelta(minutes=6))

    # the contact's email: an alert with a link, and nothing of the content in it
    alerts = world.mail.to(address(person, "Brother"), "contact_alert_with_release")
    assert len(alerts) == 1
    assert TITLE not in alerts[0].text
    assert "Sharma" not in alerts[0].text
    assert "/c/release#rt_" in alerts[0].text
    release = world.db.execute("SELECT * FROM release_events").fetchall()
    assert len(release) == 1
    assert release[0]["revoked_at"] is None
    assert release[0]["visible_after"] == STAGE_2 + timedelta(minutes=5)

    # the portal: link -> code -> content
    portal = Portal(world)
    shown = await portal.reach_content(person)
    assert shown.status_code == 200
    assert TITLE in shown.text
    assert "Mrs. Sharma at flat 3B." in shown.text
    assert person.email in shown.text
    row = world.db.execute("SELECT * FROM release_events").fetchone()
    assert row is not None
    assert row["view_count"] == 1
    assert row["first_viewed_at"] is not None
    viewed = world.db.execute("SELECT * FROM audit_logs WHERE action = 'release.viewed'").fetchall()
    assert len(viewed) == 1
    assert viewed[0]["actor_type"] == "contact"
    assert TITLE not in str(viewed[0]["metadata"])
    assert BODY not in str(viewed[0]["metadata"])

    # the person comes back: I'M OK is refused (contacts were told), I'M SAFE stops it all
    world.clock.set(STAGE_2 + timedelta(minutes=30))
    await world.checkin(person, expect=409)
    incident = world.open_incident(person)
    assert incident is not None
    await world.safe(person, str(incident["id"]))
    await world.tick()
    gone = await portal.post("/c/release/view")
    assert gone.status_code == 200
    assert "has checked in" in gone.text
    assert TITLE not in gone.text
    reopened = await portal.open(_link_token(world, person))
    assert reopened.status_code == 200
    assert "no longer available" in reopened.text
    assert TITLE not in reopened.text
    denied = world.db.execute(
        "SELECT metadata FROM audit_logs WHERE action = 'portal.access_denied'"
    ).fetchall()
    assert len(denied) >= 1  # a real link that was refused is on the record (no content)
    revoked = world.db.execute("SELECT revoked_at, revoke_reason FROM release_events").fetchone()
    assert revoked is not None
    assert revoked["revoke_reason"] == "user_safe"
    assert len(world.mail.to(address(person, "Brother"), "contact_all_clear")) == 1


async def test_a_check_in_before_anyone_was_told_leaves_no_release_at_all(world: World) -> None:
    person = await _setup(world, to=("Brother",))
    await world.advance_to(DUE + timedelta(minutes=10))
    await world.checkin(person)
    await world.advance_to(STAGE_2 + timedelta(minutes=10))
    assert world.mail.to(address(person, "Brother"), "contact_alert_with_release") == []
    count = world.db.execute("SELECT count(*) AS n FROM release_events").fetchone()
    assert count is not None
    assert count["n"] == 0


# --- the link --------------------------------------------------------------------------------


async def test_the_landing_page_is_static_and_a_get_changes_nothing(world: World) -> None:
    person = await _released(world)
    token = _link_token(world, person)
    before = world.db.execute("SELECT count(*) AS n FROM portal_sessions").fetchone()
    response = await world.h.client.get("/c/release", params={"token": token})
    assert response.status_code == 200
    assert 'action="/c/release/session"' in response.text
    assert token not in response.text  # a token in the query string is never read or echoed
    assert 'data-prefix="rt_"' in response.text
    after = world.db.execute("SELECT count(*) AS n FROM portal_sessions").fetchone()
    assert before == after
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["x-robots-tag"] == "noindex, nofollow"


async def test_the_token_is_only_ever_stored_as_a_hash(world: World) -> None:
    person = await _released(world)
    token = _link_token(world, person)
    stored = world.db.execute("SELECT token_hash FROM portal_tokens").fetchall()
    assert len(stored) == 1
    raw = token.removeprefix("rt_").encode()
    assert raw not in bytes(stored[0]["token_hash"])
    assert len(bytes(stored[0]["token_hash"])) == 32  # SHA-256


@pytest.mark.parametrize("token", ["", "garbage", "rt_short", "ci_" + "A" * 43, "rt_" + "A" * 43])
async def test_an_unknown_or_malformed_token_gives_the_same_page(world: World, token: str) -> None:
    await _released(world)
    portal = Portal(world)
    response = await portal.open(token)
    assert response.status_code == 400
    assert "This link doesn't work" in response.text
    assert TITLE not in response.text


async def test_an_expired_link_offers_a_new_one_and_a_new_link_works(world: World) -> None:
    person = await _released(world)
    token = _link_token(world, person)
    world.clock.set(STAGE_2 + timedelta(days=31))
    world.db.execute("UPDATE portal_tokens SET expires_at = %s", (STAGE_2 + timedelta(days=30),))
    portal = Portal(world)
    expired = await portal.open(token)
    assert expired.status_code == 400
    assert 'action="/c/release/new-link"' in expired.text
    asked = await portal.post("/c/release/new-link", token=token)
    assert asked.status_code == 200
    assert "Check your email" in asked.text
    await world.tick()
    fresh = world.mail.to(address(person, "Brother"), "contact_release")
    assert len(fresh) == 1
    new_token = _link_token(world, person)
    assert new_token != token
    shown = await portal.open(new_token)
    assert shown.status_code == 200


async def test_a_new_link_for_an_unknown_token_says_the_same_and_sends_nothing(
    world: World,
) -> None:
    person = await _released(world)
    portal = Portal(world)
    asked = await portal.post("/c/release/new-link", token="rt_" + "B" * 43)
    assert asked.status_code == 200
    assert "Check your email" in asked.text
    await world.tick()
    assert world.mail.to(address(person, "Brother"), "contact_release") == []


# --- the code --------------------------------------------------------------------------------


async def test_no_content_without_the_code(world: World) -> None:
    person = await _released(world)
    portal = Portal(world)
    opened = await portal.open(_link_token(world, person))
    assert opened.status_code == 200
    assert TITLE not in opened.text
    assert "b***@example.com" in opened.text  # the address is masked
    sent = await portal.code()
    assert TITLE not in sent.text
    skipped = await portal.post("/c/release/view")
    assert TITLE not in skipped.text  # the code step has not been done: asked again
    assert "Send me a code" in skipped.text


async def test_the_code_email_goes_to_the_verified_address_and_holds_no_content(
    world: World,
) -> None:
    person = await _released(world)
    portal = Portal(world)
    await portal.open(_link_token(world, person))
    await portal.code()
    mails = world.mail.to(address(person, "Brother"), "portal_code")
    assert len(mails) == 1
    assert re.search(r"Your code is \d{6}", mails[0].text)
    assert TITLE not in mails[0].text
    assert "Sharma" not in mails[0].text
    stored = world.db.execute("SELECT code_hash FROM portal_otp_challenges").fetchone()
    assert stored is not None
    assert portal.last_code(person).encode() not in bytes(stored["code_hash"])


async def test_five_wrong_codes_lock_the_challenge_and_the_sixth_is_refused(
    world: World,
) -> None:
    person = await _released(world)
    portal = Portal(world)
    await portal.open(_link_token(world, person))
    await portal.code()
    real = portal.last_code(person)
    wrong = "000000" if real != "000000" else "111111"
    for _ in range(5):
        response = await portal.verify(wrong)
        assert response.status_code == 400
        assert "isn&#39;t right" in response.text
    locked = await portal.verify(real)  # even the right code, now
    assert locked.status_code == 400
    assert "Too many wrong codes" in locked.text
    assert TITLE not in locked.text


async def test_a_fourth_code_in_an_hour_is_refused(world: World) -> None:
    person = await _released(world)
    portal = Portal(world)
    await portal.open(_link_token(world, person))
    for _ in range(3):
        assert (await portal.code()).status_code == 200
    refused = await portal.code()
    assert refused.status_code == 429
    assert len(world.mail.to(address(person, "Brother"), "portal_code")) == 3


async def test_a_new_code_replaces_the_old_one(world: World) -> None:
    person = await _released(world)
    portal = Portal(world)
    await portal.open(_link_token(world, person))
    await portal.code()
    first = portal.last_code(person)
    await portal.code()
    second = portal.last_code(person)
    if first != second:
        assert (await portal.verify(first)).status_code == 400
    assert (await portal.verify(second)).status_code == 200


async def test_an_expired_code_is_refused(world: World) -> None:
    person = await _released(world)
    portal = Portal(world)
    await portal.open(_link_token(world, person))
    await portal.code()
    code = portal.last_code(person)
    world.clock.advance(minutes=11)
    expired = await portal.verify(code)
    assert expired.status_code == 400
    assert "expired" in expired.text


async def test_the_verified_session_lasts_fifteen_minutes(world: World) -> None:
    person = await _released(world)
    portal = Portal(world)
    assert (await portal.reach_content(person)).status_code == 200
    world.clock.advance(minutes=14)
    again = await portal.post("/c/release/view")
    assert TITLE in again.text
    world.clock.advance(minutes=2)  # 16 minutes after the code
    asked = await portal.post("/c/release/view")
    assert TITLE not in asked.text
    assert "Send me a code" in asked.text


async def test_a_session_ends_after_an_hour(world: World) -> None:
    person = await _released(world)
    portal = Portal(world)
    await portal.reach_content(person)
    world.clock.advance(minutes=61)
    response = await portal.post("/c/release/view")
    assert response.status_code == 400


# --- what is visible -------------------------------------------------------------------------


async def test_a_release_is_not_visible_before_its_settle_delay(world: World) -> None:
    person = await _released(world)
    world.db.execute(
        "UPDATE release_events SET visible_after = %s", (world.clock.current + timedelta(hours=1),)
    )
    portal = Portal(world)
    shown = await portal.reach_content(person)
    assert shown.status_code == 200
    assert TITLE not in shown.text
    assert "Not available yet" in shown.text


async def test_a_release_created_inside_a_hold_window_is_hidden(world: World) -> None:
    person = await _released(world)
    created = world.db.execute("SELECT released_at FROM release_events").fetchone()
    assert created is not None
    world.db.execute(
        "INSERT INTO system_holds (reason, started_at, detected_at, created_by) "
        "VALUES ('operator', %s, %s, 'test')",
        (created["released_at"] - timedelta(minutes=1), world.clock.current),
    )
    portal = Portal(world)
    shown = await portal.reach_content(person)
    assert TITLE not in shown.text


async def test_text_is_escaped_in_the_page(world: World) -> None:
    person = await world.ready(
        contacts=("Mom", "Brother"), stages=((180, ("Mom",)), (1440, ("Brother",)))
    )
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    plan = await world.h.client.get("/v1/plan", headers=person.headers)
    made = await world.h.client.post(
        "/v1/instructions",
        json={
            "category": "home",
            "title": "<script>alert(1)</script>",
            "body": '<img src=x onerror=alert(2)> & "quotes"',
            "recipients": [
                {
                    "contact_id": person.contacts["Brother"],
                    "release_stage_id": plan.json()["stages"][1]["id"],
                }
            ],
        },
        headers=person.headers,
    )
    assert made.status_code == 201
    await world.advance_to(STAGE_2 + timedelta(minutes=6))
    shown = await Portal(world).reach_content(person)
    assert "<script>alert(1)</script>" not in shown.text
    assert "&lt;script&gt;alert(1)&lt;/script&gt;" in shown.text
    assert "<img src=x" not in shown.text
    assert "&lt;img src=x onerror=alert(2)&gt;" in shown.text


# --- taking it back --------------------------------------------------------------------------


async def test_changes_by_the_person_during_an_incident_take_the_release_back(
    world: World,
) -> None:
    person = await _released(world)
    portal = Portal(world)
    assert TITLE in (await portal.reach_content(person)).text

    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    switched = await world.h.client.patch(
        f"/v1/instructions/{person.contacts['_instruction']}",
        json={"status": "inactive"},
        headers=person.headers,
    )
    assert switched.status_code == 200
    gone = await portal.post("/c/release/view")
    assert TITLE not in gone.text
    assert "no longer available" in gone.text
    row = world.db.execute("SELECT revoke_reason FROM release_events").fetchone()
    assert row is not None
    assert row["revoke_reason"] == "instruction_removed"


async def test_removing_the_recipient_takes_the_release_back(world: World) -> None:
    person = await _released(world)
    portal = Portal(world)
    assert TITLE in (await portal.reach_content(person)).text
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    response = await world.h.client.patch(
        f"/v1/instructions/{person.contacts['_instruction']}",
        json={"recipients": []},
        headers=person.headers,
    )
    assert response.status_code == 200
    assert "no longer available" in (await portal.post("/c/release/view")).text


async def test_deleting_the_contact_takes_the_release_back(world: World) -> None:
    person = await _released(world)
    portal = Portal(world)
    assert TITLE in (await portal.reach_content(person)).text
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    deleted = await world.h.client.delete(
        f"/v1/contacts/{person.contacts['Brother']}", headers=person.headers
    )
    assert deleted.status_code == 204
    assert (await portal.post("/c/release/view")).status_code == 400
    row = world.db.execute("SELECT revoke_reason FROM release_events").fetchone()
    assert row is not None
    assert row["revoke_reason"] == "contact_removed"


async def test_an_opt_out_takes_the_release_back(world: World) -> None:
    import uuid

    from app.contacts.tokens import new_optout_token

    person = await _released(world)
    portal = Portal(world)
    assert TITLE in (await portal.reach_content(person)).text
    contact = world.db.execute(
        "SELECT email_normalized FROM trusted_contacts WHERE id = %s",
        (person.contacts["Brother"],),
    ).fetchone()
    assert contact is not None
    token = new_optout_token(
        world.engine.services.pepper,
        uuid.UUID(person.contacts["Brother"]),
        contact["email_normalized"],
    )
    response = await world.h.client.post(
        "/c/optout",
        data={"token": token, "scope": "this_person", "csrf": await world.h.portal_csrf()},
    )
    assert response.status_code == 200, response.text
    assert (await portal.post("/c/release/view")).status_code == 400
    row = world.db.execute("SELECT revoke_reason FROM release_events").fetchone()
    assert row is not None
    assert row["revoke_reason"] == "contact_opted_out"


async def test_a_contact_who_is_no_longer_verified_cannot_open_it(world: World) -> None:
    person = await _released(world)
    world.db.execute(
        "UPDATE trusted_contacts SET verification_status = 'pending' WHERE id = %s",
        (person.contacts["Brother"],),
    )
    response = await Portal(world).open(_link_token(world, person))
    assert response.status_code == 400


async def test_a_hold_rollback_takes_the_release_back_and_the_rerun_restores_it(
    world: World,
) -> None:
    from app.ops import admin

    person = await _setup(world)
    await world.advance_to(STAGE_2)  # the stage ran; the message waits out the settle delay
    count = world.db.execute("SELECT count(*) AS n FROM release_events").fetchone()
    assert count is not None
    assert count["n"] == 1
    world.clock.set(STAGE_2 + timedelta(minutes=2))
    await admin.hold_enter(world.engine.services, operator="alex", reason="investigating")
    await world.advance_to(STAGE_2 + timedelta(minutes=62))
    assert await admin.hold_exit(world.engine.services, operator="alex") == 1
    await world.tick()
    rolled = world.db.execute("SELECT revoke_reason FROM release_events").fetchone()
    assert rolled is not None
    assert rolled["revoke_reason"] == "hold_rollback"
    assert world.mail.to(address(person, "Brother"), "contact_alert_with_release") == []

    await world.advance_to(STAGE_2 + timedelta(minutes=100))  # the stage runs again
    row = world.db.execute("SELECT revoked_at, revoke_reason FROM release_events").fetchone()
    assert row is not None
    assert row["revoked_at"] is None  # back, for the same release row
    assert len(world.mail.to(address(person, "Brother"), "contact_alert_with_release")) == 1


# --- protocol --------------------------------------------------------------------------------


async def test_every_post_needs_the_csrf_pair(world: World) -> None:
    person = await _released(world)
    token = _link_token(world, person)
    no_cookie_client = world.h.client
    no_cookie_client.cookies.clear()
    refused = await no_cookie_client.post(
        "/c/release/session", data={"token": token, "csrf": "x" * 43}
    )
    assert refused.status_code == 403
    portal = Portal(world)
    await portal.open(token)
    wrong = await world.h.client.post("/c/release/code", data={"csrf": "y" * 43})
    assert wrong.status_code == 403
    assert world.mail.to(address(person, "Brother"), "portal_code") == []


async def test_the_session_cookie_is_host_only_and_http_only(world: World) -> None:
    person = await _released(world)
    portal = Portal(world)
    response = await portal.open(_link_token(world, person))
    cookies = [c for c in response.headers.get_list("set-cookie") if "afterme_portal" in c]
    assert len(cookies) == 1
    cookie = cookies[0]
    assert cookie.startswith("__Host-afterme_portal=")
    for attribute in ("secure", "httponly", "samesite=strict", "path=/"):
        assert attribute in cookie.lower()
    assert "domain" not in cookie.lower()
    stored = world.db.execute("SELECT session_hash FROM portal_sessions").fetchone()
    assert stored is not None
    value = cookie.split("=", 1)[1].split(";", 1)[0]
    assert value.encode() not in bytes(stored["session_hash"])


# --- the database refuses what only the engine may do (SEC-18) -------------------------------


def _api() -> Any:
    import psycopg
    from psycopg.rows import dict_row

    from tests.support import API_PASSWORD, conninfo

    return psycopg.connect(
        conninfo("afterme_api", API_PASSWORD), autocommit=True, row_factory=dict_row
    )


async def test_the_api_role_cannot_create_releases_access_or_tokens(world: World) -> None:
    import psycopg

    person = await _released(world)
    release = world.db.execute("SELECT * FROM release_events").fetchone()
    assert release is not None
    with _api() as api:
        for statement, params in (
            (
                "INSERT INTO release_events (user_id, incident_id, action_id, instruction_id, "
                "contact_id, step_id, released_at, visible_after) "
                "VALUES (%s, %s, %s, %s, %s, %s, now(), now())",
                (
                    person.user_id,
                    release["incident_id"],
                    release["action_id"],
                    release["instruction_id"],
                    person.contacts["Mom"],
                    release["step_id"],
                ),
            ),
            (
                "INSERT INTO portal_access (user_id, incident_id, contact_id) VALUES (%s, %s, %s)",
                (person.user_id, release["incident_id"], person.contacts["Mom"]),
            ),
            (
                "INSERT INTO portal_tokens (access_id, token_hash, expires_at) "
                "SELECT id, 'x'::bytea, now() FROM portal_access",
                (),
            ),
        ):
            with pytest.raises(psycopg.errors.InsufficientPrivilege):
                api.execute(statement, params)


async def test_the_api_role_cannot_bring_a_revoked_release_back(world: World) -> None:
    import psycopg

    await _released(world)
    world.db.execute("UPDATE release_events SET revoked_at = now(), revoke_reason = 'user_safe'")
    world.db.execute("UPDATE portal_access SET revoked_at = now()")
    with _api() as api:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            api.execute("UPDATE release_events SET revoked_at = NULL, revoke_reason = NULL")
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            api.execute("UPDATE portal_access SET revoked_at = NULL")
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            api.execute("UPDATE release_events SET visible_after = now()")  # column not granted
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            api.execute("UPDATE portal_tokens SET expires_at = now() + interval '1 year'")


async def test_the_api_role_can_revoke_and_count_views(world: World) -> None:
    await _released(world)
    with _api() as api:
        api.execute("UPDATE release_events SET view_count = view_count + 1, last_viewed_at = now()")
        api.execute("UPDATE release_events SET revoked_at = now(), revoke_reason = 'operator'")
    row = world.db.execute("SELECT view_count, revoke_reason FROM release_events").fetchone()
    assert row is not None
    assert row["view_count"] == 1
    assert row["revoke_reason"] == "operator"


# --- nothing of the content leaves by any other door (SEC-20, SEC-25) ------------------------


async def test_no_notification_and_no_log_line_carries_the_content_a_link_or_a_code(
    world: World, caplog: pytest.LogCaptureFixture
) -> None:
    import logging

    caplog.set_level(logging.DEBUG)
    person = await _setup(world)
    await world.advance_to(STAGE_2 + timedelta(minutes=6))
    portal = Portal(world)
    token = _link_token(world, person)
    shown = await portal.reach_content(person)
    assert TITLE in shown.text
    code = portal.last_code(person)
    await world.tick()

    secrets_to_find = [
        TITLE,
        "Sharma",
        "spare key",
        token,
        token.removeprefix("rt_"),
        code,
        address(person, "Brother"),
        address(person, "Mom"),
    ]
    # the outbox rows and what was handed to the providers
    for row in world.db.execute("SELECT params, template_key FROM notifications").fetchall():
        text = str(row["params"])
        for secret in (TITLE, "Sharma", "spare key"):
            assert secret not in text, (row["template_key"], secret)
    for message in world.mail.messages:
        if message.template == "portal_code":
            continue  # carries the code, by design
        assert TITLE not in message.text, message.template
        assert "Sharma" not in message.text, message.template
    for push in world.push.messages:
        assert TITLE not in str(push)
        assert "Sharma" not in str(push)
    # every log line of the whole run
    log_text = "\n".join(
        r.getMessage() + " " + str(r.__dict__.get("event", "")) for r in caplog.records
    )
    for secret in secrets_to_find:
        assert secret not in log_text, secret
    # the audit trail holds identifiers and counts only
    audits = " ".join(
        str(r["metadata"]) for r in world.db.execute("SELECT metadata FROM audit_logs").fetchall()
    )
    for secret in (TITLE, "Sharma", token, code):
        assert secret not in audits


async def test_the_portal_does_not_rely_on_a_revocation_having_been_written(
    world: World,
) -> None:
    """Defence in depth: an incident closed by a path that forgot to revoke still shows nothing."""
    person = await _released(world)
    portal = Portal(world)
    shown = await portal.reach_content(person)
    assert TITLE in shown.text
    world.db.execute(
        "UPDATE escalation_incidents SET status = 'resolved', closed_at = now(), "
        "closed_by = 'user_checkin'"
    )
    open_releases = world.db.execute(
        "SELECT count(*) AS n FROM release_events WHERE revoked_at IS NULL"
    ).fetchone()
    assert open_releases is not None
    assert open_releases["n"] == 1
    gone = await portal.post("/c/release/view")
    assert TITLE not in gone.text
    reopened = await portal.open(_link_token(world, person))
    assert TITLE not in reopened.text


# --- what the independent review found (docs/ESCALATION_ENGINE.md §13.3) -------------------


async def _make(
    world: World,
    person: Person,
    label: str,
    title: str,
    body: str = "Some words.",
    *,
    status: str = "active",
) -> str:
    await world.login(person)
    # a route to someone, while check-ins are on, asks for the password
    assert (await world.h.reauth(person.tokens)).status_code == 204
    plan = await world.h.client.get("/v1/plan", headers=person.headers)
    made = await world.h.client.post(
        "/v1/instructions",
        json={
            "category": "home",
            "title": title,
            "body": body,
            "status": status,
            "recipients": [
                {
                    "contact_id": person.contacts[label],
                    "release_stage_id": plan.json()["stages"][1]["id"],
                }
            ],
        },
        headers=person.headers,
    )
    assert made.status_code == 201, made.text
    return str(made.json()["id"])


async def test_r1_a_failed_first_instruction_does_not_lose_the_next_ones_key(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The key is durable before anything is sealed with it: a request that fails after the
    key was made leaves the key, and what is sealed later opens with it, cold cache included."""
    import uuid

    from app.instructions.repository import InstructionRepository

    person = await world.ready(contacts=("Mom", "Brother"), stages=((180, ("Mom",)),))

    async def boom(*args: Any, **kwargs: Any) -> Any:
        raise RuntimeError("the transaction fails after the key was created")

    with monkeypatch.context() as m:
        m.setattr(InstructionRepository, "replace_recipients", boom)
        await world.login(person)
        response = await world.h.client.post(
            "/v1/instructions",
            json={"category": "home", "title": "First", "body": "x"},
            headers=person.headers,
        )
        assert response.status_code == 500
    keys = world.db.execute("SELECT count(*) AS n FROM user_keys").fetchone()
    assert keys is not None
    assert keys["n"] == 1  # durable although the request rolled back
    left = world.db.execute("SELECT count(*) AS n FROM instructions").fetchone()
    assert left is not None
    assert left["n"] == 0

    made = await world.h.client.post(
        "/v1/instructions",
        json={"category": "home", "title": "Second", "body": "readable"},
        headers=person.headers,
    )
    assert made.status_code == 201
    world.h.app.state.services.vault.forget(uuid.UUID(person.user_id))  # a cold cache
    again = await world.h.client.get(
        f"/v1/instructions/{made.json()['id']}", headers=person.headers
    )
    assert again.status_code == 200
    assert again.json()["body"] == "readable"


@pytest.mark.parametrize("code_point", [0xD83D, 0xE0041, 0xFEFF, 0x202E, 0x2066])
async def test_r1_unsafe_characters_are_a_422_not_a_500(world: World, code_point: int) -> None:
    import json

    person = await world.ready()
    await world.login(person)
    text = "text " + chr(code_point) + " more"
    response = await world.h.client.post(
        "/v1/instructions",
        content=json.dumps({"category": "home", "title": "ok", "body": text}, ensure_ascii=True),
        headers={**person.headers, "content-type": "application/json"},
    )
    assert response.status_code == 422
    keys = world.db.execute("SELECT count(*) AS n FROM user_keys").fetchone()
    assert keys is not None
    assert keys["n"] == 0


async def test_r2_a_release_inside_the_rollback_reach_of_a_hold_is_hidden(world: World) -> None:
    person = await _released(world)
    created = world.db.execute("SELECT released_at FROM release_events").fetchone()
    assert created is not None
    # a Hold that began 2 minutes AFTER the stage ran: inside the settle delay, so the engine
    # will take the stage back when it ends; nothing of it may be readable meanwhile
    world.db.execute(
        "INSERT INTO system_holds (reason, started_at, detected_at, created_by) "
        "VALUES ('operator', %s, %s, 'test')",
        (created["released_at"] + timedelta(minutes=2), world.clock.current),
    )
    shown = await Portal(world).reach_content(person)
    assert TITLE not in shown.text


async def test_r3_a_released_alert_that_loses_its_release_is_sent_without_the_link(
    world: World,
) -> None:
    person = await _setup(world)  # Brother is notified AND released to at stage 2
    await world.advance_to(STAGE_2)  # the stage ran; the message waits out the settle delay
    await world.login(person)
    path = f"/v1/instructions/{person.contacts['_instruction']}"
    off = await world.h.client.patch(path, json={"status": "inactive"}, headers=person.headers)
    assert off.status_code == 403  # a live schedule asks for the password first
    assert (await world.h.reauth(person.tokens)).status_code == 204
    off = await world.h.client.patch(path, json={"status": "inactive"}, headers=person.headers)
    assert off.status_code == 200
    await world.advance_to(STAGE_2 + timedelta(minutes=6))
    plain = world.mail.to(address(person, "Brother"), "contact_alert")
    assert len(plain) == 1  # not silence
    assert "/c/release" not in plain[0].text
    assert world.mail.to(address(person, "Brother"), "contact_alert_with_release") == []


async def test_r3_a_contact_only_released_to_is_not_alerted_when_the_release_is_gone(
    world: World,
) -> None:
    person = await world.ready(
        contacts=("Mom", "Brother", "Sam"), stages=((180, ("Mom",)), (1440, ("Brother",)))
    )
    assert (await world.h.reauth(person.tokens)).status_code == 204
    instruction = await _make(world, person, "Sam", "For Sam")
    await world.advance_to(DUE + timedelta(minutes=10))
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    gone = await world.h.client.delete(f"/v1/instructions/{instruction}", headers=person.headers)
    assert gone.status_code == 204
    await world.advance_to(STAGE_2 + timedelta(minutes=10))
    assert world.mail.to(address(person, "Sam"), "contact_alert") == []
    assert world.mail.to(address(person, "Sam"), "contact_alert_with_release") == []
    assert len(world.mail.to(address(person, "Brother"), "contact_alert")) == 1


async def test_r4_content_that_cannot_be_opened_is_not_reported_as_withdrawn(
    world: World,
) -> None:
    person = await _released(world)
    world.db.execute("UPDATE instructions SET content_key_version = 99")  # cannot open now
    portal = Portal(world)
    shown = await portal.reach_content(person)
    assert shown.status_code == 503
    assert "couldn't show this right now" in shown.text.replace("&#39;", "'")
    assert "withdrawn" not in shown.text
    row = world.db.execute("SELECT view_count FROM release_events").fetchone()
    assert row is not None
    assert row["view_count"] == 0  # not counted as seen


async def test_r4_one_unreadable_item_is_said_not_silently_dropped(world: World) -> None:
    person = await world.ready(
        contacts=("Mom", "Brother"), stages=((180, ("Mom",)), (1440, ("Brother",)))
    )
    assert (await world.h.reauth(person.tokens)).status_code == 204
    await _make(world, person, "Brother", "First thing", "Words one.")
    second = await _make(world, person, "Brother", "Second thing", "Words two.")
    await world.advance_to(STAGE_2 + timedelta(minutes=6))
    world.db.execute("UPDATE instructions SET content_key_version = 99 WHERE id = %s", (second,))
    shown = await Portal(world).reach_content(person)
    assert shown.status_code == 200
    assert "First thing" in shown.text
    assert "Second thing" not in shown.text
    assert "1 item could not be shown" in shown.text


async def test_r5_changing_who_receives_something_needs_the_password(world: World) -> None:
    person = await world.ready(
        contacts=("Mom", "Brother"), stages=((180, ("Mom",)), (1440, ("Brother",)))
    )
    await world.login(person)
    plan = await world.h.client.get("/v1/plan", headers=person.headers)
    stage_2 = plan.json()["stages"][1]["id"]
    route = [{"contact_id": person.contacts["Brother"], "release_stage_id": stage_2}]
    refused = await world.h.client.post(
        "/v1/instructions",
        json={"category": "home", "title": "T", "body": "B", "recipients": route},
        headers=person.headers,
    )
    assert refused.status_code == 403  # a route to someone, while the net is on
    assert refused.json()["code"] == "reauth_required"
    plain = await world.h.client.post(
        "/v1/instructions",
        json={"category": "home", "title": "T", "body": "B"},
        headers=person.headers,
    )
    assert plain.status_code == 201  # no recipient: nothing is routed
    instruction = plain.json()["id"]
    response = await world.h.client.patch(
        f"/v1/instructions/{instruction}", json={"recipients": route}, headers=person.headers
    )
    assert response.status_code == 403
    assert (await world.h.reauth(person.tokens)).status_code == 204
    done = await world.h.client.patch(
        f"/v1/instructions/{instruction}", json={"recipients": route}, headers=person.headers
    )
    assert done.status_code == 200


async def test_r5_editing_the_text_or_switching_on_never_asks_but_switching_off_does(
    world: World,
) -> None:
    person = await world.ready(
        contacts=("Mom", "Brother"), stages=((180, ("Mom",)), (1440, ("Brother",)))
    )
    assert (await world.h.reauth(person.tokens)).status_code == 204
    instruction = await _make(world, person, "Brother", "Keys", status="inactive")
    await world.login(person)  # a fresh session: no recent password
    path = f"/v1/instructions/{instruction}"
    edited = await world.h.client.patch(path, json={"title": "Keys v2"}, headers=person.headers)
    assert edited.status_code == 200
    on = await world.h.client.patch(path, json={"status": "active"}, headers=person.headers)
    assert on.status_code == 200
    off = await world.h.client.patch(path, json={"status": "inactive"}, headers=person.headers)
    assert off.status_code == 403  # switching OFF something that is routed does


async def test_r5_deleting_a_routed_instruction_needs_the_password(world: World) -> None:
    person = await _setup(world)
    await world.login(person)
    refused = await world.h.client.delete(
        f"/v1/instructions/{person.contacts['_instruction']}", headers=person.headers
    )
    assert refused.status_code == 403


async def test_r5_removing_a_release_only_recipient_needs_the_password(world: World) -> None:
    person = await world.ready(
        contacts=("Mom", "Brother", "Sam"), stages=((180, ("Mom",)), (1440, ("Brother",)))
    )
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    await _make(world, person, "Sam", "For Sam")
    await world.login(person)  # a fresh session: no recent password
    refused = await world.h.client.delete(
        f"/v1/contacts/{person.contacts['Sam']}", headers=person.headers
    )
    assert refused.status_code == 403
    assert refused.json()["code"] == "reauth_required"


async def test_r6_guessing_has_a_daily_budget_across_codes(world: World) -> None:
    person = await _released(world)
    portal = Portal(world)
    token = _link_token(world, person)
    attempts = 0
    refused = None
    for _ in range(6):  # a code (and a new session) an hour apart: each allows five tries
        await portal.open(token)
        await portal.code()
        real = portal.last_code(person)
        wrong = "000000" if real != "000000" else "111111"
        for _ in range(5):
            response = await portal.verify(wrong)
            attempts += 1
            if response.status_code == 429:
                refused = response
                break
        if refused is not None:
            break
        world.clock.advance(minutes=61)
    assert refused is not None
    assert attempts == 21  # the 21st attempt of the day


async def test_r7_a_link_row_must_name_its_own_contact(world: World) -> None:
    person = await _released(world)
    access = world.db.execute("SELECT id FROM portal_access").fetchone()
    assert access is not None
    world.db.execute(
        "INSERT INTO notifications (user_id, audience, category, contact_id, channel, "
        "template_key, params, status, send_after, dedupe_key) VALUES "
        "(%s, 'contact', 'contact_other', %s, 'email', 'contact_release', %s::jsonb, 'queued', "
        "%s, 'forged-link')",
        (
            person.user_id,
            person.contacts["Mom"],
            f'{{"access_id": "{access["id"]}"}}',
            world.clock.current,
        ),
    )
    await world.dispatch()
    assert world.mail.to(address(person, "Mom"), "contact_release") == []
    row = world.db.execute(
        "SELECT status FROM notifications WHERE dedupe_key = 'forged-link'"
    ).fetchone()
    assert row is not None
    assert row["status"] == "cancelled"


async def test_r9_a_fresh_link_waits_out_a_hold(world: World) -> None:
    from app.ops import admin

    person = await _released(world)
    token = _link_token(world, person)
    before = len(world.mail.to(address(person, "Brother"), "contact_release"))
    portal = Portal(world)
    await admin.hold_enter(world.engine.services, operator="alex", reason="investigating")
    asked = await portal.post("/c/release/new-link", token=token)
    assert asked.status_code == 200
    await world.tick()
    assert len(world.mail.to(address(person, "Brother"), "contact_release")) == before


async def test_r10_a_whole_account_can_be_deleted_with_instructions_and_releases(
    world: World,
) -> None:
    person = await _released(world)
    world.db.execute("DELETE FROM users WHERE id = %s", (person.user_id,))
    for table in ("instructions", "instruction_recipients", "release_events", "user_keys"):
        left = world.db.execute(f"SELECT count(*) AS n FROM {table}").fetchone()  # noqa: S608
        assert left is not None
        assert left["n"] == 0, table


async def test_r11_each_process_is_connected_as_its_own_role(world: World) -> None:
    assert await world.h.app.state.services.db.current_role() == "afterme_api"
    assert await world.engine.services.db.current_role() == "afterme_worker"


async def test_a_contact_sees_only_their_own_instructions_and_gets_the_right_notice(
    world: World,
) -> None:
    person = await world.ready(
        contacts=("Mom", "Brother"), stages=((180, ("Mom",)), (1440, ("Brother",)))
    )
    assert (await world.h.reauth(person.tokens)).status_code == 204
    await _make(world, person, "Mom", "For Mom only", "Mom's words.")
    await _make(world, person, "Brother", "For Brother only", "Brother's words.")
    await world.advance_to(STAGE_2 + timedelta(minutes=6))
    # Mom was alerted at stage 1, so at stage 2 she gets the release notice, not a second alert
    assert len(world.mail.to(address(person, "Mom"), "contact_alert")) == 1
    assert len(world.mail.to(address(person, "Mom"), "contact_release")) == 1
    assert len(world.mail.to(address(person, "Brother"), "contact_alert_with_release")) == 1

    portal = Portal(world)
    brother = await portal.reach_content(person, "Brother")
    assert "For Brother only" in brother.text
    assert "For Mom only" not in brother.text
    mom = await portal.reach_content(person, "Mom")
    assert "For Mom only" in mom.text
    assert "For Brother only" not in mom.text
