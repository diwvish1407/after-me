"""Authorization matrix over EVERY route (TEST_PLAN §5.1; SECURITY T1).

Each route of the application must have an entry in ``ROUTE_POLICY``. A new route without an
entry fails the build, so no endpoint can skip its authorization tests.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
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
from tests.security.sec_support import snapshot
from tests.support import Harness, bearer, jwt_private_key_pem, make_settings, problem


@dataclass(frozen=True)
class Public:
    """No session. ``rate_limited`` routes count requests per IP (and more).

    ``secret`` names the credential of a machine-to-machine route (a shared secret or a provider
    signature): such a route is public to the session layer but refuses a request without it.
    """

    rate_limited: bool = False
    secret: str | None = None


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
    """Step-up: the password entered within the last five minutes (FR-AUTH-08)."""

    body: dict[str, Any] | None = field(default=None)


@dataclass(frozen=True)
class FreshReauth:
    """Step-up with the 60-second window, for what cannot be taken back or reads everything
    (``FreshReauthUserDep``): a confirmation of two minutes ago does not count. ``destructive``
    routes end the account (and so the session) when they succeed, so their success is checked
    once, last."""

    body: dict[str, Any] | None = field(default=None)
    destructive: bool = False


@dataclass(frozen=True)
class Web:
    """A server-rendered page under ``/a`` or ``/c`` (no bearer token). Unsafe methods must carry
    a CSRF token (issued by ``csrf_page``) and GET must never change state."""

    form: dict[str, str] = field(default_factory=dict)
    csrf_page: str = "/a/reset"
    # POSTs one address may send in the window before the 429 page (API_SPEC §16). ``None``: no
    # per-address budget (the route has a per-user one, or none at all).
    ip_limit: int | None = None

    @property
    def rate_limited(self) -> bool:
        return self.ip_limit is not None


@dataclass(frozen=True)
class PublicPage(Public):
    """A server-rendered GET page that is public by design (``/legal/*``, ``/support``): no
    session, no cookie, no form, no database, nothing about any person. It carries the page
    security headers like every other page, and may be cached for a few minutes by anyone."""


Policy = Public | PublicPage | Authenticated | Owned | Reauth | FreshReauth | Web

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
    # The uptime monitor authenticates with its own shared secret (X-Probe-Token), not a session;
    # 10 a minute per address (``ops/router.py``).
    ("POST", "/internal/probe"): Public(rate_limited=True, secret="X-Probe-Token"),
    # Provider webhooks (Phase 8): machine to machine, authenticated by the provider's signature
    # or password; an unconfigured provider is a bare 404; 600 a minute per address.
    ("POST", "/webhooks/email/{provider}"): Public(rate_limited=True, secret="signature"),
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
    ("GET", "/v1/activity"): Authenticated(),
    ("PUT", "/v1/devices/current"): Authenticated(
        body={
            "platform": "android",
            "app_version": "1.0.0+1",
            "os_version": "15",
            "locale": "en",
            "push_token": "t" * 40,
        }
    ),
    ("DELETE", "/v1/devices/current/push-token"): Authenticated(),
    # The password entered within the last 60 seconds *and* the word DELETE (FreshReauthUserDep,
    # DeleteAccountRequest). Success closes the account and ends the session, so the FreshReauth
    # check runs it last (tests/engine/test_deletion.py covers what deletion then does).
    ("DELETE", "/v1/me"): FreshReauth(body={"confirm": "DELETE"}, destructive=True),
    # The export holds the decrypted instructions: the same 60-second window.
    ("POST", "/v1/me/export"): FreshReauth(),
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
    # Reading decrypts the content, so both reads need the password entered in the last five
    # minutes (and a successful read is audited). The stranger of the Owned check re-authenticates
    # first and still gets 404.
    ("GET", "/v1/instructions"): Reauth(),
    ("POST", "/v1/instructions"): Authenticated(
        body={"category": "home", "title": "House", "body": "Where the key is."}
    ),
    ("GET", "/v1/instructions/{instruction_id}"): Owned(
        "instruction_id",
        factory="instruction",
        tables=("instructions", "instruction_recipients"),
        reauth=True,
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
    ("GET", "/legal"): PublicPage(),
    ("GET", "/legal/privacy"): PublicPage(),
    ("GET", "/legal/terms"): PublicPage(),
    ("GET", "/support"): PublicPage(),
    ("GET", "/a/reset"): Web(),
    ("POST", "/a/reset"): Web(
        form={"token": "pr_" + "A" * 43, "new_password": "a new passphrase 42"}, ip_limit=10
    ),
    ("GET", "/a/assets/web.css"): Web(),
    # Phase 7: account deletion without the app, and the lost-phone pages. Every page that needs
    # a session shows the sign-in form instead when it has none.
    ("GET", "/a/delete"): Web(csrf_page="/a/delete"),
    ("POST", "/a/delete"): Web(
        form={"email": "someone@example.com"}, csrf_page="/a/delete", ip_limit=10
    ),
    ("GET", "/a/delete/confirm"): Web(csrf_page="/a/delete/confirm"),
    ("POST", "/a/delete/confirm"): Web(
        form={"token": "ad_" + "A" * 43, "password": "x"},
        csrf_page="/a/delete/confirm",
        ip_limit=10,
    ),
    ("GET", "/a/login"): Web(csrf_page="/a/login"),
    ("POST", "/a/login"): Web(
        form={"email": "someone@example.com", "password": "x"}, csrf_page="/a/login", ip_limit=10
    ),
    ("GET", "/a/checkin"): Web(csrf_page="/a/login"),
    ("POST", "/a/checkin"): Web(form={"key": "web-" + "a" * 20}, csrf_page="/a/login"),
    (
        "POST",
        "/a/safe",
    ): Web(
        form={"key": "web-" + "a" * 20, "incident_id": str(uuid.uuid4()), "password": "x"},
        csrf_page="/a/login",
    ),
    ("POST", "/a/logout"): Web(csrf_page="/a/login"),
    ("GET", "/c/open"): Web(csrf_page="/c/open"),
    ("GET", "/c/optout"): Web(csrf_page="/c/open"),
    # One shared budget of 20 an hour per address for the five invitation and opt-out POSTs.
    ("POST", "/c/session"): Web(form={"token": "ci_" + "A" * 43}, csrf_page="/c/open", ip_limit=20),
    ("POST", "/c/invite/accept"): Web(
        form={"token": "ci_" + "A" * 43}, csrf_page="/c/open", ip_limit=20
    ),
    ("POST", "/c/invite/decline"): Web(
        form={"token": "ci_" + "A" * 43, "never_contact": "1"}, csrf_page="/c/open", ip_limit=20
    ),
    ("POST", "/c/optout/confirm"): Web(
        form={"token": "oo_" + str(uuid.uuid4()) + "." + "A" * 43},
        csrf_page="/c/open",
        ip_limit=20,
    ),
    ("POST", "/c/optout"): Web(
        form={"token": "oo_" + str(uuid.uuid4()) + "." + "A" * 43, "scope": "everyone"},
        csrf_page="/c/open",
        ip_limit=20,
    ),
    # Phase 6: the release pages. A session and a one-time code stand between the link and any
    # content; a GET shows a static form only.
    ("GET", "/c/release"): Web(csrf_page="/c/release"),
    # One shared budget of 60 an hour per address for every POST of the release pages.
    ("POST", "/c/release/session"): Web(
        form={"token": "rt_" + "A" * 43}, csrf_page="/c/release", ip_limit=60
    ),
    ("POST", "/c/release/code"): Web(csrf_page="/c/release", ip_limit=60),
    ("POST", "/c/release/verify"): Web(
        form={"code": "123456"}, csrf_page="/c/release", ip_limit=60
    ),
    ("POST", "/c/release/view"): Web(csrf_page="/c/release", ip_limit=60),
    ("POST", "/c/release/new-link"): Web(
        form={"token": "rt_" + "A" * 43}, csrf_page="/c/release", ip_limit=60
    ),
    ("POST", "/c/release/end"): Web(csrf_page="/c/release", ip_limit=60),
}

# Routes ``create_app`` mounts only when ``TEST_SUPPORT_ENABLED`` is set (never in production):
# the movable clock and the mail reader. Every one needs the ``X-Test-Token`` header.
TEST_SUPPORT_TOKEN = "t" * 40
TEST_SUPPORT_ROUTE_POLICY: dict[tuple[str, str], Policy] = {
    ("GET", "/test/clock"): Public(secret="X-Test-Token"),
    ("POST", "/test/clock/advance"): Public(secret="X-Test-Token"),
    ("POST", "/test/clock/reset"): Public(secret="X-Test-Token"),
    ("GET", "/test/mail"): Public(secret="X-Test-Token"),
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


async def test_every_test_support_route_has_a_policy_and_a_token_guard(tmp_path: Any) -> None:
    """The matrix app never has test support, so the routes that exist only with it are scanned
    in an app built with it: nothing but the documented four, and none answers without the
    token (including the one that moves time backwards)."""
    settings = make_settings(
        test_support_enabled=True,
        test_support_token=TEST_SUPPORT_TOKEN,
        email_provider="console",
        dev_mail_dir=tmp_path / "mail",
        rate_limit_enabled=False,
    )
    support_app = create_app(settings)
    try:
        routes = app_routes(support_app)
        assert routes == ROUTE_POLICY.keys() | TEST_SUPPORT_ROUTE_POLICY.keys()
        assert {r for r in routes if r[1].startswith("/test")} == TEST_SUPPORT_ROUTE_POLICY.keys()
        transport = httpx.ASGITransport(app=support_app, client=("203.0.113.10", 51000))
        async with httpx.AsyncClient(transport=transport, base_url="https://api.afterme.test") as c:
            for method, path in sorted(TEST_SUPPORT_ROUTE_POLICY):
                body = {"seconds": 60} if path.endswith("/advance") else None
                for token in (None, "", "wrong", TEST_SUPPORT_TOKEN[:-1], TEST_SUPPORT_TOKEN + "x"):
                    headers = {} if token is None else {"X-Test-Token": token}
                    refused = await c.request(method, path, headers=headers, json=body)
                    assert refused.status_code == 401, (method, path, token)
            # the guard is the only thing in the way: with the token the routes answer
            allowed = {"X-Test-Token": TEST_SUPPORT_TOKEN}
            for method, path in sorted(TEST_SUPPORT_ROUTE_POLICY):
                body = {"seconds": 1} if path.endswith("/advance") else None
                answered = await c.request(method, path, headers=allowed, json=body)
                assert answered.status_code in (200, 501), (method, path, answered.text)
            await c.post("/test/clock/reset", headers=allowed)
    finally:
        await support_app.state.services.db.dispose()


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
    [
        (k, p)
        for k, p in ROUTE_POLICY.items()
        if isinstance(p, Public) and p.rate_limited and p.secret is None
    ],
    ids=str,
)
async def test_public_auth_routes_do_not_require_tokens(
    h: Harness, route: tuple[str, str], policy: Public
) -> None:
    method, path = route
    response = await h.client.request(method, path, json={})
    assert response.status_code == 422  # reached validation: no auth gate in front
    assert "ratelimit-limit" in response.headers


# --- machine-to-machine routes: no session, but a secret, and a budget -------------------------

PROBE_TOKEN = "p" * 40
WHSEC = "whsec_" + base64.b64encode(b"0123456789abcdef0123456789abcdef").decode()
SECRET_ROUTES = {k for k, p in ROUTE_POLICY.items() if isinstance(p, Public) and p.secret}


def test_the_secret_authenticated_routes_are_exactly_the_probe_and_the_webhooks() -> None:
    """A new route that is public to the session layer but guarded by a secret must be added
    here, with its own refusal test below."""
    assert {("POST", "/internal/probe"), ("POST", "/webhooks/email/{provider}")} == SECRET_ROUTES
    for key in SECRET_ROUTES:
        policy = ROUTE_POLICY[key]
        assert isinstance(policy, Public)
        assert policy.rate_limited, key


@pytest.mark.settings(probe_token=PROBE_TOKEN)
async def test_the_probe_needs_its_secret_and_is_rate_limited(
    h: Harness, owner_db: psycopg.Connection[dict[str, Any]]
) -> None:
    """The route is public to the session layer, guarded by ``X-Probe-Token``, and a flood of
    requests without it is stopped. (How the budgets are split between right and wrong tokens,
    and the numbers, are asserted where the probe is tested: ``engine/test_hold.py``.)"""
    for headers in ({}, {"X-Probe-Token": "wrong-" + PROBE_TOKEN}, {"X-Probe-Token": ""}):
        refused = await h.client.post("/internal/probe", headers=headers)
        assert refused.status_code == 401, headers
        assert problem(refused)["code"] == "unauthenticated"
    assert owner_db.execute("SELECT count(*) AS n FROM ingestion_probes").fetchone() == {"n": 0}

    accepted = await h.client.post("/internal/probe", headers={"X-Probe-Token": PROBE_TOKEN})
    assert accepted.status_code == 204
    assert owner_db.execute("SELECT count(*) AS n FROM ingestion_probes").fetchone() == {"n": 1}

    # a flood of guesses meets a 429 (well before this loop ends) and stores nothing
    stopped = None
    for _ in range(500):
        response = await h.client.post("/internal/probe", headers={"X-Probe-Token": "guess"})
        if response.status_code == 429:
            stopped = response
            break
        assert response.status_code == 401
    assert stopped is not None, "guessing the probe token is not rate limited"
    assert problem(stopped)["code"] == "rate_limited"
    assert 1 <= int(stopped.headers["retry-after"]) <= 3600
    assert owner_db.execute("SELECT count(*) AS n FROM ingestion_probes").fetchone() == {"n": 1}


@pytest.mark.settings(
    email_provider="resend", email_api_key="re_test_key_00000000", email_webhook_secret=WHSEC
)
async def test_a_webhook_needs_the_providers_signature_and_is_counted(
    h: Harness, owner_db: psycopg.Connection[dict[str, Any]]
) -> None:
    raw = json.dumps({"type": "email.delivered", "data": {"email_id": "not-ours"}}).encode()
    stamp = int(h.clock.current.timestamp())

    def signed(secret: str, *, at: int = stamp) -> dict[str, str]:
        key = base64.b64decode(secret.removeprefix("whsec_"))
        digest = hmac.new(key, f"msg_1.{at}.".encode() + raw, hashlib.sha256).digest()
        return {
            "content-type": "application/json",
            "svix-id": "msg_1",
            "svix-timestamp": str(at),
            "svix-signature": "v1," + base64.b64encode(digest).decode(),
        }

    other = "whsec_" + base64.b64encode(b"fedcba9876543210fedcba9876543210").decode()
    before = snapshot(owner_db)
    for headers in (
        {"content-type": "application/json"},  # nothing
        signed(other),  # somebody else's secret
        signed(WHSEC, at=stamp - 3600),  # a genuine signature, an hour old: replay
    ):
        refused = await h.client.post("/webhooks/email/resend", content=raw, headers=headers)
        assert refused.status_code == 401, headers
        assert refused.headers["ratelimit-limit"] == "600"
    assert snapshot(owner_db) == before

    accepted = await h.client.post("/webhooks/email/resend", content=raw, headers=signed(WHSEC))
    assert accepted.status_code == 204
    assert accepted.headers["ratelimit-limit"] == "600"
    # a provider this deployment does not use looks like a path that does not exist
    unused = await h.client.post("/webhooks/email/postmark", content=raw, headers=signed(WHSEC))
    assert unused.status_code == 404
    assert unused.headers["ratelimit-limit"] == "600"


# --- step-up with the 60-second window ----------------------------------------------------------


@pytest.mark.parametrize(
    ("route", "policy"),
    [(k, p) for k, p in ROUTE_POLICY.items() if isinstance(p, FreshReauth)],
    ids=str,
)
async def test_fresh_reauth_routes_take_only_the_last_sixty_seconds(
    h: Harness,
    owner_db: psycopg.Connection[dict[str, Any]],
    route: tuple[str, str],
    policy: FreshReauth,
) -> None:
    tokens = await h.signup("fresh@example.com")
    method, path = route
    headers = bearer(tokens)

    async def attempt(body: Any = policy.body) -> httpx.Response:
        return await h.client.request(method, path, headers=headers, json=body)

    def account() -> Any:
        return owner_db.execute(
            "SELECT status, deletion_requested_at FROM users WHERE id = %s",
            (tokens["user"]["id"],),
        ).fetchone()

    untouched = account()

    never = await attempt()
    assert never.status_code == 403
    assert problem(never)["code"] == "reauth_required"

    # a confirmation a minute old does not count, although the 5-minute routes would take it
    assert (await h.reauth(tokens)).status_code == 204
    h.clock.advance(seconds=61)
    stale = await attempt()
    assert stale.status_code == 403
    assert problem(stale)["code"] == "reauth_required"
    assert account() == untouched

    assert (await h.reauth(tokens)).status_code == 204
    if policy.destructive:
        # the typed word is the second half of the confirmation
        for wrong in ({}, {"confirm": "delete"}, {"confirm": "DELETE", "tier": "premium"}):
            refused = await attempt(wrong)
            assert refused.status_code == 422, wrong
            assert account() == untouched
    done = await attempt()
    assert done.status_code in (200, 202), done.text  # the 403 above was the window, not a bug
    if policy.destructive:
        assert account()["status"] == "pending_deletion"
        gone = await h.client.get("/v1/me", headers=headers)
        assert gone.status_code == 401  # the session ended with the account


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


@pytest.mark.parametrize(("route", "policy"), WEB_POSTS, ids=str)
async def test_web_posts_are_limited_per_address_as_declared(
    h: Harness, route: tuple[str, str], policy: Web
) -> None:
    """``Web.ip_limit`` is how many POSTs one address gets before the 429 page (API_SPEC §16).
    Every route that declares none must not run into one (its budget, if any, is per user)."""
    _, path = route

    async def post(client: httpx.AsyncClient, number: int) -> httpx.Response:
        page = await client.get(policy.csrf_page)
        found = re.search(r'name="csrf" value="([^"]+)"', page.text)
        assert found is not None
        form = dict(policy.form)
        if "email" in form:  # /a/delete and /a/login also count per address: vary it
            form["email"] = f"flood{number}@example.com"
        return await client.post(path, data={**form, "csrf": found[1]})

    # more than the largest declared budget (60): a route sharing any bucket would trip
    budget = policy.ip_limit if policy.ip_limit is not None else 65
    for number in range(budget):
        response = await post(h.client, number)
        assert response.status_code != 429, (path, number)
        assert response.status_code < 500, (path, number)
    over = await post(h.client, budget)
    if not policy.rate_limited:
        assert over.status_code != 429
        return
    assert over.status_code == 429
    assert over.headers["content-type"].startswith("text/html")  # a page, not a problem document
    assert int(over.headers["retry-after"]) >= 1
    assert over.headers["ratelimit-limit"] == str(policy.ip_limit)
    assert over.headers["ratelimit-remaining"] == "0"
    # another address has its own budget ...
    transport = httpx.ASGITransport(app=h.app, client=("198.51.100.77", 52000))
    async with httpx.AsyncClient(transport=transport, base_url="https://api.afterme.test") as c:
        assert (await post(c, 0)).status_code != 429
    # ... and the window ends
    h.clock.advance(hours=1)
    assert (await post(h.client, budget + 1)).status_code != 429


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
