"""Golden contract files for the mobile app (``docs/contracts/phase6``): instruction categories,
instructions (create, read, list, change, delete), the problems they can answer with, the plan's
``release_count`` and ``409 stage_in_use``, and the password step-up the plan and contacts ask
for once check-ins are on.

Same mechanism as Phases 2 to 5 (see ``recorder.py``). Regenerate after an intentional change::

    AFTERME_UPDATE_CONTRACTS=1 uv run pytest tests/contracts

The files hold fictional placeholder values only.
"""

from __future__ import annotations

import os
import re
from typing import Any

import psycopg

from tests.contracts.recorder import Recorder
from tests.support import BACKEND_DIR, Harness, make_premium

CONTRACT_DIR = BACKEND_DIR.parent / "docs" / "contracts" / "phase6"
UPDATE = os.environ.get("AFTERME_UPDATE_CONTRACTS") == "1"

OWNER = "asha@example.com"

PHASE6_NOTES = (
    "Values are fictional placeholders; IDs are not real.",
    "Errors are RFC 9457 application/problem+json; see problems[].",
    "Title and body exist only as ciphertext on the server; the list never carries a body.",
    "A recipient is a contact of yours and a stage of yours whose offset is at least 1440 "
    "minutes; anything else owned by someone else is 404.",
    "A stage that holds an instruction cannot be removed: 409 stage_in_use with the IDs.",
    "While the check-in schedule is active, changing the plan and removing, switching off or "
    "re-addressing a contact who is in a stage answer 403 reauth_required until the password "
    "has been confirmed (POST /v1/auth/reauth, valid 5 minutes).",
)

Conn = psycopg.Connection[dict[str, Any]]


async def _scenario(h: Harness, owner_db: Conn) -> Recorder:
    r = Recorder(h, contract="afterme-phase6", notes=PHASE6_NOTES)
    tokens = await h.signup(OWNER)
    make_premium(owner_db, OWNER)

    async def call(name: str, method: str, path: str, **kwargs: Any) -> Any:
        h.clock.advance(seconds=20)
        template = kwargs.pop("template", None)
        return await r.call(
            name, method, path, tokens=tokens, auth="bearer", template=template, **kwargs
        )

    mom = (await h.add_contact(tokens, "mom@example.com", name="Mom")).json()
    dad = (await h.add_contact(tokens, "dad@example.com", name="Dad")).json()
    for contact in (mom, dad):
        owner_db.execute(
            "UPDATE trusted_contacts SET verification_status = 'verified', verified_at = now() "
            "WHERE id = %s",
            (contact["id"],),
        )
    plan = (
        await h.client.get(
            "/v1/plan", headers={"Authorization": f"Bearer {tokens['access_token']}"}
        )
    ).json()
    put = await h.client.put(
        "/v1/plan",
        json={
            "grace_minutes": 180,
            "stages": [
                {"id": None, "offset_minutes": 180, "notify_contact_ids": [mom["id"]]},
                {"id": None, "offset_minutes": 1440, "notify_contact_ids": [dad["id"]]},
            ],
        },
        headers={
            "Authorization": f"Bearer {tokens['access_token']}",
            "If-Match": '"plan-1"',
        },
    )
    assert put.status_code == 200, (put.text, plan)
    stages = put.json()["stages"]

    await call("categories_list", "GET", "/v1/instruction-categories", status=200)
    await call("instructions_list_empty", "GET", "/v1/instructions", status=200)
    await call(
        "problem_release_stage_too_early",
        "POST",
        "/v1/instructions",
        status=422,
        json_body={
            "category": "home",
            "title": "House emergency",
            "body": "The spare key is with Mrs. Sharma at flat 3B.",
            "recipients": [{"contact_id": dad["id"], "release_stage_id": stages[0]["id"]}],
        },
        problem=True,
    )
    created = await call(
        "instruction_create",
        "POST",
        "/v1/instructions",
        status=201,
        json_body={
            "category": "home",
            "title": "House emergency",
            "body": "The spare key is with Mrs. Sharma at flat 3B.\nCall her before you go.",
            "status": "active",
            "recipients": [{"contact_id": dad["id"], "release_stage_id": stages[1]["id"]}],
        },
    )
    instruction_id = created.json()["id"]
    await call(
        "instruction_get",
        "GET",
        f"/v1/instructions/{instruction_id}",
        status=200,
        template="/v1/instructions/{instruction_id}",
    )
    await call("instructions_list", "GET", "/v1/instructions?category=home", status=200)
    await call(
        "instruction_patch",
        "PATCH",
        f"/v1/instructions/{instruction_id}",
        status=200,
        json_body={"title": "House emergency (updated)", "status": "inactive"},
        template="/v1/instructions/{instruction_id}",
    )
    await call(
        "problem_validation_failed",
        "POST",
        "/v1/instructions",
        status=422,
        json_body={"category": "home", "title": "", "body": "x"},
        problem=True,
    )
    await call(
        "problem_not_found",
        "GET",
        "/v1/instructions/00000000-0000-4000-8000-000000000000",
        status=404,
        problem=True,
        template="/v1/instructions/{instruction_id}",
    )
    await call("plan_with_release_count", "GET", "/v1/plan", status=200)
    await call(
        "instruction_activate",
        "PATCH",
        f"/v1/instructions/{instruction_id}",
        status=200,
        json_body={"status": "active"},
        template="/v1/instructions/{instruction_id}",
    )
    await call("plan_with_release_count_active", "GET", "/v1/plan", status=200)
    current_plan = await h.client.get(
        "/v1/plan", headers={"Authorization": f"Bearer {tokens['access_token']}"}
    )
    await call(
        "problem_stage_in_use",
        "PUT",
        "/v1/plan",
        status=409,
        json_body={
            "grace_minutes": 180,
            "stages": [
                {
                    "id": stages[0]["id"],
                    "offset_minutes": 180,
                    "notify_contact_ids": [mom["id"]],
                }
            ],
        },
        headers={"If-Match": current_plan.headers["etag"]},
        problem=True,
    )

    # --- the step-up once check-ins are on ----------------------------------------------------
    await call("schedule_activate", "POST", "/v1/checkin/activate", status=200)
    await call(
        "problem_reauth_plan",
        "PUT",
        "/v1/plan",
        status=403,
        json_body={
            "grace_minutes": 240,
            "stages": [
                {"id": stages[0]["id"], "offset_minutes": 240, "notify_contact_ids": [mom["id"]]},
                {"id": stages[1]["id"], "offset_minutes": 1440, "notify_contact_ids": [dad["id"]]},
            ],
        },
        headers={"If-Match": current_plan.headers["etag"]},
        problem=True,
    )
    await call(
        "problem_reauth_contact_delete",
        "DELETE",
        f"/v1/contacts/{dad['id']}",
        status=403,
        problem=True,
        template="/v1/contacts/{contact_id}",
    )
    await call(
        "problem_reauth_contact_off",
        "PATCH",
        f"/v1/contacts/{dad['id']}",
        status=403,
        json_body={"is_active": False},
        problem=True,
        template="/v1/contacts/{contact_id}",
    )
    await call(
        "problem_reauth_instruction",
        "DELETE",
        f"/v1/instructions/{instruction_id}",
        status=403,
        problem=True,
        template="/v1/instructions/{instruction_id}",
    )
    assert (await h.reauth(tokens)).status_code == 204
    await call(
        "instruction_delete",
        "DELETE",
        f"/v1/instructions/{instruction_id}",
        status=204,
        template="/v1/instructions/{instruction_id}",
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
        f"API output drifted from docs/contracts/phase6: {drifted}. If the change is intended, "
        "regenerate with AFTERME_UPDATE_CONTRACTS=1 and tell the mobile team."
    )


async def test_every_phase6_json_endpoint_has_a_contract(h: Harness, owner_db: Conn) -> None:
    recorder = await _scenario(h, owner_db)
    covered = {(e["method"], e["path"]) for e in recorder.endpoints}
    assert covered >= {
        ("GET", "/v1/instruction-categories"),
        ("GET", "/v1/instructions"),
        ("POST", "/v1/instructions"),
        ("GET", "/v1/instructions/{instruction_id}"),
        ("PATCH", "/v1/instructions/{instruction_id}"),
        ("DELETE", "/v1/instructions/{instruction_id}"),
    }
    problems = {p["name"] for p in recorder.problems}
    assert problems >= {
        "problem_release_stage_too_early",
        "problem_validation_failed",
        "problem_not_found",
        "problem_stage_in_use",
        "problem_reauth_plan",
        "problem_reauth_contact_delete",
        "problem_reauth_contact_off",
        "problem_reauth_instruction",
    }


async def test_contract_files_hold_only_placeholders(h: Harness, owner_db: Conn) -> None:
    recorder = await _scenario(h, owner_db)
    text = "\n".join(recorder.files.values()) + recorder.index()
    for real in recorder._uuids:
        assert real not in text
    for forbidden in (
        "Bearer ",
        "access_token",
        "refresh_token",
        "mom@example.com",
        'ciphertext":',
    ):
        assert forbidden not in text, forbidden
    assert not re.search(r"[A-Za-z0-9_-]{40,}", text.replace("example", ""))
