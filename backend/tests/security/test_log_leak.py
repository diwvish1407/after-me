"""Log-leak test (SECURITY §10; TEST_PLAN SEC-25).

Captures every log record emitted while a full signup → verify → login → refresh → reauth →
logout flow runs (at DEBUG level, including third-party loggers) and fails if any secret value
appears in the rendered output.
"""

from __future__ import annotations

import io
import logging
import re
from collections.abc import Iterator
from typing import Any

import psycopg
import pytest

from app.core.logging import build_formatter
from tests.support import Harness, bearer

SECRET_PASSWORD = "Leaky Passphrase 42 xyzzy"
EMAIL = "Leak.Test.Person@Example.com"


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
    """Match a value that is not part of a longer word/number (6-digit codes vs timestamps)."""
    return re.compile(rf"(?<![\w.:+-]){re.escape(value)}(?![\w])")


async def test_full_auth_flow_leaks_nothing_to_logs(
    h: Harness, captured_logs: io.StringIO, owner_db: psycopg.Connection[dict[str, Any]]
) -> None:
    secrets_seen: list[str] = []

    start = await h.register(EMAIL, password=SECRET_PASSWORD, display_name="Leaky Name")
    assert start.status_code == 202
    code = h.code_for(EMAIL)
    wrong = "000000" if code != "000000" else "111111"
    assert (await h.verify(EMAIL, wrong, SECRET_PASSWORD)).status_code == 400
    verified = await h.verify(EMAIL, code, SECRET_PASSWORD)
    assert verified.status_code == 201
    first = verified.json()
    secrets_seen += [first["access_token"], first["refresh_token"]]

    bad_login = await h.login(EMAIL, "Wrong Passphrase 99 plugh")
    assert bad_login.status_code == 401
    login = await h.login(EMAIL, SECRET_PASSWORD)
    assert login.status_code == 200
    second = login.json()
    secrets_seen += [second["access_token"], second["refresh_token"]]

    refreshed = await h.refresh(second["refresh_token"])
    assert refreshed.status_code == 200
    third = refreshed.json()
    secrets_seen += [third["access_token"], third["refresh_token"]]

    assert (await h.reauth(third, "Wrong Passphrase 99 plugh")).status_code == 401
    assert (await h.reauth(third, SECRET_PASSWORD)).status_code == 204
    assert (await h.client.get("/v1/me", headers=bearer(third))).status_code == 200
    assert (await h.client.post("/v1/auth/logout", headers=bearer(third))).status_code == 204
    # Reuse after logout and an unknown token: error paths log too.
    assert (await h.refresh(first["refresh_token"])).status_code == 200
    h.clock.advance(minutes=5)
    assert (await h.refresh(first["refresh_token"])).status_code == 401
    assert (await h.client.get("/v1/_test/boom")).status_code == 500

    output = captured_logs.getvalue()
    assert "http.request" in output  # the capture really saw the access log
    assert output.count("\n") >= 10

    forbidden = [
        SECRET_PASSWORD,
        "Wrong Passphrase 99 plugh",
        EMAIL,
        EMAIL.lower(),
        "Leak.Test.Person",
        "Leaky Name",
        *secrets_seen,
    ]
    for value in forbidden:
        assert value not in output, f"secret value leaked into logs: {value[:12]}…"
    for value in (code, wrong):
        assert not _standalone(value).search(output), "verification code leaked into logs"
    assert "Bearer " not in output
    assert not re.search(r"eyJ[A-Za-z0-9_-]{10,}\.", output)
    assert "rt_" not in output

    # Audit rows are part of the same leak surface.
    audit = str(owner_db.execute("SELECT metadata, request_id FROM audit_logs").fetchall())
    for value in (SECRET_PASSWORD, EMAIL.lower(), code, *secrets_seen):
        assert value not in audit


async def test_password_email_and_profile_flows_leak_nothing_to_logs(
    h: Harness, captured_logs: io.StringIO, owner_db: psycopg.Connection[dict[str, Any]]
) -> None:
    """Phase 2 flows: forgot, web reset, change password, change email, profile patch."""
    new_email = "Brand.New.Address@Example.com"
    reset_password = "Reset Passphrase 31 quux"
    changed_password = "Changed Passphrase 52 corge"
    rejected_password = "short"
    phone = "+14155550137"
    display_name = "Secret Display Name"

    first = await h.signup(EMAIL, SECRET_PASSWORD)
    await h.forgot(EMAIL)
    await h.forgot("nobody-at-all@example.com")
    token = h.reset_token_for(EMAIL)

    assert (await h.client.get("/a/reset", params={"token": token})).status_code == 200
    assert (await h.web_reset(token, rejected_password)).status_code == 422
    assert (await h.web_reset(token, reset_password)).status_code == 200
    assert (await h.web_reset(token, "Replayed Passphrase 08 grault")).status_code == 400
    assert (await h.client.get("/v1/me", headers=bearer(first))).status_code == 401

    login = (await h.login(EMAIL, reset_password)).json()
    other = (await h.login(EMAIL, reset_password)).json()
    wrong = await h.client.post(
        "/v1/auth/password/change",
        json={"current_password": "Not The Password 66 garply", "new_password": changed_password},
        headers=bearer(login),
    )
    assert wrong.status_code == 401
    changed = await h.client.post(
        "/v1/auth/password/change",
        json={"current_password": reset_password, "new_password": changed_password},
        headers=bearer(login),
    )
    assert changed.status_code == 204
    assert (await h.client.get("/v1/me", headers=bearer(other))).status_code == 401

    assert (await h.reauth(login, changed_password)).status_code == 204
    started = await h.client.post(
        "/v1/auth/email/change/start", json={"new_email": new_email}, headers=bearer(login)
    )
    assert started.status_code == 202
    message = h.mail.to(new_email, "email_change_code")[0]
    code_match = re.search(r"\b(\d{6})\b", message.text)
    assert code_match is not None
    code = code_match[1]
    wrong_code = "000000" if code != "000000" else "111111"
    for attempt in (wrong_code, code):
        await h.client.post(
            "/v1/auth/email/change/verify", json={"code": attempt}, headers=bearer(login)
        )
    patch = await h.client.patch(
        "/v1/me/profile",
        json={"display_name": display_name, "phone_e164": phone},
        headers=bearer(login),
    )
    assert patch.status_code == 200
    assert patch.json()["email"] == "Brand.New.Address@example.com"  # canonical spelling

    output = captured_logs.getvalue()
    assert "http.request" in output
    assert "/v1/auth/password/change" in output  # the route template is logged, nothing else

    forbidden = [
        SECRET_PASSWORD,
        reset_password,
        changed_password,
        rejected_password + '"',  # a bare "short" would match unrelated words
        "Not The Password 66 garply",
        "Replayed Passphrase 08 grault",
        EMAIL,
        EMAIL.lower(),
        new_email,
        new_email.lower(),
        "Brand.New.Address",
        "nobody-at-all@example.com",
        token,
        token[3:],
        phone,
        display_name,
        login["access_token"],
        login["refresh_token"],
    ]
    for value in forbidden:
        assert value not in output, f"secret value leaked into logs: {value[:10]}…"
    for value in (code, wrong_code):
        assert not _standalone(value).search(output), "email-change code leaked into logs"
    assert "pr_" not in output
    assert "/a/reset#" not in output
    assert "__Host-afterme_csrf" not in output
    assert "new_password" not in output
    assert "Bearer " not in output

    # Audit metadata and rate-limit keys are part of the same leak surface.
    stored = str(
        owner_db.execute("SELECT metadata, request_id FROM audit_logs").fetchall()
        + owner_db.execute("SELECT key FROM rate_limit_counters").fetchall()
    )
    for value in (
        reset_password,
        changed_password,
        new_email.lower(),
        token,
        code,
        phone,
        display_name,
    ):
        assert value not in stored
    assert "@" not in stored


async def test_contact_and_portal_flows_leak_nothing_to_logs(
    h: Harness, captured_logs: io.StringIO, owner_db: psycopg.Connection[dict[str, Any]]
) -> None:
    """Phase 3 flows: contacts CRUD, invitations, suppression, the recipient pages (accept,
    decline, opt-out, invalid links, CSRF refusals, rate limiting)."""
    contact_email = "Quentin.Secret@Example.com"
    other_email = "Rowan.Hidden@Example.org"
    third_email = "Sasha.Quiet@Example.net"
    contact_name = "Quentin Secretname"
    other_name = "Rowan Hiddenname"
    third_name = "Sasha Quietname"
    phone = "+14155550199"
    owner_name = "Ownerella Privatename"

    tokens = await h.signup(EMAIL, SECRET_PASSWORD)
    await h.client.patch(
        "/v1/me/profile", json={"display_name": owner_name}, headers=bearer(tokens)
    )
    owner_db.execute("UPDATE users SET tier = 'premium'")

    first = (await h.add_contact(tokens, contact_email, name=contact_name, phone_e164=phone)).json()
    second = (await h.add_contact(tokens, other_email, name=other_name)).json()
    third = (await h.add_contact(tokens, third_email, name=third_name)).json()
    assert (await h.add_contact(tokens, contact_email, name="Dup")).status_code == 409
    assert (await h.add_contact(tokens, EMAIL, name="Me")).status_code == 422
    assert (await h.client.get("/v1/contacts", headers=bearer(tokens))).status_code == 200
    renamed = await h.client.patch(
        f"/v1/contacts/{first['id']}",
        json={"email": "Quentin.Changed@Example.com", "display_name": "Quentin Renamed"},
        headers=bearer(tokens),
    )
    assert renamed.status_code == 200
    assert (
        await h.client.post(f"/v1/contacts/{second['id']}/invitation", headers=bearer(tokens))
    ).status_code == 202
    assert (await h.client.get("/v1/me/entitlements", headers=bearer(tokens))).status_code == 200

    invitation = h.invitation_token_for("quentin.changed@example.com")
    second_invitation = h.invitation_token_for(other_email)
    optout = h.optout_token_for(third_email)
    csrf = await h.portal_csrf()
    assert (await h.client.get("/c/open", params={"token": invitation})).status_code == 200
    assert (await h.portal_post("/c/session", invitation)).status_code == 200
    assert (await h.client.post("/c/session", data={"token": invitation})).status_code == 403
    assert (await h.portal_post("/c/session", "ci_" + "Z" * 43)).status_code == 400
    assert (await h.portal_post("/c/optout", "oo_forged." + "Y" * 43)).status_code == 400
    assert (await h.portal_post("/c/invite/accept", invitation)).status_code == 200
    assert (await h.portal_post("/c/invite/accept", invitation)).status_code == 400
    assert (
        await h.portal_post("/c/invite/decline", second_invitation, never_contact="1")
    ).status_code == 200
    assert (await h.portal_post("/c/optout/confirm", optout)).status_code == 200
    assert (await h.portal_post("/c/optout", optout, scope="this_person")).status_code == 200
    h.mail.clear()
    assert (
        await h.client.delete(f"/v1/contacts/{third['id']}", headers=bearer(tokens))
    ).status_code == 204
    for _ in range(21):  # run into the per-IP limit of the recipient pages
        await h.client.post("/c/session", data={"token": invitation, "csrf": csrf})

    output = captured_logs.getvalue()
    assert "http.request" in output
    assert "/v1/contacts/{contact_id}" in output  # the route template is logged, not the path
    forbidden = [
        contact_email,
        contact_email.lower(),
        "quentin.changed@example.com",
        other_email,
        other_email.lower(),
        third_email,
        third_email.lower(),
        "Quentin",
        "Secretname",
        "Rowan",
        "Hiddenname",
        "Sasha",
        "Quietname",
        owner_name,
        "Ownerella",
        EMAIL,
        EMAIL.lower(),
        phone,
        invitation,
        invitation[3:],
        second_invitation,
        optout,
        optout[3:],
        csrf,
    ]
    for value in forbidden:
        assert value not in output, f"sensitive value leaked into logs: {value[:10]}…"
    assert not re.search(r"\bci_[A-Za-z0-9_-]{20,}", output)
    assert not re.search(r"\boo_[0-9a-f]{8}-", output)
    assert "/c/open#" not in output
    assert "/c/optout#" not in output
    assert "__Host-afterme_csrf" not in output
    assert "csrf" not in output.lower().replace("afterme.csrf", "")
    assert "Bearer " not in output

    readable = str(
        owner_db.execute("SELECT metadata, request_id FROM audit_logs").fetchall()
        + owner_db.execute("SELECT key FROM rate_limit_counters").fetchall()
        + owner_db.execute("SELECT reason FROM email_suppressions").fetchall()
    )
    # The suppression hash is random bytes: its repr can contain any character, '@' included.
    stored = readable + str(
        owner_db.execute("SELECT email_hash FROM email_suppressions").fetchall()
    )
    for value in (
        contact_email.lower(),
        other_email.lower(),
        third_email.lower(),
        contact_name,
        owner_name,
        phone,
        invitation,
        optout,
    ):
        assert value not in stored
    assert "@" not in readable


async def test_checkin_flows_leak_nothing_to_logs_or_audit(
    h: Harness, captured_logs: io.StringIO, owner_db: psycopg.Connection[dict[str, Any]]
) -> None:
    """Phase 4 flows: schedule, activation, check-in (with an informational client time),
    history, Home and deactivation. Check-in history reveals daily patterns (SECURITY §2), so
    neither the times nor the idempotency keys may reach the logs or the audit metadata."""
    contact_email = "Tamsin.Private@Example.com"
    key = "leaky-idem-0123456789abcdef"
    reported = "2026-10-08T14:31:17+05:30"
    tokens = await h.signup(EMAIL, SECRET_PASSWORD)
    assert (
        await h.add_contact(tokens, contact_email, name="Tamsin Privatename")
    ).status_code == 201
    put = await h.client.put(
        "/v1/checkin/schedule",
        json={"interval_days": 3, "due_local_time": "21:47", "reminder_lead_minutes": 120},
        headers={**bearer(tokens), "If-Match": '"sched-1"'},
    )
    assert put.status_code == 200
    await h.plan_for_contacts(tokens)
    assert (await h.client.post("/v1/checkin/activate", headers=bearer(tokens))).status_code == 200
    first = await h.client.post(
        "/v1/checkins",
        json={"client_reported_at": reported},
        headers={**bearer(tokens), "Idempotency-Key": key},
    )
    assert first.status_code == 200
    replay = await h.client.post("/v1/checkins", headers={**bearer(tokens), "Idempotency-Key": key})
    assert replay.status_code == 200
    assert (await h.client.get("/v1/checkins", headers=bearer(tokens))).status_code == 200
    assert (await h.client.get("/v1/home", headers=bearer(tokens))).status_code == 200
    assert (await h.reauth(tokens, SECRET_PASSWORD)).status_code == 204
    assert (
        await h.client.post("/v1/checkin/deactivate", headers=bearer(tokens))
    ).status_code == 200

    output = captured_logs.getvalue()
    assert "/v1/checkins" in output
    for value in (
        key,
        reported,
        "14:31:17",
        "21:47",
        contact_email,
        contact_email.lower(),
        "Tamsin",
        "Privatename",
        SECRET_PASSWORD,
        first.json()["checkin"]["id"],  # the event ID is not a secret, but it has no place in logs
    ):
        assert value not in output, f"sensitive value leaked into logs: {value[:10]}…"
    assert "Bearer " not in output
    assert "If-Match" not in output
    assert "Idempotency-Key" not in output

    audit = str(
        owner_db.execute(
            "SELECT action, metadata, resource_type FROM audit_logs "
            "WHERE action LIKE 'schedule.%' OR action LIKE 'checkin.%'"
        ).fetchall()
    )
    for value in (key, reported, "21:47", "2026-10-"):
        assert value not in audit
