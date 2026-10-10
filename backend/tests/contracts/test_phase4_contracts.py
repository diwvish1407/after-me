"""Golden contract files for the mobile app (``docs/contracts/phase4``): the check-in schedule,
I'M OK, history and the Home aggregate.

Same mechanism as Phases 2 and 3 (see ``recorder.py``). The scenario walks one account from a
fresh signup through saving a schedule, activating it, checking in (and retrying), reading the
history and Home, and deactivating, and records every JSON request and response, including the
problem shapes the app must handle and the ``ETag`` / ``If-Match`` / ``Idempotency-Key`` headers.
Regenerate after an intentional API change::

    AFTERME_UPDATE_CONTRACTS=1 uv run pytest tests/contracts

The files hold fictional placeholder values only.
"""

from __future__ import annotations

import os
import re
from typing import Any

import psycopg

from tests.contracts.recorder import Recorder
from tests.support import BACKEND_DIR, Harness, bearer

CONTRACT_DIR = BACKEND_DIR.parent / "docs" / "contracts" / "phase4"
UPDATE = os.environ.get("AFTERME_UPDATE_CONTRACTS") == "1"

OWNER = "asha@example.com"
IDEMPOTENCY_KEY = "0f0e0d0c-0b0a-4908-8706-050403020100"
SECOND_KEY = "1f1e1d1c-1b1a-4918-8716-151413121110"

PHASE4_NOTES = (
    "Values are fictional placeholders; IDs are not real.",
    "Errors are RFC 9457 application/problem+json; see problems[].",
    "Instants are RFC 3339 UTC with a Z suffix; due_local_time is 24-hour HH:MM.",
    'The schedule is a singleton with a strong ETag ("sched-<version>"). PUT needs If-Match: '
    "428 when absent, 412 when stale. A check-in does not change the version.",
    "POST /v1/checkins needs an Idempotency-Key (16 to 64 URL-safe characters). Reuse the SAME "
    "key for every retry of one tap: the original answer is replayed, marked with the response "
    "header Idempotent-Replayed: true. A replay's server_time is the ORIGINAL one: calibrate the "
    "clock offset from GET /v1/home (or a non-replayed response), never from a replay.",
    "next_due_at is null while the schedule is inactive.",
    "incident is always null in Phase 4; it becomes an object when escalation exists.",
    "The deadline is computed by the server only; client_reported_at is informational.",
    "Lengthening interval_days of an ACTIVE schedule needs a password re-auth within the last "
    "5 minutes (403 reauth_required, as for deactivate); an inactive schedule does not.",
)

Conn = psycopg.Connection[dict[str, Any]]


async def _scenario(h: Harness, owner_db: Conn) -> Recorder:
    r = Recorder(h, contract="afterme-phase4", notes=PHASE4_NOTES)
    tokens = await h.signup(OWNER)
    schedule = "/v1/checkin/schedule"
    checkins = "/v1/checkins"

    async def call(name: str, method: str, path: str, **kwargs: Any) -> Any:
        h.clock.advance(seconds=20)
        template = kwargs.pop("template", None)
        return await r.call(
            name, method, path, tokens=tokens, auth="bearer", template=template, **kwargs
        )

    # --- a new account -----------------------------------------------------------------------
    await call("schedule_get_default", "GET", schedule, status=200)
    await call("home_new", "GET", "/v1/home", status=200)
    await call(
        "problem_precondition_required",
        "PUT",
        schedule,
        status=428,
        json_body={"interval_days": 2, "due_local_time": "21:30", "reminder_lead_minutes": 30},
        problem=True,
    )
    await call(
        "problem_validation_failed",
        "PUT",
        schedule,
        status=422,
        json_body={"interval_days": 0, "due_local_time": "24:00", "reminder_lead_minutes": 45},
        headers={"If-Match": '"sched-1"'},
        problem=True,
    )
    await call(
        "schedule_put",
        "PUT",
        schedule,
        status=200,
        json_body={"interval_days": 2, "due_local_time": "21:30", "reminder_lead_minutes": 30},
        headers={"If-Match": '"sched-1"'},
    )
    await call(
        "problem_precondition_failed",
        "PUT",
        schedule,
        status=412,
        json_body={"interval_days": 3, "due_local_time": "21:30", "reminder_lead_minutes": 30},
        headers={"If-Match": '"sched-1"'},
        problem=True,
    )
    await call(
        "problem_activation_requirements_unmet",
        "POST",
        "/v1/checkin/activate",
        status=409,
        problem=True,
    )
    await call(
        "checkin_inactive",
        "POST",
        checkins,
        status=200,
        json_body={"client_reported_at": "2026-10-08T14:30:40+05:30"},
        headers={"Idempotency-Key": SECOND_KEY},
    )

    # --- add a contact (Phase 3 contract), activate -----------------------------------------
    assert (await h.add_contact(tokens, "mom@example.com")).status_code == 201
    await h.plan_for_contacts(tokens)  # the plan is the Phase 5 contract
    await call("schedule_activate", "POST", "/v1/checkin/activate", status=200)
    await call("home_active", "GET", "/v1/home", status=200)
    await call(
        "problem_reauth_required_lengthen",
        "PUT",
        schedule,
        status=403,
        json_body={"interval_days": 30, "due_local_time": "21:30", "reminder_lead_minutes": 30},
        headers={"If-Match": '"sched-3"'},
        problem=True,
    )

    # --- check in, retry, reuse ---------------------------------------------------------------
    await call(
        "checkin_record",
        "POST",
        checkins,
        status=200,
        json_body={"client_reported_at": "2026-10-08T14:31:02+05:30"},
        headers={"Idempotency-Key": IDEMPOTENCY_KEY},
    )
    await call(
        "checkin_replay",
        "POST",
        checkins,
        status=200,
        json_body={"client_reported_at": "2026-10-08T14:31:02+05:30"},
        headers={"Idempotency-Key": IDEMPOTENCY_KEY},
        record_headers=("ETag", "Idempotent-Replayed"),
    )
    await call("problem_idempotency_key_missing", "POST", checkins, status=422, problem=True)
    await call(
        "checkin_history",
        "GET",
        f"{checkins}?limit=1",
        status=200,
        template=checkins,
    )

    # --- deactivation needs the password; an open incident blocks every change ----------------
    await call(
        "problem_reauth_required", "POST", "/v1/checkin/deactivate", status=403, problem=True
    )
    assert (await h.reauth(tokens)).status_code == 204
    await call("schedule_deactivate", "POST", "/v1/checkin/deactivate", status=200)
    await call("home_inactive", "GET", "/v1/home", status=200)

    owner_db.execute(
        "UPDATE checkin_configurations SET status = 'incident_open', "
        "baseline_at = now(), next_due_at = now() + interval '1 day' WHERE user_id = %s",
        (tokens["user"]["id"],),
    )
    current = await h.client.get(schedule, headers=bearer(tokens))
    await call(
        "problem_incident_open",
        "PUT",
        schedule,
        status=409,
        json_body={"interval_days": 1, "due_local_time": "20:00", "reminder_lead_minutes": 60},
        headers={"If-Match": current.headers["etag"]},
        problem=True,
    )
    return r


def _committed() -> dict[str, str]:
    if not CONTRACT_DIR.is_dir():
        return {}
    return {p.name: p.read_text(encoding="utf-8") for p in sorted(CONTRACT_DIR.glob("*.json"))}


async def test_contract_files_match_the_api(h: Harness, owner_db: Conn) -> None:
    recorder = await _scenario(h, owner_db)
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
        f"API output drifted from docs/contracts/phase4: {drifted}. If the change is intended, "
        "regenerate with AFTERME_UPDATE_CONTRACTS=1 and tell the mobile team."
    )


async def test_every_phase4_json_endpoint_has_a_contract(h: Harness, owner_db: Conn) -> None:
    recorder = await _scenario(h, owner_db)
    covered = {(e["method"], e["path"]) for e in recorder.endpoints}
    assert covered == {
        ("GET", "/v1/checkin/schedule"),
        ("PUT", "/v1/checkin/schedule"),
        ("POST", "/v1/checkin/activate"),
        ("POST", "/v1/checkin/deactivate"),
        ("POST", "/v1/checkins"),
        ("GET", "/v1/checkins"),
        ("GET", "/v1/home"),
    }
    problems = {p["name"] for p in recorder.problems}
    assert problems >= {
        "problem_precondition_required",
        "problem_precondition_failed",
        "problem_validation_failed",
        "problem_activation_requirements_unmet",
        "problem_idempotency_key_missing",
        "problem_reauth_required",
        "problem_reauth_required_lengthen",
        "problem_incident_open",
    }


async def test_the_contract_records_the_headers_the_app_must_send_and_read(
    h: Harness, owner_db: Conn
) -> None:
    recorder = await _scenario(h, owner_db)
    by_name = {e["name"]: e for e in recorder.endpoints + recorder.problems}
    assert by_name["schedule_get_default"]["response_headers"] == {"ETag": '"sched-1"'}
    assert by_name["schedule_put"]["request_headers"] == {"If-Match": '"sched-1"'}
    assert by_name["schedule_put"]["response_headers"] == {"ETag": '"sched-2"'}
    assert "Idempotency-Key" in by_name["checkin_record"]["request_headers"]
    assert by_name["checkin_replay"]["response_headers"] == {"Idempotent-Replayed": "true"}
    assert "response_headers" not in by_name["checkin_record"]
    assert by_name["problem_activation_requirements_unmet"]["status"] == 409


async def test_contract_files_hold_only_placeholders(h: Harness, owner_db: Conn) -> None:
    recorder = await _scenario(h, owner_db)
    text = "\n".join(recorder.files.values()) + recorder.index()
    for real in recorder._uuids:
        assert real not in text
    for forbidden in ("Bearer ", "access_token", "refresh_token", "mom@example.com"):
        assert forbidden not in text, forbidden
    assert not re.search(r"[A-Za-z0-9_-]{40,}", text.replace("example", ""))
