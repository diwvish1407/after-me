"""Phase 14: several check-in events with their own plans, two-step verification, the admin
API, contact acknowledgements and Sign in with Google (token verification)."""

from __future__ import annotations

import base64
import time as pytime
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from app.auth.google import GoogleTokenError, GoogleVerifier
from app.auth.totp import code_at, step_of
from app.contacts.tokens import new_ack_token
from tests.support import DEVICE, PASSWORD, Harness, bearer, problem, rows
from tests.world import World, ist

EVENTS = "/v1/checkin/events"


async def _event(world: World, person: Any, label: str = "Morning", at: str = "09:00") -> Any:
    response = await world.call(person, "POST", EVENTS, json={"label": label, "due_local_time": at})
    assert response.status_code == 201, response.text
    return response.json()


# --- several check-in events ------------------------------------------------------------------


async def test_events_can_be_added_listed_changed_and_removed(world: World) -> None:
    person = await world.ready()
    event = await _event(world, person)
    assert event["label"] == "Morning"
    assert event["due_local_time"] == "09:00"
    assert event["has_own_plan"] is False

    listed = (await world.call(person, "GET", EVENTS)).json()
    assert [e["id"] for e in listed["items"]] == [event["id"]]
    assert listed["max_events"] == 5

    # the earliest deadline is now the morning event (activation was at 14:30 IST)
    config = world.config(person)
    assert config["due_slot_id"] is not None
    assert config["next_due_at"] == ist("2026-10-09T09:00")
    assert config["primary_due_at"] == ist("2026-10-09T20:00")

    changed = await world.call(
        person,
        "PUT",
        f"{EVENTS}/{event['id']}",
        json={"label": "Breakfast", "due_local_time": "08:30"},
    )
    assert changed.status_code == 200, changed.text
    assert changed.json()["label"] == "Breakfast"
    assert world.config(person)["next_due_at"] == ist("2026-10-09T08:30")

    # removing an event of an active schedule needs the password again
    refused = await world.call(person, "DELETE", f"{EVENTS}/{event['id']}")
    assert problem(refused)["code"] == "reauth_required"
    assert (await world.h.reauth(person.tokens)).status_code == 204
    removed = await world.h.client.delete(f"{EVENTS}/{event['id']}", headers=person.headers)
    assert removed.status_code == 204
    assert world.config(person)["due_slot_id"] is None
    assert world.config(person)["next_due_at"] == ist("2026-10-09T20:00")
    assert (await world.call(person, "GET", EVENTS)).json()["items"] == []


async def test_the_number_of_events_is_limited(world: World) -> None:
    person = await world.ready()
    for i in range(5):
        await _event(world, person, f"Event {i}", f"0{i}:15")
    sixth = await world.call(
        person, "POST", EVENTS, json={"label": "Six", "due_local_time": "07:00"}
    )
    assert problem(sixth)["code"] == "plan_limit_reached"


async def test_a_checkin_answers_the_event_that_is_due_first(world: World) -> None:
    person = await world.ready()
    event = await _event(world, person)
    await world.advance_to(ist("2026-10-09T08:30"))
    await world.checkin(person)
    config = world.config(person)
    assert config["primary_due_at"] == ist("2026-10-09T20:00")
    assert config["next_due_at"] == ist("2026-10-09T20:00")
    assert config["due_slot_id"] is None
    (slot,) = rows(world.db, "SELECT next_due_at FROM checkin_slots WHERE id = %s", event["id"])
    assert slot["next_due_at"] == ist("2026-10-10T09:00")


async def test_a_missed_event_escalates_with_its_own_plan(world: World) -> None:
    person = await world.ready(contacts=("Mom", "Dad"), stages=((180, ("Mom",)),))
    event = await _event(world, person)
    inherited = await world.call(person, "GET", f"{EVENTS}/{event['id']}/plan")
    assert inherited.status_code == 200
    assert inherited.json()["inherits_default"] is True
    assert inherited.headers["etag"] == '"plan-0"'

    assert (await world.h.reauth(person.tokens)).status_code == 204
    own = await world.h.client.put(
        f"{EVENTS}/{event['id']}/plan",
        json={
            "grace_minutes": 60,
            "stages": [{"offset_minutes": 60, "notify_contact_ids": [person.contacts["Dad"]]}],
        },
        headers={**person.headers, "If-Match": '"plan-0"'},
    )
    assert own.status_code == 200, own.text
    assert own.json()["slot_id"] == event["id"]
    assert own.json()["inherits_default"] is False

    await world.advance_to(ist("2026-10-09T09:01"))
    await world.tick()
    incident = world.open_incident(person)
    assert incident is not None
    assert str(incident["plan_id"]) == own.json()["id"]
    assert incident["grace_ends_at"] == ist("2026-10-09T10:00")
    snapshot = incident["plan_snapshot"]
    assert snapshot["stages"][0]["notify_contact_ids"] == [person.contacts["Dad"]]


async def test_another_persons_event_is_not_found(world: World) -> None:
    owner = await world.ready()
    event = await _event(world, owner)
    other = await world.ready("other@example.com")
    for method, path in (
        ("PUT", f"{EVENTS}/{event['id']}"),
        ("GET", f"{EVENTS}/{event['id']}/plan"),
    ):
        response = await world.call(
            other, method, path, json={"label": "x", "due_local_time": "10:00"}
        )
        assert response.status_code == 404


# --- two-step verification --------------------------------------------------------------------


async def _enable_mfa(h: Harness, tokens: dict[str, Any]) -> tuple[bytes, list[str]]:
    assert (await h.reauth(tokens)).status_code == 204
    setup = await h.client.post("/v1/me/2fa/setup", headers=bearer(tokens))
    assert setup.status_code == 200, setup.text
    secret = base64.b32decode(setup.json()["secret"] + "=" * (-len(setup.json()["secret"]) % 8))
    now = h.clock.current
    enabled = await h.client.post(
        "/v1/me/2fa/enable",
        json={"code": code_at(secret, step_of(now))},
        headers=bearer(tokens),
    )
    assert enabled.status_code == 200, enabled.text
    codes: list[str] = enabled.json()["recovery_codes"]
    return secret, codes


async def test_two_step_verification_is_asked_at_sign_in(h: Harness) -> None:
    tokens = await h.signup("mfa@example.com")
    secret, codes = await _enable_mfa(h, tokens)
    assert len(codes) == 8

    missing = await h.login("mfa@example.com")
    assert problem(missing)["code"] == "mfa_required"

    wrong = await h.client.post(
        "/v1/auth/login",
        json={
            "email": "mfa@example.com",
            "password": PASSWORD,
            "device": DEVICE,
            "otp": "000000",
        },
    )
    assert wrong.status_code == 401

    h.clock.advance(seconds=31)
    ok = await h.client.post(
        "/v1/auth/login",
        json={
            "email": "mfa@example.com",
            "password": PASSWORD,
            "device": DEVICE,
            "otp": code_at(secret, step_of(h.clock.current)),
        },
    )
    assert ok.status_code == 200, ok.text

    by_recovery = await h.client.post(
        "/v1/auth/login",
        json={
            "email": "mfa@example.com",
            "password": PASSWORD,
            "device": DEVICE,
            "otp": codes[0],
        },
    )
    assert by_recovery.status_code == 200, by_recovery.text
    status = await h.client.get("/v1/me/2fa", headers=bearer(by_recovery.json()))
    assert status.json() == {"enabled": True, "recovery_codes_left": 7}


async def test_setting_up_two_step_verification_needs_the_password(h: Harness) -> None:
    tokens = await h.signup("mfa2@example.com")
    response = await h.client.post("/v1/me/2fa/setup", headers=bearer(tokens))
    assert problem(response)["code"] == "reauth_required"


# --- the admin API ------------------------------------------------------------------------------


async def test_only_admins_reach_the_admin_api(world: World) -> None:
    person = await world.ready()
    refused = await world.call(person, "GET", "/v1/admin/overview")
    assert problem(refused)["code"] == "admin_required"

    admin = await world.person("admin@example.com")
    world.db.execute("UPDATE users SET role = 'admin' WHERE id = %s", (admin.user_id,))
    overview = await world.call(admin, "GET", "/v1/admin/overview")
    assert overview.status_code == 200, overview.text
    assert overview.json()["users_total"] >= 2
    assert overview.json()["schedules_active"] >= 1

    users = await world.call(admin, "GET", "/v1/admin/users", params={"q": "owner@"})
    assert [u["email"] for u in users.json()["items"]] == ["owner@example.com"]

    detail = await world.call(admin, "GET", f"/v1/admin/users/{person.user_id}")
    assert detail.status_code == 200, detail.text
    body = detail.json()
    assert body["contacts"][0]["email_masked"].startswith("m***@")
    assert "instructions" not in body  # only a count, never content
    assert body["instructions_active"] == 0

    # changes need a fresh password
    refused = await world.call(
        admin,
        "POST",
        f"/v1/admin/users/{person.user_id}/tier",
        json={"tier": "free", "reason": "test"},
    )
    assert problem(refused)["code"] == "reauth_required"
    assert (await world.h.reauth(admin.tokens)).status_code == 204
    changed = await world.h.client.post(
        f"/v1/admin/users/{person.user_id}/tier",
        json={"tier": "free", "reason": "beta ended"},
        headers=admin.headers,
    )
    assert changed.status_code == 200, changed.text
    assert changed.json()["after"] == "free"
    me = await world.call(admin, "GET", "/v1/me")
    assert me.json()["role"] == "admin"


# --- a contact acknowledges an alert --------------------------------------------------------------


async def test_a_contact_can_say_they_are_checking_on_the_person(world: World) -> None:
    person = await world.ready(stages=((60, ("Mom",)),))
    await world.advance_to(ist("2026-10-09T20:01"))
    await world.tick()
    incident = world.open_incident(person)
    assert incident is not None
    token = new_ack_token(world.h.app.state.services.pepper, incident["id"], person.contacts["Mom"])

    preview = await world.h.portal_post("/c/ack/confirm", token)
    assert preview.status_code == 200
    assert "checking on" in preview.text
    assert rows(world.db, "SELECT id FROM incident_acknowledgements") == []  # a POST to look

    done = await world.h.portal_post("/c/ack", token)
    assert done.status_code == 200
    again = await world.h.portal_post("/c/ack", token)
    assert again.status_code == 200
    (ack,) = rows(world.db, "SELECT contact_id FROM incident_acknowledgements")
    assert str(ack["contact_id"]) == person.contacts["Mom"]

    view = await world.call(person, "GET", f"/v1/incidents/{incident['id']}")
    assert [a["contact_display_name"] for a in view.json()["acknowledgements"]] == ["Mom"]

    forged = await world.h.portal_post("/c/ack/confirm", token[:-2] + "AA")
    assert forged.status_code == 400


# --- Sign in with Google (token verification) ------------------------------------------------


def _google_keys() -> tuple[Any, dict[str, Any]]:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    jwk = jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key(), as_dict=True)
    jwk.update({"kid": "k1", "alg": "RS256", "use": "sig"})
    return key, {"keys": [jwk]}


def _id_token(key: Any, **claims: Any) -> str:
    now = int(pytime.time())
    body = {
        "iss": "https://accounts.google.com",
        "aud": "client-1",
        "sub": "g-123",
        "email": "person@gmail.com",
        "email_verified": True,
        "name": "Person",
        "iat": now,
        "exp": now + 600,
        **claims,
    }
    return jwt.encode(body, key, algorithm="RS256", headers={"kid": "k1"})


@pytest.mark.no_db
async def test_google_tokens_are_verified() -> None:
    key, jwks = _google_keys()
    verifier = GoogleVerifier(["client-1"], jwks=jwks)
    identity = await verifier.verify(_id_token(key))
    assert (identity.sub, identity.email, identity.name) == ("g-123", "person@gmail.com", "Person")
    for bad in (
        _id_token(key, aud="someone-else"),
        _id_token(key, iss="https://evil.example"),
        _id_token(key, email_verified=False),
        _id_token(rsa.generate_private_key(public_exponent=65537, key_size=2048)),
    ):
        with pytest.raises(GoogleTokenError):
            await verifier.verify(bad)
    with pytest.raises(GoogleTokenError):
        await GoogleVerifier([]).verify(_id_token(key))


async def test_google_sign_in_is_off_without_a_client_id(h: Harness) -> None:
    response = await h.client.post(
        "/v1/auth/google",
        json={"id_token": "x" * 40, "device": DEVICE},
    )
    assert problem(response)["code"] == "google_unavailable"
