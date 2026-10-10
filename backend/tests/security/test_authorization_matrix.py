"""Authorization matrix over EVERY route (TEST_PLAN §5.1; SECURITY T1).

Each route of the application must have an entry in ``ROUTE_POLICY``. A new route without an
entry fails the build, so no endpoint can skip its authorization tests.
"""

from __future__ import annotations

import base64
import json
import re
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import timedelta
from typing import Any

import httpx
import jwt
import psycopg
import pytest
from fastapi import FastAPI
from fastapi.routing import iter_route_contexts

from app.core.config import Settings
from app.main import create_app
from tests.support import Harness, bearer, jwt_private_key_pem, problem


@dataclass(frozen=True)
class Public:
    """No authentication. ``rate_limited`` routes count requests per IP (and more)."""

    rate_limited: bool = False


@dataclass(frozen=True)
class Authenticated:
    body: dict[str, Any] | None = None


@dataclass(frozen=True)
class Owned:
    """Authenticated, and the path parameter names a user-owned resource. ``tables`` are
    snapshotted before and after another user's attempt: they must not change."""

    param: str
    factory: str
    body: dict[str, Any] | None = None
    tables: tuple[str, ...] = ("sessions",)
    headers: dict[str, str] = field(default_factory=dict)
    reauth: bool = False  # step-up routes: the stranger re-authenticates first, still gets 404


@dataclass(frozen=True)
class Reauth:
    body: dict[str, Any] | None = field(default=None)


@dataclass(frozen=True)
class Web:
    """A server-rendered page under ``/a`` or ``/c`` (no bearer token). Unsafe methods must carry
    a CSRF token (issued by ``csrf_page``) and GET must never change state."""

    form: dict[str, str] = field(default_factory=dict)
    csrf_page: str = "/a/reset"


Policy = Public | Authenticated | Owned | Reauth | Web

CONTACT_TABLES = ("trusted_contacts", "contact_verifications", "email_suppressions", "audit_logs")

ROUTE_POLICY: dict[tuple[str, str], Policy] = {
    ("GET", "/health/live"): Public(),
    ("GET", "/health/ready"): Public(),
    ("GET", "/v1/openapi.json"): Public(),
    ("HEAD", "/v1/openapi.json"): Public(),
    ("GET", "/v1/docs"): Public(),
    ("HEAD", "/v1/docs"): Public(),
    ("GET", "/v1/docs/oauth2-redirect"): Public(),
    ("HEAD", "/v1/docs/oauth2-redirect"): Public(),
    # The uptime monitor authenticates with its own shared secret (X-Probe-Token), not a session.
    ("POST", "/internal/probe"): Public(),
    ("POST", "/v1/auth/register/start"): Public(rate_limited=True),
    ("POST", "/v1/auth/register/verify"): Public(rate_limited=True),
    ("POST", "/v1/auth/register/resend"): Public(rate_limited=True),
    ("POST", "/v1/auth/login"): Public(rate_limited=True),
    ("POST", "/v1/auth/refresh"): Public(rate_limited=True),
    ("POST", "/v1/auth/logout"): Authenticated(),
    ("POST", "/v1/auth/logout-all"): Authenticated(),
    ("POST", "/v1/auth/reauth"): Authenticated(body={"password": "x"}),
    ("POST", "/v1/auth/password/forgot"): Public(rate_limited=True),
    ("POST", "/v1/auth/password/change"): Authenticated(
        body={"current_password": "x", "new_password": "a long enough new passphrase"}
    ),
    ("POST", "/v1/auth/email/change/start"): Reauth(body={"new_email": "other@example.com"}),
    ("POST", "/v1/auth/email/change/verify"): Authenticated(body={"code": "123456"}),
    ("GET", "/v1/auth/sessions"): Authenticated(),
    ("DELETE", "/v1/auth/sessions/{session_id}"): Owned("session_id", factory="session"),
    ("GET", "/v1/me"): Authenticated(),
    ("PATCH", "/v1/me/profile"): Authenticated(body={"display_name": "Someone"}),
    ("GET", "/v1/me/entitlements"): Authenticated(),
    ("GET", "/v1/contacts"): Authenticated(),
    ("POST", "/v1/contacts"): Authenticated(
        body={
            "display_name": "Matrix Contact",
            "relationship": "friend",
            "email": "matrix.contact@example.com",
        }
    ),
    ("GET", "/v1/contacts/{contact_id}"): Owned(
        "contact_id", factory="contact", tables=CONTACT_TABLES
    ),
    ("PATCH", "/v1/contacts/{contact_id}"): Owned(
        "contact_id",
        factory="contact",
        body={"display_name": "Hijacked", "email": "hijack@example.com"},
        tables=CONTACT_TABLES,
    ),
    ("DELETE", "/v1/contacts/{contact_id}"): Owned(
        "contact_id", factory="contact", tables=CONTACT_TABLES
    ),
    ("POST", "/v1/contacts/{contact_id}/invitation"): Owned(
        "contact_id", factory="contact", tables=CONTACT_TABLES
    ),
    ("GET", "/v1/checkin/schedule"): Authenticated(),
    ("PUT", "/v1/checkin/schedule"): Authenticated(
        body={"interval_days": 1, "due_local_time": "20:00", "reminder_lead_minutes": 60}
    ),
    ("POST", "/v1/checkin/activate"): Authenticated(),
    ("POST", "/v1/checkin/deactivate"): Reauth(),
    ("POST", "/v1/checkins"): Authenticated(),
    ("GET", "/v1/checkins"): Authenticated(),
    ("GET", "/v1/home"): Authenticated(),
    ("GET", "/v1/incidents/current"): Authenticated(),
    ("GET", "/v1/incidents"): Authenticated(),
    ("GET", "/v1/incidents/{incident_id}"): Owned(
        "incident_id", factory="incident", tables=("escalation_incidents", "incident_actions")
    ),
    ("POST", "/v1/incidents/{incident_id}/safe"): Owned(
        "incident_id",
        factory="incident",
        tables=("escalation_incidents", "incident_actions", "notifications", "checkin_events"),
        headers={"Idempotency-Key": "matrix-idempotency-key-0001"},
        reauth=True,
    ),
    ("GET", "/v1/plan"): Authenticated(),
    ("PUT", "/v1/plan"): Authenticated(
        body={"grace_minutes": 180, "stages": [{"offset_minutes": 180, "notify_contact_ids": []}]}
    ),
    ("GET", "/v1/instruction-categories"): Authenticated(),
    ("GET", "/v1/instructions"): Authenticated(),
    ("POST", "/v1/instructions"): Authenticated(
        body={"category": "home", "title": "House", "body": "Where the key is."}
    ),
    ("GET", "/v1/instructions/{instruction_id}"): Owned(
        "instruction_id", factory="instruction", tables=("instructions", "instruction_recipients")
    ),
    ("PATCH", "/v1/instructions/{instruction_id}"): Owned(
        "instruction_id",
        factory="instruction",
        tables=("instructions", "instruction_recipients", "release_events"),
        body={"title": "Changed"},
    ),
    ("DELETE", "/v1/instructions/{instruction_id}"): Owned(
        "instruction_id",
        factory="instruction",
        tables=("instructions", "instruction_recipients", "release_events"),
    ),
    ("GET", "/a/reset"): Web(),
    ("POST", "/a/reset"): Web(
        form={"token": "pr_" + "A" * 43, "new_password": "a new passphrase 42"}
    ),
    ("GET", "/a/assets/web.css"): Web(),
    ("GET", "/c/open"): Web(csrf_page="/c/open"),
    ("GET", "/c/optout"): Web(csrf_page="/c/open"),
    ("POST", "/c/session"): Web(form={"token": "ci_" + "A" * 43}, csrf_page="/c/open"),
    ("POST", "/c/invite/accept"): Web(form={"token": "ci_" + "A" * 43}, csrf_page="/c/open"),
    ("POST", "/c/invite/decline"): Web(
        form={"token": "ci_" + "A" * 43, "never_contact": "1"}, csrf_page="/c/open"
    ),
    ("POST", "/c/optout/confirm"): Web(
        form={"token": "oo_" + str(uuid.uuid4()) + "." + "A" * 43}, csrf_page="/c/open"
    ),
    ("POST", "/c/optout"): Web(
        form={"token": "oo_" + str(uuid.uuid4()) + "." + "A" * 43, "scope": "everyone"},
        csrf_page="/c/open",
    ),
    # Phase 6: the release pages. A session and a one-time code stand between the link and any
    # content; a GET shows a static form only.
    ("GET", "/c/release"): Web(csrf_page="/c/release"),
    ("POST", "/c/release/session"): Web(form={"token": "rt_" + "A" * 43}, csrf_page="/c/release"),
    ("POST", "/c/release/code"): Web(csrf_page="/c/release"),
    ("POST", "/c/release/verify"): Web(form={"code": "123456"}, csrf_page="/c/release"),
    ("POST", "/c/release/view"): Web(csrf_page="/c/release"),
    ("POST", "/c/release/new-link"): Web(form={"token": "rt_" + "A" * 43}, csrf_page="/c/release"),
    ("POST", "/c/release/end"): Web(csrf_page="/c/release"),
}

# Routes registered only by the test suite (tests/routes.py).
TEST_ROUTE_POLICY: dict[tuple[str, str], Policy] = {
    ("GET", "/v1/_test/reauth"): Reauth(),
    ("GET", "/v1/_test/boom"): Public(),
    ("GET", "/v1/_test/slow"): Public(),
    ("GET", "/v1/_test/db-error"): Public(),
    ("POST", "/v1/_test/echo"): Public(),
}


def app_routes(app: FastAPI) -> set[tuple[str, str]]:
    routes: set[tuple[str, str]] = set()
    for context in iter_route_contexts(app.routes):
        path = context.path
        methods = context.methods or set()
        assert path is not None
        routes.update((method, path) for method in methods)
    return routes


def test_every_production_route_has_a_policy(settings: Settings) -> None:
    production_app = create_app(settings)
    routes = app_routes(production_app)
    missing = sorted(routes - ROUTE_POLICY.keys())
    stale = sorted(ROUTE_POLICY.keys() - routes)
    assert not missing, f"routes without an authorization policy: {missing}"
    assert not stale, f"policies for routes that no longer exist: {stale}"


def test_every_test_route_has_a_policy(app: FastAPI) -> None:
    routes = app_routes(app)
    assert routes == ROUTE_POLICY.keys() | TEST_ROUTE_POLICY.keys()


def test_no_route_can_trigger_escalation_or_release(settings: Settings) -> None:
    """INV-1 / API_SPEC §15: nothing creates incidents, actions or releases. The incident
    routes only *read* them or *stop* one (a POST on a specific incident's ``/safe``)."""
    routes = app_routes(create_app(settings))
    for forbidden in ("release", "escalat", "trigger", "simulate", "_test", "execute"):
        # The recipient portal is how a release is *read*: it creates nothing (its routes have
        # their own policies, and the database role it runs as cannot insert one).
        assert not any(
            forbidden in path and not path.startswith("/c/release") for _, path in routes
        ), forbidden
    assert {(m, p) for m, p in routes if p.startswith("/c/release")} == {
        ("GET", "/c/release"),
        ("POST", "/c/release/session"),
        ("POST", "/c/release/code"),
        ("POST", "/c/release/verify"),
        ("POST", "/c/release/view"),
        ("POST", "/c/release/new-link"),
        ("POST", "/c/release/end"),
    }
    incident_routes = {(m, p) for m, p in routes if "incident" in p}
    assert incident_routes == {
        ("GET", "/v1/incidents/current"),
        ("GET", "/v1/incidents"),
        ("GET", "/v1/incidents/{incident_id}"),
        ("POST", "/v1/incidents/{incident_id}/safe"),
    }
    # no write method on the collection or on an incident itself
    for method, path in routes:
        if path in ("/v1/incidents", "/v1/incidents/{incident_id}", "/v1/incidents/current"):
            assert method == "GET", (method, path)


# --- helpers ----------------------------------------------------------------------------------

PROTECTED = [
    (key, policy)
    for key, policy in {**ROUTE_POLICY, **TEST_ROUTE_POLICY}.items()
    if not isinstance(policy, (Public, Web))
]


def _concrete_path(path: str, value: str) -> str:
    return re.sub(r"\{[a-z_]+\}", value, path)


async def _call(
    client: httpx.AsyncClient,
    method: str,
    path: str,
    policy: Policy,
    headers: dict[str, str],
    owned_id: str | None = None,
) -> httpx.Response:
    url = _concrete_path(path, owned_id or str(uuid.uuid4()))
    body = getattr(policy, "body", None)
    extra = getattr(policy, "headers", None) or {}
    return await client.request(method, url, headers={**headers, **extra}, json=body)


def _b64(data: dict[str, Any]) -> str:
    return base64.urlsafe_b64encode(json.dumps(data).encode()).rstrip(b"=").decode()


TokenFactory = Callable[[Harness, dict[str, Any]], Awaitable[str]]


async def _expired(h: Harness, tokens: dict[str, Any]) -> str:
    h.clock.advance(seconds=h.settings.access_token_ttl_seconds)
    return str(tokens["access_token"])


async def _revoked(h: Harness, tokens: dict[str, Any]) -> str:
    response = await h.client.post("/v1/auth/logout", headers=bearer(tokens))
    assert response.status_code == 204
    return str(tokens["access_token"])


async def _tampered(h: Harness, tokens: dict[str, Any]) -> str:
    header, payload, signature = str(tokens["access_token"]).split(".")
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    claims["sub"] = str(uuid.uuid4())
    return f"{header}.{_b64(claims)}.{signature}"


async def _alg_none(h: Harness, tokens: dict[str, Any]) -> str:
    payload = str(tokens["access_token"]).split(".")[1]
    return f"{_b64({'alg': 'none', 'kid': h.settings.jwt_active_kid})}.{payload}."


async def _wrong_audience(h: Harness, tokens: dict[str, Any]) -> str:
    claims = jwt.decode(str(tokens["access_token"]), options={"verify_signature": False})
    claims["aud"] = "someone-else"
    return jwt.encode(
        claims,
        jwt_private_key_pem(),
        algorithm="EdDSA",
        headers={"kid": h.settings.jwt_active_kid},
    )


async def _garbage(h: Harness, tokens: dict[str, Any]) -> str:
    return "not-a-token"


BAD_TOKENS: dict[str, tuple[TokenFactory, str]] = {
    "garbage": (_garbage, "unauthenticated"),
    "expired": (_expired, "token_expired"),
    "revoked_session": (_revoked, "session_revoked"),
    "tampered_signature": (_tampered, "unauthenticated"),
    "alg_none": (_alg_none, "unauthenticated"),
    "wrong_audience": (_wrong_audience, "unauthenticated"),
}


# --- the matrix -------------------------------------------------------------------------------


@pytest.mark.no_rate_limit
@pytest.mark.parametrize(("route", "policy"), PROTECTED, ids=str)
async def test_protected_routes_require_a_token(
    h: Harness, route: tuple[str, str], policy: Policy
) -> None:
    method, path = route
    response = await _call(h.client, method, path, policy, headers={})
    assert response.status_code == 401
    assert problem(response)["code"] == "unauthenticated"


@pytest.mark.no_rate_limit
@pytest.mark.parametrize("bad", sorted(BAD_TOKENS))
@pytest.mark.parametrize(("route", "policy"), PROTECTED, ids=str)
async def test_protected_routes_reject_bad_tokens(
    h: Harness, route: tuple[str, str], policy: Policy, bad: str
) -> None:
    tokens = await h.signup(f"{bad}@example.com")
    factory, expected_code = BAD_TOKENS[bad]
    token = await factory(h, tokens)
    method, path = route
    response = await _call(
        h.client, method, path, policy, headers=bearer(token), owned_id=tokens["session_id"]
    )
    assert response.status_code == 401
    assert problem(response)["code"] == expected_code


async def _make_session(h: Harness, owner: dict[str, Any]) -> str:
    response = await h.login(owner["user"]["email"])
    assert response.status_code == 200
    return str(response.json()["session_id"])


async def _make_contact(h: Harness, owner: dict[str, Any]) -> str:
    response = await h.add_contact(owner, "alices.contact@example.com", name="Alice's Contact")
    assert response.status_code == 201, response.text
    return str(response.json()["id"])


async def _make_incident(h: Harness, owner: dict[str, Any]) -> str:
    """An open incident belonging to ``owner``, created the only way it can be: by the worker."""
    from datetime import timedelta

    from app.api.container import build_worker_services
    from app.engine.runtime import Engine

    mom = await h.add_contact(owner, "alices.mom@example.com", name="Mom")
    assert mom.status_code == 201
    contacts = (await h.client.get("/v1/contacts", headers=bearer(owner))).json()["items"]
    owner_db = h.app.state.owner_db
    owner_db.execute(
        "UPDATE trusted_contacts SET verification_status = 'verified' WHERE id = %s",
        (contacts[0]["id"],),
    )
    await h.plan_for_contacts(owner)
    assert (await h.client.post("/v1/checkin/activate", headers=bearer(owner))).status_code == 200
    due = owner_db.execute(
        "SELECT next_due_at FROM checkin_configurations WHERE user_id = %s", (owner["user"]["id"],)
    ).fetchone()["next_due_at"]
    services = build_worker_services(
        h.settings, clock=h.clock, email_provider=h.app.state.services.mailer.provider
    )
    before = h.clock.current
    try:
        h.clock.set(due + timedelta(seconds=1))
        await Engine(services, instance_id="matrix").tick()
    finally:
        h.clock.set(before)  # other people's access tokens must stay valid for the test
        await services.db.dispose()
    row = owner_db.execute(
        "SELECT id FROM escalation_incidents WHERE user_id = %s", (owner["user"]["id"],)
    ).fetchone()
    assert row is not None
    return str(row["id"])


async def _make_instruction(h: Harness, owner: dict[str, Any]) -> str:
    response = await h.client.post(
        "/v1/instructions",
        json={"category": "home", "title": "Alice's secret title", "body": "Alice's secret body."},
        headers=bearer(owner),
    )
    assert response.status_code == 201, response.text
    return str(response.json()["id"])


FACTORIES: dict[str, Callable[[Harness, dict[str, Any]], Awaitable[str]]] = {
    "session": _make_session,
    "contact": _make_contact,
    "incident": _make_incident,
    "instruction": _make_instruction,
}


@pytest.mark.no_rate_limit
@pytest.mark.parametrize(
    ("route", "policy"),
    [(k, p) for k, p in ROUTE_POLICY.items() if isinstance(p, Owned)],
    ids=str,
)
async def test_owned_routes_return_404_for_other_users_ids(
    h: Harness, owner_db: psycopg.Connection[dict[str, Any]], route: tuple[str, str], policy: Owned
) -> None:
    alice = await h.signup("alice@example.com")
    bob = await h.signup("bob@example.com")
    alice_resource = await FACTORIES[policy.factory](h, alice)
    method, path = route
    if policy.reauth:
        assert (await h.reauth(bob)).status_code == 204

    def snapshot_tables() -> dict[str, Any]:
        return {
            t: owner_db.execute(f"SELECT * FROM {t} ORDER BY 1").fetchall()  # noqa: S608
            for t in policy.tables
        }

    snapshot = snapshot_tables()
    sent_before = len(h.mail.messages)

    response = await _call(
        h.client, method, path, policy, headers=bearer(bob), owned_id=alice_resource
    )
    assert response.status_code == 404
    body = problem(response)
    assert body["code"] == "not_found"
    assert alice_resource not in response.text
    assert alice["user"]["email"] not in response.text
    assert snapshot_tables() == snapshot
    assert len(h.mail.messages) == sent_before  # no email goes out for a foreign id
    assert "alices.contact@example.com" not in response.text

    unknown = await _call(
        h.client, method, path, policy, headers=bearer(bob), owned_id=str(uuid.uuid4())
    )
    assert unknown.status_code == 404
    assert {k: v for k, v in problem(unknown).items() if k != "request_id"} == {
        k: v for k, v in body.items() if k != "request_id"
    }


@pytest.mark.parametrize(
    ("route", "policy"),
    [(k, p) for k, p in {**ROUTE_POLICY, **TEST_ROUTE_POLICY}.items() if isinstance(p, Reauth)],
    ids=str,
)
async def test_reauth_routes_need_a_fresh_password(
    h: Harness, route: tuple[str, str], policy: Reauth
) -> None:
    tokens = await h.signup("step@example.com")
    method, path = route
    stale = await _call(h.client, method, path, policy, headers=bearer(tokens))
    assert stale.status_code == 403
    assert problem(stale)["code"] == "reauth_required"
    assert (await h.reauth(tokens)).status_code == 204
    fresh = await _call(h.client, method, path, policy, headers=bearer(tokens))
    assert fresh.status_code < 400
    h.clock.advance(timedelta(minutes=5, seconds=1))
    assert (await _call(h.client, method, path, policy, headers=bearer(tokens))).status_code == 403


@pytest.mark.parametrize(
    ("route", "policy"),
    [(k, p) for k, p in ROUTE_POLICY.items() if isinstance(p, Public) and p.rate_limited],
    ids=str,
)
async def test_public_auth_routes_do_not_require_tokens(
    h: Harness, route: tuple[str, str], policy: Public
) -> None:
    method, path = route
    response = await h.client.request(method, path, json={})
    assert response.status_code == 422  # reached validation: no auth gate in front
    assert "ratelimit-limit" in response.headers


# --- web pages --------------------------------------------------------------------------------

WEB_ROUTES = [(k, p) for k, p in ROUTE_POLICY.items() if isinstance(p, Web)]
WEB_POSTS = [(k, p) for k, p in WEB_ROUTES if k[0] == "POST"]
WEB_GET_PAGES = [
    (k, p) for k, p in WEB_ROUTES if k[0] == "GET" and not k[1].startswith("/a/assets")
]
WEB_TABLES = (
    "users",
    "sessions",
    "refresh_tokens",
    "auth_tokens",
    "audit_logs",
    "user_profiles",
    "trusted_contacts",
    "contact_verifications",
    "email_suppressions",
)


def test_web_routes_live_under_a_or_c_and_are_not_in_the_api_docs(settings: Settings) -> None:
    for (_method, path), _ in WEB_ROUTES:
        assert path.startswith(("/a/", "/c/"))
    schema_paths = set(create_app(settings).openapi()["paths"])
    assert not any(p.startswith(("/a/", "/c/")) for p in schema_paths)


@pytest.mark.parametrize(("route", "policy"), WEB_POSTS, ids=str)
async def test_web_posts_need_a_csrf_token(
    h: Harness, owner_db: psycopg.Connection[dict[str, Any]], route: tuple[str, str], policy: Web
) -> None:
    _, path = route
    await h.signup("web-matrix@example.com")
    before = owner_db.execute("SELECT * FROM users ORDER BY id").fetchall()
    without_cookie = await h.client.post(path, data={**policy.form, "csrf": "x" * 43})
    assert without_cookie.status_code == 403
    csrf = await h.portal_csrf(policy.csrf_page)
    mismatch = await h.client.post(path, data={**policy.form, "csrf": csrf + "x"})
    assert mismatch.status_code == 403
    as_json = await h.client.post(path, json={**policy.form, "csrf": csrf})
    assert as_json.status_code == 403  # not a urlencoded form: the CSRF check cannot pass
    assert owner_db.execute("SELECT * FROM users ORDER BY id").fetchall() == before


@pytest.mark.parametrize(("route", "policy"), WEB_ROUTES, ids=str)
async def test_web_responses_carry_the_page_security_headers(
    h: Harness, route: tuple[str, str], policy: Web
) -> None:
    method, path = route
    response = await h.client.request(method, path, data=policy.form or None)
    headers = response.headers
    assert "frame-ancestors 'none'" in headers["content-security-policy"]
    assert headers["referrer-policy"] == "no-referrer"
    assert headers["x-content-type-options"] == "nosniff"
    if path.startswith("/a/assets"):
        return
    assert headers["cache-control"] == "no-store"
    assert headers["x-frame-options"] == "DENY"
    assert headers["x-robots-tag"] == "noindex, nofollow"
    assert "script-src 'nonce-" in headers["content-security-policy"]


@pytest.mark.parametrize(("route", "policy"), WEB_GET_PAGES, ids=str)
async def test_web_gets_never_change_state(
    h: Harness, owner_db: psycopg.Connection[dict[str, Any]], route: tuple[str, str], policy: Web
) -> None:
    tokens = await h.signup("web-get@example.com")
    await h.forgot("web-get@example.com")
    assert (await h.add_contact(tokens, "web-get-contact@example.com")).status_code == 201
    tables = WEB_TABLES
    before = {t: owner_db.execute(f"SELECT * FROM {t} ORDER BY 1").fetchall() for t in tables}  # noqa: S608
    for _ in range(3):
        assert (await h.client.get(route[1])).status_code == 200
    after = {t: owner_db.execute(f"SELECT * FROM {t} ORDER BY 1").fetchall() for t in tables}  # noqa: S608
    assert after == before
