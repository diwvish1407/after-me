"""Golden contract files for the mobile app (``docs/contracts/phase3``): trusted contacts.

Same mechanism as Phase 2 (see ``recorder.py``). The scenario walks one account through the whole
contact lifecycle (add, list, edit, change address, invitation answers through the web pages,
resend, delete, entitlements) and records every JSON request and response, including the problem
shapes the app must handle. Regenerate after an intentional API change::

    AFTERME_UPDATE_CONTRACTS=1 uv run pytest tests/contracts

The files hold fictional placeholder values only.
"""

from __future__ import annotations

import os
import re
from typing import Any

import psycopg

from tests.contracts.recorder import Recorder
from tests.support import BACKEND_DIR, Harness, bearer, make_premium

CONTRACT_DIR = BACKEND_DIR.parent / "docs" / "contracts" / "phase3"
UPDATE = os.environ.get("AFTERME_UPDATE_CONTRACTS") == "1"

OWNER = "asha@example.com"

PHASE3_NOTES = (
    "Values are fictional placeholders; IDs are not real.",
    "Errors are RFC 9457 application/problem+json; see problems[].",
    "204 responses have no body and no response file.",
    "Contact objects never reveal whether an address is on the suppression list.",
    "The recipient pages (/c/open, /c/session, /c/invite/accept, /c/invite/decline, "
    "/c/optout, /c/optout/confirm) are server-rendered HTML forms, not JSON endpoints.",
)

Conn = psycopg.Connection[dict[str, Any]]


async def _scenario(h: Harness, owner_db: Conn) -> Recorder:
    r = Recorder(h, contract="afterme-phase3", notes=PHASE3_NOTES)
    tokens = await h.signup(OWNER)

    async def call(name: str, method: str, path: str, **kwargs: Any) -> Any:
        h.clock.advance(seconds=20)
        template = kwargs.pop("template", None)
        return await r.call(
            name, method, path, tokens=tokens, auth="bearer", template=template, **kwargs
        )

    # --- a free account: one contact ---------------------------------------------------------
    await call("entitlements_free", "GET", "/v1/me/entitlements", status=200)
    mom = (
        await call(
            "contact_create",
            "POST",
            "/v1/contacts",
            status=201,
            json_body={
                "display_name": "Mom",
                "relationship": "mother",
                "email": "mom@example.com",
                "phone_e164": "+919876543210",
            },
        )
    ).json()
    mom_url = f"/v1/contacts/{mom['id']}"
    template = "/v1/contacts/{contact_id}"
    await call(
        "problem_plan_limit_reached",
        "POST",
        "/v1/contacts",
        status=403,
        json_body={"display_name": "Dad", "relationship": "father", "email": "dad@example.com"},
        problem=True,
    )
    await call(
        "problem_cannot_be_own_email",
        "POST",
        "/v1/contacts",
        status=422,
        json_body={"display_name": "Me", "relationship": "other", "email": OWNER},
        problem=True,
    )
    await call("entitlements_free_in_use", "GET", "/v1/me/entitlements", status=200)
    await call("contact_get", "GET", mom_url, status=200, template=template)
    await call(
        "contact_patch",
        "PATCH",
        mom_url,
        status=200,
        json_body={"display_name": "Mum", "priority": 2, "phone_e164": None},
        template=template,
    )
    await call(
        "problem_validation_failed",
        "PATCH",
        mom_url,
        status=422,
        json_body={"display_name": "visit afterme.example", "priority": 0, "phone_e164": "123"},
        template=template,
        problem=True,
    )

    # --- upgrade: more contacts ---------------------------------------------------------------
    make_premium(owner_db, OWNER)
    await call("entitlements_premium", "GET", "/v1/me/entitlements", status=200)
    await call(
        "problem_contact_duplicate",
        "POST",
        "/v1/contacts",
        status=409,
        json_body={
            "display_name": "Mother",
            "relationship": "mother",
            "email": " Mom@Example.com ",
        },
        problem=True,
    )
    dad = (
        await call(
            "contact_create_other",
            "POST",
            "/v1/contacts",
            status=201,
            json_body={
                "display_name": "Dad",
                "relationship": "other",
                "relationship_label": "Godfather",
                "email": "dad@example.com",
                "priority": 1,
            },
        )
    ).json()
    sam = (
        await call(
            "contact_create_friend",
            "POST",
            "/v1/contacts",
            status=201,
            json_body={"display_name": "Sam", "relationship": "friend", "email": "sam@example.com"},
        )
    ).json()

    # --- the recipients answer on the web pages (not JSON, so not recorded) -------------------
    accepted = await h.portal_post("/c/invite/accept", h.invitation_token_for("dad@example.com"))
    assert accepted.status_code == 200
    declined = await h.portal_post("/c/invite/decline", h.invitation_token_for("sam@example.com"))
    assert declined.status_code == 200
    await call(
        "contact_get_verified", "GET", f"/v1/contacts/{dad['id']}", status=200, template=template
    )
    await call(
        "contact_get_declined", "GET", f"/v1/contacts/{sam['id']}", status=200, template=template
    )
    await call("contacts_list", "GET", "/v1/contacts", status=200)

    # --- changing the address starts again, resend, state and rate limit ----------------------
    await call(
        "contact_patch_email",
        "PATCH",
        mom_url,
        status=200,
        json_body={"email": "Mum.Rao@Example.com"},
        template=template,
    )
    await call(
        "contact_resend",
        "POST",
        f"{mom_url}/invitation",
        status=202,
        template=template + "/invitation",
    )
    await call(
        "problem_invalid_state",
        "POST",
        f"/v1/contacts/{dad['id']}/invitation",
        status=409,
        template=template + "/invitation",
        problem=True,
    )
    for _ in range(2):
        resent = await h.client.post(f"{mom_url}/invitation", headers=bearer(tokens))
        assert resent.status_code == 202
    await call(
        "problem_rate_limited",
        "POST",
        f"{mom_url}/invitation",
        status=429,
        template=template + "/invitation",
        problem=True,
    )

    # --- delete -------------------------------------------------------------------------------
    await call(
        "contact_delete", "DELETE", f"/v1/contacts/{sam['id']}", status=204, template=template
    )
    await call(
        "problem_not_found",
        "GET",
        f"/v1/contacts/{sam['id']}",
        status=404,
        template=template,
        problem=True,
    )
    await call("entitlements_after_delete", "GET", "/v1/me/entitlements", status=200)
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
        f"API output drifted from docs/contracts/phase3: {drifted}. If the change is intended, "
        "regenerate with AFTERME_UPDATE_CONTRACTS=1 and tell the mobile team."
    )


async def test_every_phase3_json_endpoint_has_a_contract(h: Harness, owner_db: Conn) -> None:
    recorder = await _scenario(h, owner_db)
    covered = {(e["method"], e["path"]) for e in recorder.endpoints}
    assert covered == {
        ("GET", "/v1/me/entitlements"),
        ("GET", "/v1/contacts"),
        ("POST", "/v1/contacts"),
        ("GET", "/v1/contacts/{contact_id}"),
        ("PATCH", "/v1/contacts/{contact_id}"),
        ("DELETE", "/v1/contacts/{contact_id}"),
        ("POST", "/v1/contacts/{contact_id}/invitation"),
    }
    problems = {p["name"] for p in recorder.problems}
    assert problems >= {
        "problem_plan_limit_reached",
        "problem_contact_duplicate",
        "problem_cannot_be_own_email",
        "problem_invalid_state",
        "problem_rate_limited",
        "problem_validation_failed",
        "problem_not_found",
    }


async def test_contract_files_hold_only_placeholders(h: Harness, owner_db: Conn) -> None:
    recorder = await _scenario(h, owner_db)
    text = "\n".join(recorder.files.values())
    for real in recorder._uuids:
        assert real not in text
    assert not re.search(r"\bci_[A-Za-z0-9_-]{20,}", text)  # no invitation token
    assert not re.search(r"\boo_[0-9a-f]{8}-", text)  # no opt-out token
    for forbidden in ("Bearer ", "csrf", "/c/open", "token"):
        assert forbidden not in text, forbidden
    assert "plan_limit_reached" in text
    assert "suppress" not in text.lower()
