"""Golden contract files for the mobile app (``docs/contracts/phase8``): the phone's push
registration and the exact push payloads the server sends.

Same mechanism as the earlier phases (see ``recorder.py``); regenerate after an intentional
change with ``AFTERME_UPDATE_CONTRACTS=1 uv run pytest tests/contracts``.
"""

from __future__ import annotations

import json
import os
from typing import Any

from app.notifications import outbox
from app.notifications.providers.fcm import fcm_payload
from app.notifications.render import PUSH_COPY, push_message
from tests.contracts.recorder import Recorder
from tests.support import BACKEND_DIR, DEVICE, Harness

CONTRACT_DIR = BACKEND_DIR.parent / "docs" / "contracts" / "phase8"
UPDATE = os.environ.get("AFTERME_UPDATE_CONTRACTS") == "1"

NOTES = (
    "Values are fictional placeholders; IDs are not real.",
    "Errors are RFC 9457 application/problem+json; see problems[].",
    "PUT /v1/devices/current is how the app hands over its FCM registration token; the token is "
    "never echoed back. Omitting push_token keeps the registered one, null removes it.",
    "push_payloads.json lists, for every push type, the `message` the server sends to FCM (minus "
    "the token). The app must act only on `data.type` and `data.incident_id` and must fetch "
    "everything else from the API: a payload carries no authority (SECURITY T21).",
)

# The documented routes the app opens for each push type (tab, then an optional incident).
ROUTES: dict[str, str] = {
    outbox.USER_PRE_REMINDER: "home",
    outbox.USER_MISSED: "home",
    outbox.USER_MIDPOINT: "home",
    outbox.USER_LAST_CHANCE: "home",
    outbox.USER_STAGE_DEFERRED: "home",
    outbox.USER_STAGE_EXECUTED: "home",
    outbox.USER_FINAL_WARNING: "home",
    outbox.USER_ALL_CLEAR: "home",
    outbox.USER_HOLD_NOTICE: "home",
    outbox.USER_CONTACT_UNREACHABLE: "people",
}
_INCIDENT_ID = "11111111-1111-4111-8111-111111111111"


def _payloads() -> dict[str, Any]:
    items = []
    for template in PUSH_COPY:
        with_incident = template not in (outbox.USER_PRE_REMINDER, outbox.USER_CONTACT_UNREACHABLE)
        message = push_message(
            template, token="TOKEN", incident_id=_INCIDENT_ID if with_incident else None
        )
        assert message is not None
        items.append(
            {
                "type": template,
                "opens": ROUTES[template],
                "message": fcm_payload(message),
            }
        )
    return {"contract": "afterme-phase8", "version": 1, "payloads": items}


async def _scenario(h: Harness) -> Recorder:
    r = Recorder(h, contract="afterme-phase8", notes=NOTES)
    tokens = await h.signup("asha@example.com")
    device_id = tokens["device_id"]
    r.literal(str(device_id), "00000000-0000-4000-8000-0000000000d1")

    async def call(name: str, **kwargs: Any) -> Any:
        h.clock.advance(seconds=20)
        return await r.call(name, tokens=tokens, auth="bearer", **kwargs)

    body = {**DEVICE, "push_token": "fcm-token-example-" + "x" * 24}
    await call(
        "device_register", method="PUT", path="/v1/devices/current", status=200, json_body=body
    )
    await call(
        "device_keep_token",
        method="PUT",
        path="/v1/devices/current",
        status=200,
        json_body=dict(DEVICE),
    )
    await call(
        "device_remove_token",
        method="PUT",
        path="/v1/devices/current",
        status=200,
        json_body={**DEVICE, "push_token": None},
    )
    await call(
        "problem_device_bad_token",
        method="PUT",
        path="/v1/devices/current",
        status=422,
        json_body={**DEVICE, "push_token": "has spaces"},
        problem=True,
    )
    await call(
        "device_push_token_delete",
        method="DELETE",
        path="/v1/devices/current/push-token",
        status=204,
    )
    return r


def _committed() -> dict[str, str]:
    if not CONTRACT_DIR.is_dir():
        return {}
    return {p.name: p.read_text(encoding="utf-8") for p in sorted(CONTRACT_DIR.glob("*.json"))}


async def test_contract_files_match_the_api(h: Harness) -> None:
    recorder = await _scenario(h)
    generated = {
        **recorder.files,
        "index.json": recorder.index(),
        "push_payloads.json": json.dumps(_payloads(), indent=2) + "\n",
    }
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
    assert not drifted, f"API output drifted from docs/contracts/phase8: {drifted}"


def test_every_push_is_generic_and_carries_only_a_type_and_an_incident() -> None:
    for item in _payloads()["payloads"]:
        message = item["message"]
        assert set(message["data"]) <= {"type", "incident_id", "v"}
        text = json.dumps(message["notification"]).lower()
        for private in ("@", "http", "instruction", "mom", "brother"):
            assert private not in text, (item["type"], private)
        assert message["android"]["notification"]["visibility"] == "PRIVATE"
        assert message["android"]["notification"]["channel_id"] in (
            "reminders",
            "incidents",
            "account",
        )
        assert message["android"]["priority"] == "HIGH"
