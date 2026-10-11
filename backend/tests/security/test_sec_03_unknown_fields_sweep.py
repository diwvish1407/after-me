"""SEC-03: an unknown field in any body is a 422, and changes nothing (TEST_PLAN §5.2).

The per-feature tests (``test_profile.py``, ``test_contacts_crud.py``, ``test_instructions.py``,
``test_devices.py``, ``test_checkins.py``) each prove it for their own route. This sweep proves it
for **every** route that takes a JSON body, and a completeness test keeps it that way: a route
added with a body but without a case here fails the build.

Each case sends a *valid* body plus the fields an attacker would try to set by mass assignment
(``tier``, ``status``, ``user_id``, ``next_due_at``, ``verification_status``), at the top level and,
where the body has nested objects, inside them. The answer must be ``422`` whose errors are
exactly the unknown fields (so the rest of the body was fine: the refusal is the extras'), and no
table, email or counter-visible state may have changed.
"""

from __future__ import annotations

import copy
import uuid
from dataclasses import dataclass
from typing import Any

import httpx
import psycopg
import pytest

from app.core.config import Settings
from app.main import create_app
from tests.security.sec_support import assert_unchanged, snapshot
from tests.security.test_authorization_matrix import (
    FACTORIES,
    ROUTE_POLICY,
    FreshReauth,
    Owned,
    Policy,
    Public,
    Reauth,
)
from tests.support import DEVICE, PASSWORD, Harness, bearer, problem

Db = psycopg.Connection[dict[str, Any]]

EXTRAS: dict[str, Any] = {
    "tier": "premium",
    "status": "suspended",
    "user_id": "2b1f3c9e-7a0d-4a39-9d6e-5f3c1b0a9e11",
    "next_due_at": "2030-01-01T00:00:00Z",
    "verification_status": "verified",
}
# A field the route really has: a different answer than "unknown" is the correct one for it.
LEGITIMATE: dict[tuple[str, str], set[str]] = {
    ("POST", "/v1/instructions"): {"status"},
    ("PATCH", "/v1/instructions/{instruction_id}"): {"status"},
}

EMAIL = "sweeper@example.com"

# Public routes carry no body in the registry (the matrix sends ``{}`` to reach validation).
PUBLIC_BODIES: dict[tuple[str, str], dict[str, Any]] = {
    ("POST", "/v1/auth/register/start"): {
        "email": "new.person@example.com",
        "password": PASSWORD,
        "display_name": "New Person",
        "timezone": "Asia/Kolkata",
        "locale": "en",
    },
    ("POST", "/v1/auth/register/verify"): {
        "email": "new.person@example.com",
        "code": "123456",
        "password": PASSWORD,
        "device": dict(DEVICE),
    },
    ("POST", "/v1/auth/register/resend"): {"email": "new.person@example.com"},
    ("POST", "/v1/auth/login"): {"email": EMAIL, "password": PASSWORD, "device": dict(DEVICE)},
    ("POST", "/v1/auth/refresh"): {"refresh_token": "rt_" + "A" * 43},
    ("POST", "/v1/auth/password/forgot"): {"email": "new.person@example.com"},
}
# Routes whose body is optional or whose registry entry has none.
OTHER_BODIES: dict[tuple[str, str], dict[str, Any]] = {
    ("POST", "/v1/checkins"): {"client_reported_at": "2026-10-08T09:00:00Z"},
}
EXTRA_HEADERS: dict[tuple[str, str], dict[str, str]] = {
    ("POST", "/v1/checkins"): {"Idempotency-Key": "sweep-checkin-key-0001"},
    ("PUT", "/v1/plan"): {"If-Match": '"plan-1"'},
}
# Where a nested object sits, and a base body that has one.
_RECIPIENT = {"contact_id": str(uuid.uuid4()), "release_stage_id": str(uuid.uuid4())}
NESTED: dict[tuple[str, str], list[tuple[str, dict[str, Any]]]] = {
    ("POST", "/v1/auth/register/verify"): [
        ("device", PUBLIC_BODIES[("POST", "/v1/auth/register/verify")])
    ],
    ("POST", "/v1/auth/login"): [("device", PUBLIC_BODIES[("POST", "/v1/auth/login")])],
    ("PUT", "/v1/plan"): [
        (
            "stages[0]",
            {
                "grace_minutes": 180,
                "stages": [{"offset_minutes": 180, "notify_contact_ids": []}],
            },
        )
    ],
    ("POST", "/v1/instructions"): [
        (
            "recipients[0]",
            {
                "category": "home",
                "title": "House",
                "body": "Where the key is.",
                "recipients": [_RECIPIENT],
            },
        )
    ],
    ("PATCH", "/v1/instructions/{instruction_id}"): [
        ("recipients[0]", {"recipients": [_RECIPIENT]})
    ],
}


@dataclass(frozen=True)
class Case:
    method: str
    path: str
    policy: Policy | None
    body: dict[str, Any]
    where: str  # "" for the top level, else "device", "stages[0]", "recipients[0]"
    headers: dict[str, str]

    @property
    def id(self) -> str:
        return f"{self.method} {self.path} {self.where or 'body'}"


def _cases() -> list[Case]:
    cases: list[Case] = []
    bodies: dict[tuple[str, str], tuple[Policy | None, dict[str, Any]]] = {}
    for key, policy in ROUTE_POLICY.items():
        body = getattr(policy, "body", None)
        if body is not None:
            bodies[key] = (policy, body)
    for key, body in {**PUBLIC_BODIES, **OTHER_BODIES}.items():
        bodies[key] = (ROUTE_POLICY[key], body)
    for key, (policy, body) in sorted(bodies.items()):
        headers = EXTRA_HEADERS.get(key, {})
        cases.append(Case(key[0], key[1], policy, body, "", headers))
        for where, nested_body in NESTED.get(key, []):
            cases.append(Case(key[0], key[1], policy, nested_body, where, headers))
    return cases


CASES = _cases()


def _with_extras(body: dict[str, Any], where: str, extras: dict[str, Any]) -> dict[str, Any]:
    sent = copy.deepcopy(body)
    if not where:
        sent.update(extras)
    elif where == "device":
        sent["device"].update(extras)
    elif where == "stages[0]":
        sent["stages"][0].update(extras)
    elif where == "recipients[0]":
        sent["recipients"][0].update(extras)
    else:  # pragma: no cover - a new nesting needs its own branch
        raise AssertionError(where)
    return sent


def test_every_route_with_a_json_body_is_swept(settings: Settings) -> None:
    """The OpenAPI schema is the application's own list of routes that read a body."""
    schema = create_app(settings).openapi()
    declared = {
        (method.upper(), path)
        for path, item in schema["paths"].items()
        for method, operation in item.items()
        if "requestBody" in operation
    }
    swept = {(c.method, c.path) for c in CASES}
    assert declared == swept, (
        f"routes with a body and no sweep case: {sorted(declared - swept)}; "
        f"cases for routes without a body: {sorted(swept - declared)}"
    )


@pytest.mark.no_rate_limit
@pytest.mark.parametrize("case", CASES, ids=lambda c: c.id)
async def test_unknown_fields_are_refused_and_change_nothing(
    h: Harness, owner_db: Db, case: Case
) -> None:
    tokens = await h.signup(EMAIL)
    key = (case.method, case.path)
    policy = case.policy
    headers = dict(case.headers)
    path = case.path
    if not isinstance(policy, Public):
        headers.update(bearer(tokens))
    if isinstance(policy, Owned):
        resource = await FACTORIES[policy.factory](h, tokens)
        path = path.replace("{" + policy.param + "}", resource)
    if isinstance(policy, (Reauth, FreshReauth)):
        assert (await h.reauth(tokens)).status_code == 204  # so the 422 is not hidden by a 403

    legitimate = LEGITIMATE.get(key, set()) if not case.where else set()
    extras = {k: v for k, v in EXTRAS.items() if k not in legitimate}
    sent = _with_extras(case.body, case.where, extras)
    before = snapshot(owner_db)
    mail_before = len(h.mail.messages)

    response = await h.client.request(case.method, path, json=sent, headers=headers)

    assert response.status_code == 422, response.text
    body = problem(response)
    assert body["code"] == "validation_failed"
    prefix = f"{case.where}." if case.where else ""
    refused = {(e["field"], e["code"]) for e in body["errors"]}
    # exactly the unknown fields: the rest of the body was accepted by the validator
    assert refused == {(prefix + name, "unknown_field") for name in extras}, body["errors"]
    for value in ("premium", "suspended", "verified", EXTRAS["user_id"]):
        assert value not in response.text  # the values are never echoed back
    assert_unchanged(before, snapshot(owner_db), f"{case.id}: the refused request")
    assert len(h.mail.messages) == mail_before

    # positive control: the same body without the extras is not a validation error, so the
    # refusal above is the extras' doing (not skipped for the destructive route, whose success
    # would end the very account this test uses)
    destructive = isinstance(policy, FreshReauth) and policy.destructive
    if not case.where and not destructive:
        clean = await h.client.request(case.method, path, json=case.body, headers=headers)
        assert clean.status_code != 422, clean.text


def test_the_sweep_extras_are_not_fields_of_the_swept_bodies() -> None:
    """If a route ever grows a field with one of these names, the case above would turn into a
    test of that field: say so here, in one place."""
    for case in CASES:
        for name in EXTRAS:
            if name in LEGITIMATE.get((case.method, case.path), set()) and not case.where:
                continue
            assert name not in case.body, (case.id, name)


async def test_a_sweep_request_that_is_not_json_at_all_is_a_422_too(h: Harness) -> None:
    """Not part of the extras sweep, but the same door: a body that is not an object."""
    tokens = await h.signup(EMAIL)
    for content in (b"[]", b'"x"', b"null", b"1"):
        response = await h.client.patch(
            "/v1/me/profile",
            content=content,
            headers={**bearer(tokens), "content-type": "application/json"},
        )
        assert response.status_code == 422, content
    ok: httpx.Response = await h.client.patch(
        "/v1/me/profile", json={"display_name": "Still Fine"}, headers=bearer(tokens)
    )
    assert ok.status_code == 200
