"""Golden contract files for the mobile app (``docs/contracts/phase7``): the Activity feed, the
account export and account deletion, with the problems they can answer with.

Same mechanism as Phases 2 to 6 (see ``recorder.py``). Regenerate after an intentional change::

    AFTERME_UPDATE_CONTRACTS=1 uv run pytest tests/contracts

The files hold fictional placeholder values only.
"""

from __future__ import annotations

import os
import re
from typing import Any

from tests.contracts.recorder import Recorder
from tests.engine.test_release import Portal, _released
from tests.support import BACKEND_DIR, make_premium
from tests.world import World

CONTRACT_DIR = BACKEND_DIR.parent / "docs" / "contracts" / "phase7"
UPDATE = os.environ.get("AFTERME_UPDATE_CONTRACTS") == "1"

OWNER = "asha@example.com"

PHASE7_NOTES = (
    "Values are fictional placeholders; IDs are not real.",
    "Errors are RFC 9457 application/problem+json; see problems[].",
    "GET /v1/activity is newest first with an opaque cursor. Display strings are composed by "
    "the app from `action` and `params`; an action the app does not know is shown generically.",
    "POST /v1/me/export and DELETE /v1/me need the password to have been confirmed within the "
    "last 60 seconds (POST /v1/auth/reauth); an export spends the confirmation, and exports are "
    "limited to 3 an hour; the export is a file download.",
    "DELETE /v1/me ends every session: the app must go back to sign-in whatever else happens.",
    "incident_with_release_viewed and incident_closed_release_revoked show the incident's "
    "`releases` as the owner sees them: viewed once; then taken back with a title that can no "
    "longer be opened (null).",
)


async def _scenario(world: World) -> Recorder:
    h, owner_db = world.h, world.db
    r = Recorder(h, contract="afterme-phase7", notes=PHASE7_NOTES)
    tokens = await h.signup(OWNER)
    make_premium(owner_db, OWNER)

    async def call(name: str, method: str, path: str, **kwargs: Any) -> Any:
        h.clock.advance(seconds=20)
        template = kwargs.pop("template", None)
        return await r.call(
            name, method, path, tokens=tokens, auth="bearer", template=template, **kwargs
        )

    mom = (await h.add_contact(tokens, "mom@example.com", name="Mom")).json()
    owner_db.execute(
        "UPDATE trusted_contacts SET verification_status = 'verified', verified_at = %s "
        "WHERE id = %s",
        (h.clock.current, mom["id"]),
    )
    auth = {"Authorization": f"Bearer {tokens['access_token']}"}
    put = await h.client.put(
        "/v1/plan",
        json={
            "grace_minutes": 180,
            "stages": [{"id": None, "offset_minutes": 180, "notify_contact_ids": [mom["id"]]}],
        },
        headers={**auth, "If-Match": '"plan-1"'},
    )
    assert put.status_code == 200, put.text
    made = await h.client.post(
        "/v1/instructions",
        json={
            "category": "home",
            "title": "House emergency",
            "body": "The spare key is with Mrs. Sharma at flat 3B.",
            "status": "active",
            "recipients": [],
        },
        headers=auth,
    )
    assert made.status_code == 201, made.text
    assert (await h.client.post("/v1/checkin/activate", headers=auth)).status_code == 200
    assert (
        await h.client.post(
            "/v1/checkins", headers={**auth, "Idempotency-Key": "contract-key-0000000001"}
        )
    ).status_code == 200

    await call("activity_first_page", "GET", "/v1/activity?limit=3", status=200)
    page = (await h.client.get("/v1/activity?limit=3", headers=auth)).json()
    await call(
        "activity_next_page",
        "GET",
        f"/v1/activity?limit=3&cursor={page['next_cursor']}",
        status=200,
        template="/v1/activity",
    )
    await call(
        "problem_activity_bad_cursor",
        "GET",
        "/v1/activity?cursor=not-a-cursor",
        status=422,
        problem=True,
        template="/v1/activity",
    )

    await call("problem_reauth_export", "POST", "/v1/me/export", status=403, problem=True)
    await call(
        "problem_reauth_delete",
        "DELETE",
        "/v1/me",
        status=403,
        json_body={"confirm": "DELETE"},
        problem=True,
    )
    assert (await h.reauth(tokens)).status_code == 204
    await call(
        "export",
        "POST",
        "/v1/me/export",
        status=200,
        record_headers=("Content-Disposition",),
    )
    for _ in range(2):  # the second and third export of the hour
        assert (await h.reauth(tokens)).status_code == 204
        assert (
            await h.client.post(
                "/v1/me/export", headers={"Authorization": f"Bearer {tokens['access_token']}"}
            )
        ).status_code == 200
    assert (await h.reauth(tokens)).status_code == 204
    await call("problem_export_rate_limited", "POST", "/v1/me/export", status=429, problem=True)
    assert (await h.reauth(tokens)).status_code == 204  # the exports spent the confirmation
    await call(
        "problem_delete_unconfirmed",
        "DELETE",
        "/v1/me",
        status=422,
        json_body={"confirm": "delete"},
        problem=True,
    )
    await call("account_delete", "DELETE", "/v1/me", status=202, json_body={"confirm": "DELETE"})

    # --- what the owner sees of a release (the incident's `releases`), for the incident UI ----
    # A different person, run last: the clock moves a day and more.
    other = await _released(world)  # an instruction released to Brother at stage 2
    assert "House emergency" in (await Portal(world).reach_content(other)).text  # viewed once
    await world.login(other)
    seen = await r.call(
        "incident_with_release_viewed",
        "GET",
        "/v1/incidents/current",
        status=200,
        tokens=other.tokens,
        auth="bearer",
    )
    incident_id = seen.json()["incident"]["id"]
    await world.safe(other, incident_id)  # I'M SAFE: everything released is taken back
    assert (await h.reauth(other.tokens)).status_code == 204
    gone = await h.client.delete(
        f"/v1/instructions/{other.contacts['_instruction']}", headers=other.headers
    )
    assert gone.status_code == 204  # its text is wiped: the title can no longer be opened
    await r.call(
        "incident_closed_release_revoked",
        "GET",
        f"/v1/incidents/{incident_id}",
        status=200,
        tokens=other.tokens,
        auth="bearer",
        template="/v1/incidents/{incident_id}",
    )
    return r


def _committed() -> dict[str, str]:
    if not CONTRACT_DIR.is_dir():
        return {}
    return {p.name: p.read_text(encoding="utf-8") for p in sorted(CONTRACT_DIR.glob("*.json"))}


async def test_contract_files_match_the_api(world: World) -> None:
    recorder = await _scenario(world)
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
        f"API output drifted from docs/contracts/phase7: {drifted}. If the change is intended, "
        "regenerate with AFTERME_UPDATE_CONTRACTS=1 and tell the mobile team."
    )


async def test_every_phase7_json_endpoint_has_a_contract(world: World) -> None:
    recorder = await _scenario(world)
    covered = {(e["method"], e["path"]) for e in recorder.endpoints}
    assert covered >= {
        ("GET", "/v1/activity"),
        ("POST", "/v1/me/export"),
        ("DELETE", "/v1/me"),
        ("GET", "/v1/incidents/current"),
        ("GET", "/v1/incidents/{incident_id}"),
    }
    problems = {p["name"] for p in recorder.problems}
    assert problems >= {
        "problem_activity_bad_cursor",
        "problem_reauth_export",
        "problem_reauth_delete",
        "problem_delete_unconfirmed",
        "problem_export_rate_limited",
    }


async def test_contract_files_hold_only_placeholders(world: World) -> None:
    recorder = await _scenario(world)
    text = "\n".join(recorder.files.values()) + recorder.index()
    for real in recorder._uuids:
        assert real not in text
    for forbidden in ("Bearer ", "access_token", "refresh_token", "password_hash", "ciphertext"):
        assert forbidden not in text, forbidden
    assert not re.search(r"[A-Za-z0-9_-]{40,}", text.replace("example", ""))
