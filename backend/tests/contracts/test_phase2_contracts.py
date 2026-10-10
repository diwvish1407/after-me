"""Golden contract files for the mobile app (``docs/contracts/phase2``).

The test drives every authentication endpoint through a realistic session, records each request
and response body, replaces everything random (IDs, tokens, codes, request IDs) with fixed
placeholders, and compares the result to the committed files. The mobile app parses the same
files in its own tests, so the two sides cannot drift apart unnoticed.

Regenerate after an intentional API change::

    AFTERME_UPDATE_CONTRACTS=1 uv run pytest tests/contracts

The files hold fictional placeholder values only: no real token, code or address is ever written.
"""

from __future__ import annotations

import os
import re

from tests.contracts.recorder import Recorder
from tests.support import BACKEND_DIR, DEVICE, Harness

CONTRACT_DIR = BACKEND_DIR.parent / "docs" / "contracts" / "phase2"
UPDATE = os.environ.get("AFTERME_UPDATE_CONTRACTS") == "1"

EMAIL = "asha@example.com"
NEW_EMAIL = "asha.rao@example.net"
UNVERIFIED_EMAIL = "newcomer@example.net"
PASSWORD = "correct horse battery staple"
NEW_PASSWORD = "a brand new passphrase 77"

PHASE2_NOTES = (
    "Values are fictional placeholders; tokens, codes and IDs are not real.",
    "Errors are RFC 9457 application/problem+json; see problems[].",
    "204 responses have no body and no response file.",
    "POST /a/reset is a web form (urlencoded: token, new_password, csrf), not a JSON endpoint.",
)


async def _scenario(h: Harness) -> Recorder:
    r = Recorder(h, contract="afterme-phase2", notes=PHASE2_NOTES)
    # --- sign up -------------------------------------------------------------------------------
    await r.call(
        "register_start",
        "POST",
        "/v1/auth/register/start",
        status=202,
        json_body={
            "email": EMAIL,
            "password": PASSWORD,
            "display_name": "Asha Rao",
            "timezone": "Asia/Kolkata",
            "locale": "en",
            "country_code": "IN",
        },
    )
    h.clock.advance(seconds=61)
    await r.call(
        "register_resend",
        "POST",
        "/v1/auth/register/resend",
        status=202,
        json_body={"email": EMAIL},
    )
    code = h.code_for(EMAIL)
    r.literal(code, "482913")
    wrong = "000000" if code != "000000" else "111111"
    r.literal(wrong, "000000")
    await r.call(
        "problem_invalid_code",
        "POST",
        "/v1/auth/register/verify",
        status=400,
        json_body={"email": EMAIL, "code": wrong, "password": PASSWORD, "device": DEVICE},
        problem=True,
    )
    verified = await r.call(
        "register_verify",
        "POST",
        "/v1/auth/register/verify",
        status=201,
        json_body={"email": EMAIL, "code": code, "password": PASSWORD, "device": DEVICE},
    )
    first = verified.json()

    # --- sign in, refresh, read ----------------------------------------------------------------
    h.clock.advance(seconds=5)
    await r.call(
        "problem_invalid_credentials",
        "POST",
        "/v1/auth/login",
        status=401,
        json_body={"email": EMAIL, "password": "not the password", "device": DEVICE},
        problem=True,
    )
    # A signup that was started but never verified: the right password is still refused (M28).
    assert (await h.register(UNVERIFIED_EMAIL, PASSWORD)).status_code == 202
    await r.call(
        "problem_email_unverified",
        "POST",
        "/v1/auth/login",
        status=403,
        json_body={"email": UNVERIFIED_EMAIL, "password": PASSWORD, "device": DEVICE},
        problem=True,
    )
    login_body = {"email": EMAIL, "password": PASSWORD, "device": DEVICE}
    logged_in = await r.call("login", "POST", "/v1/auth/login", status=200, json_body=login_body)
    second = logged_in.json()
    h.clock.advance(seconds=5)
    refreshed = await r.call(
        "refresh",
        "POST",
        "/v1/auth/refresh",
        status=200,
        json_body={"refresh_token": second["refresh_token"]},
    )
    current = {**second, **refreshed.json()}
    await r.call("me", "GET", "/v1/me", status=200, tokens=current, auth="bearer")
    await r.call("sessions", "GET", "/v1/auth/sessions", status=200, tokens=current, auth="bearer")
    await r.call("problem_unauthenticated", "GET", "/v1/me", status=401, problem=True)

    # --- re-authentication, email change, profile ------------------------------------------------
    await r.call(
        "reauth",
        "POST",
        "/v1/auth/reauth",
        status=204,
        json_body={"password": PASSWORD},
        tokens=current,
        auth="bearer",
    )
    await r.call(
        "password_forgot",
        "POST",
        "/v1/auth/password/forgot",
        status=202,
        json_body={"email": EMAIL},
    )
    await r.call(
        "email_change_start",
        "POST",
        "/v1/auth/email/change/start",
        status=202,
        json_body={"new_email": NEW_EMAIL},
        tokens=current,
        auth="bearer+reauth",
    )
    change_code = h.mail.to(NEW_EMAIL, "email_change_code")[-1].text
    match = re.search(r"\b(\d{6})\b", change_code)
    assert match is not None
    r.literal(match[1], "135790")
    await r.call(
        "email_change_verify",
        "POST",
        "/v1/auth/email/change/verify",
        status=200,
        json_body={"code": match[1]},
        tokens=current,
        auth="bearer",
    )
    await r.call(
        "profile_patch",
        "PATCH",
        "/v1/me/profile",
        status=200,
        json_body={
            "display_name": "Asha R.",
            "phone_e164": "+919876543210",
            "country_code": "IN",
            "timezone": "Europe/London",
            "locale": "en-IN",
        },
        tokens=current,
        auth="bearer",
    )
    await r.call(
        "problem_validation_failed",
        "PATCH",
        "/v1/me/profile",
        status=422,
        json_body={"timezone": "Mars/Base", "phone_e164": "12345"},
        tokens=current,
        auth="bearer",
        problem=True,
    )
    h.clock.advance(minutes=6)  # the 5-minute re-authentication window has closed
    await r.call(
        "problem_reauth_required",
        "POST",
        "/v1/auth/email/change/start",
        status=403,
        json_body={"new_email": "someone.else@example.net"},
        tokens=current,
        auth="bearer+reauth",
        problem=True,
    )

    # --- password change ends the other sessions ----------------------------------------------
    await r.call(
        "password_change",
        "POST",
        "/v1/auth/password/change",
        status=204,
        json_body={"current_password": PASSWORD, "new_password": NEW_PASSWORD},
        tokens=current,
        auth="bearer",
    )
    await r.call(
        "problem_session_revoked",
        "GET",
        "/v1/me",
        status=401,
        tokens=first,
        auth="bearer",
        problem=True,
    )
    third = (
        await h.client.post(
            "/v1/auth/login",
            json={"email": NEW_EMAIL, "password": NEW_PASSWORD, "device": DEVICE},
        )
    ).json()
    await r.call(
        "session_revoke",
        "DELETE",
        f"/v1/auth/sessions/{third['session_id']}",
        status=204,
        tokens=current,
        auth="bearer",
        template="/v1/auth/sessions/{session_id}",
    )
    fourth = (
        await h.client.post(
            "/v1/auth/login",
            json={"email": NEW_EMAIL, "password": NEW_PASSWORD, "device": DEVICE},
        )
    ).json()
    await r.call("logout", "POST", "/v1/auth/logout", status=204, tokens=fourth, auth="bearer")

    # --- rate limit, expiry, sign out everywhere -------------------------------------------------
    for _ in range(2):
        await h.forgot(EMAIL)
    await r.call(
        "problem_rate_limited",
        "POST",
        "/v1/auth/password/forgot",
        status=429,
        json_body={"email": EMAIL},
        problem=True,
    )
    await r.call(
        "logout_all", "POST", "/v1/auth/logout-all", status=204, tokens=current, auth="bearer"
    )
    h.clock.advance(minutes=15)
    await r.call(
        "problem_token_expired",
        "GET",
        "/v1/me",
        status=401,
        tokens=current,
        auth="bearer",
        problem=True,
    )
    return r


def _committed() -> dict[str, str]:
    if not CONTRACT_DIR.is_dir():
        return {}
    return {p.name: p.read_text(encoding="utf-8") for p in sorted(CONTRACT_DIR.glob("*.json"))}


async def test_contract_files_match_the_api(h: Harness) -> None:
    recorder = await _scenario(h)
    generated = {**recorder.files, "index.json": recorder.index()}

    if UPDATE:
        CONTRACT_DIR.mkdir(parents=True, exist_ok=True)
        for stale in set(_committed()) - set(generated):
            (CONTRACT_DIR / stale).unlink()
        for name, text in generated.items():
            (CONTRACT_DIR / name).write_text(text, encoding="utf-8")

    committed = _committed()
    assert set(committed) == set(generated), (
        "contract file set differs; run with AFTERME_UPDATE_CONTRACTS=1 after an intentional "
        f"change. missing: {sorted(set(generated) - set(committed))}, "
        f"stale: {sorted(set(committed) - set(generated))}"
    )
    drifted = [name for name, text in generated.items() if committed[name] != text]
    assert not drifted, (
        f"API output drifted from docs/contracts/phase2: {drifted}. If the change is intended, "
        "regenerate with AFTERME_UPDATE_CONTRACTS=1 and tell the mobile team."
    )


async def test_every_documented_endpoint_has_a_contract(h: Harness) -> None:
    """The contract set covers every Phase 1 and Phase 2 JSON endpoint of the auth/me API."""
    recorder = await _scenario(h)
    covered = {(e["method"], e["path"]) for e in recorder.endpoints}
    assert covered == {
        ("POST", "/v1/auth/register/start"),
        ("POST", "/v1/auth/register/resend"),
        ("POST", "/v1/auth/register/verify"),
        ("POST", "/v1/auth/login"),
        ("POST", "/v1/auth/refresh"),
        ("GET", "/v1/me"),
        ("GET", "/v1/auth/sessions"),
        ("POST", "/v1/auth/reauth"),
        ("POST", "/v1/auth/password/forgot"),
        ("POST", "/v1/auth/email/change/start"),
        ("POST", "/v1/auth/email/change/verify"),
        ("PATCH", "/v1/me/profile"),
        ("POST", "/v1/auth/password/change"),
        ("DELETE", "/v1/auth/sessions/{session_id}"),
        ("POST", "/v1/auth/logout"),
        ("POST", "/v1/auth/logout-all"),
    }


async def test_contract_files_hold_only_placeholders(h: Harness) -> None:
    recorder = await _scenario(h)
    text = "\n".join(recorder.files.values())
    assert "pr_" not in text
    for real in recorder._uuids:
        assert real not in text
    for _kind, value in (k.split(":", 1) for k in recorder._tokens):
        assert value not in text
    for value in (EMAIL.upper(), "Bearer "):
        assert value not in text
