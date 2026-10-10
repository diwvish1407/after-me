"""Golden contract files for the mobile app (``docs/contracts/phase5``): the escalation plan,
the incident object and timeline, the check-in that resolves an incident or is refused with
``safe_required``, and I'M SAFE.

Same mechanism as Phases 2 to 4 (see ``recorder.py``). The scenario is driven through the real
API plus the real worker (``Engine`` and ``Dispatcher``) on the frozen clock, because incidents
can only be created by the worker. Regenerate after an intentional API change::

    AFTERME_UPDATE_CONTRACTS=1 uv run pytest tests/contracts

The files hold fictional placeholder values only.
"""

from __future__ import annotations

import os
import re
from datetime import timedelta
from typing import Any

import psycopg

from app.api.container import build_worker_services
from app.engine.dispatcher import Dispatcher
from app.engine.runtime import Engine
from app.notifications.push import RecordingPushProvider
from tests.contracts.recorder import Recorder
from tests.support import BACKEND_DIR, Harness, bearer, make_premium

CONTRACT_DIR = BACKEND_DIR.parent / "docs" / "contracts" / "phase5"
UPDATE = os.environ.get("AFTERME_UPDATE_CONTRACTS") == "1"

OWNER = "asha@example.com"
SAFE_KEY = "5a5b5c5d-5e5f-4a60-8b61-626364656667"
CHECKIN_KEY = "6a6b6c6d-6e6f-4a70-8b71-727374757677"

PHASE5_NOTES = (
    "Values are fictional placeholders; IDs are not real.",
    "Errors are RFC 9457 application/problem+json; see problems[].",
    'The plan is a singleton with a strong ETag ("plan-<version>"); PUT needs If-Match '
    "(428 when absent, 412 when stale) and is refused with 409 incident_open during an incident.",
    "Incidents are created only by the worker; the API reads them and can stop one "
    "(a check-in, or POST /v1/incidents/{id}/safe).",
    '`requires` is "checkin" while nobody has been messaged and "safe" afterwards; a '
    'POST /v1/checkins in the "safe" state is 409 safe_required with the incident_id.',
    "POST /v1/incidents/{id}/safe needs a password re-auth within 5 minutes and an "
    "Idempotency-Key; a replay is marked Idempotent-Replayed: true.",
    "Push payloads carry no names or content: the app fetches the incident over the API.",
)

Conn = psycopg.Connection[dict[str, Any]]


async def _scenario(h: Harness, owner_db: Conn) -> Recorder:
    r = Recorder(h, contract="afterme-phase5", notes=PHASE5_NOTES)
    tokens = await h.signup(OWNER)
    make_premium(owner_db, OWNER)
    services = build_worker_services(
        h.settings, clock=h.clock, email_provider=h.app.state.services.mailer.provider
    )
    engine = Engine(services, instance_id="contract")
    dispatcher = Dispatcher(services, push=RecordingPushProvider())

    async def call(name: str, method: str, path: str, **kwargs: Any) -> Any:
        h.clock.advance(seconds=20)
        template = kwargs.pop("template", None)
        return await r.call(
            name, method, path, tokens=tokens, auth="bearer", template=template, **kwargs
        )

    async def relogin() -> None:
        nonlocal tokens
        tokens = await h.relogin(OWNER)

    try:
        # --- the plan -------------------------------------------------------------------------
        mom = (await h.add_contact(tokens, "mom@example.com")).json()
        owner_db.execute(
            "UPDATE trusted_contacts SET verification_status = 'verified', verified_at = now() "
            "WHERE id = %s",
            (mom["id"],),
        )
        await call("plan_get_default", "GET", "/v1/plan", status=200)
        await call("home_without_plan", "GET", "/v1/home", status=200)
        await call(
            "problem_activation_requirements_unmet",
            "POST",
            "/v1/checkin/activate",
            status=409,
            problem=True,
        )
        body = {
            "grace_minutes": 180,
            "stages": [{"id": None, "offset_minutes": 180, "notify_contact_ids": [mom["id"]]}],
        }
        await call(
            "problem_precondition_required",
            "PUT",
            "/v1/plan",
            status=428,
            json_body=body,
            problem=True,
        )
        await call(
            "problem_validation_failed",
            "PUT",
            "/v1/plan",
            status=422,
            json_body={
                "grace_minutes": 180,
                "stages": [{"id": None, "offset_minutes": 360, "notify_contact_ids": [mom["id"]]}],
            },
            headers={"If-Match": '"plan-1"'},
            problem=True,
        )
        await call(
            "plan_put",
            "PUT",
            "/v1/plan",
            status=200,
            json_body=body,
            headers={"If-Match": '"plan-1"'},
        )
        await call(
            "problem_precondition_failed",
            "PUT",
            "/v1/plan",
            status=412,
            json_body=body,
            headers={"If-Match": '"plan-1"'},
            problem=True,
        )
        await call("schedule_activate", "POST", "/v1/checkin/activate", status=200)
        await call("incidents_current_none", "GET", "/v1/incidents/current", status=200)

        # --- a missed deadline (the worker opens the incident) -------------------------------
        due = owner_db.execute(
            "SELECT next_due_at FROM checkin_configurations WHERE user_id = %s",
            (tokens["user"]["id"],),
        ).fetchone()["next_due_at"]
        h.clock.set(due + timedelta(seconds=1))
        await engine.tick()
        await dispatcher.dispatch()
        await relogin()
        incident = (
            await call("incident_current", "GET", "/v1/incidents/current", status=200)
        ).json()["incident"]
        await call("home_incident", "GET", "/v1/home", status=200)
        await call(
            "incident_get",
            "GET",
            f"/v1/incidents/{incident['id']}",
            status=200,
            template="/v1/incidents/{incident_id}",
        )
        current_plan = await h.client.get("/v1/plan", headers=bearer(tokens))
        await call(
            "problem_plan_incident_open",
            "PUT",
            "/v1/plan",
            status=409,
            json_body=body,
            headers={"If-Match": current_plan.headers["etag"]},
            problem=True,
        )

        # --- the reminders, then the first stage runs and the contact is messaged -------------
        for minutes in (91, 166):
            h.clock.set(due + timedelta(minutes=minutes))
            await engine.tick()
            await dispatcher.dispatch()
        h.clock.set(due + timedelta(minutes=180, seconds=1))
        await engine.tick()
        h.clock.set(due + timedelta(minutes=186))
        await dispatcher.dispatch()
        await relogin()
        await call("incident_after_stage", "GET", "/v1/incidents/current", status=200)
        await call(
            "problem_safe_required",
            "POST",
            "/v1/checkins",
            status=409,
            headers={"Idempotency-Key": CHECKIN_KEY},
            problem=True,
        )
        await call(
            "problem_reauth_required",
            "POST",
            f"/v1/incidents/{incident['id']}/safe",
            status=403,
            headers={"Idempotency-Key": SAFE_KEY},
            problem=True,
            template="/v1/incidents/{incident_id}/safe",
        )
        assert (await h.reauth(tokens)).status_code == 204
        await call(
            "incident_safe",
            "POST",
            f"/v1/incidents/{incident['id']}/safe",
            status=200,
            headers={"Idempotency-Key": SAFE_KEY},
            template="/v1/incidents/{incident_id}/safe",
        )
        await call(
            "incident_safe_replay",
            "POST",
            f"/v1/incidents/{incident['id']}/safe",
            status=200,
            headers={"Idempotency-Key": SAFE_KEY},
            template="/v1/incidents/{incident_id}/safe",
            record_headers=("ETag", "Idempotent-Replayed"),
        )
        await call(
            "problem_invalid_state",
            "POST",
            f"/v1/incidents/{incident['id']}/safe",
            status=409,
            headers={"Idempotency-Key": "7a7b7c7d-7e7f-4a80-8b81-828384858687"},
            problem=True,
            template="/v1/incidents/{incident_id}/safe",
        )
        await call("incidents_list", "GET", "/v1/incidents", status=200)

        # --- a second miss that the person settles with an ordinary check-in ------------------
        next_due = owner_db.execute(
            "SELECT next_due_at FROM checkin_configurations WHERE user_id = %s",
            (tokens["user"]["id"],),
        ).fetchone()["next_due_at"]
        h.clock.set(next_due + timedelta(seconds=1))
        await engine.tick()
        await relogin()
        await call(
            "checkin_resolves_incident",
            "POST",
            "/v1/checkins",
            status=200,
            headers={"Idempotency-Key": "8a8b8c8d-8e8f-4a90-8b91-929394959697"},
        )
        await call("incidents_list_after", "GET", "/v1/incidents", status=200)
    finally:
        await services.db.dispose()
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
        f"API output drifted from docs/contracts/phase5: {drifted}. If the change is intended, "
        "regenerate with AFTERME_UPDATE_CONTRACTS=1 and tell the mobile team."
    )


async def test_every_phase5_json_endpoint_has_a_contract(h: Harness, owner_db: Conn) -> None:
    recorder = await _scenario(h, owner_db)
    covered = {(e["method"], e["path"]) for e in recorder.endpoints}
    assert covered >= {
        ("GET", "/v1/plan"),
        ("PUT", "/v1/plan"),
        ("GET", "/v1/incidents/current"),
        ("GET", "/v1/incidents"),
        ("GET", "/v1/incidents/{incident_id}"),
        ("POST", "/v1/incidents/{incident_id}/safe"),
        ("POST", "/v1/checkins"),
        ("GET", "/v1/home"),
    }
    problems = {p["name"] for p in recorder.problems}
    assert problems >= {
        "problem_precondition_required",
        "problem_precondition_failed",
        "problem_validation_failed",
        "problem_activation_requirements_unmet",
        "problem_plan_incident_open",
        "problem_safe_required",
        "problem_reauth_required",
        "problem_invalid_state",
    }


async def test_contract_files_hold_only_placeholders(h: Harness, owner_db: Conn) -> None:
    recorder = await _scenario(h, owner_db)
    text = "\n".join(recorder.files.values()) + recorder.index()
    for real in recorder._uuids:
        assert real not in text
    for forbidden in ("Bearer ", "access_token", "refresh_token", "mom@example.com", "oo_"):
        assert forbidden not in text, forbidden
    assert not re.search(r"[A-Za-z0-9_-]{40,}", text.replace("example", ""))
