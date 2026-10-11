"""SEC-15: every response of the web pages carries the whole security header set (TEST_PLAN §5.2).

The matrix checks four headers on every registered route in the *test* environment, which has no
HSTS. Here the application is built as staging (HSTS on) and the full set is compared with a list
written out below, on every route of the registry and on the pages the matrix cannot reach: a
signed-in state page, the recipient's code and content pages, redirects, error pages (400, 403,
404, 405, 429, 503) and the static stylesheet. Cookies are checked the same way: ``__Host-``
prefixed, ``Secure``, ``HttpOnly``, ``SameSite=Strict``, ``Path=/``, never a ``Domain``.
"""

from __future__ import annotations

import re
from collections.abc import AsyncIterator
from datetime import timedelta

import httpx
import pytest
from fastapi import FastAPI

from app.core.config import AppEnv, Settings
from app.main import create_app
from tests.engine.test_release import _link_token, _released
from tests.security.sec_support import csrf_of
from tests.security.test_authorization_matrix import ROUTE_POLICY, Web
from tests.security.test_sec_12_cross_incident_portal import Browser
from tests.support import CLIENT_IP, PASSWORD
from tests.world import World

HOST = "https://api.afterme.test"

# What every HTML page must say, written out (not read from the application's constants).
PAGE_HEADERS = {
    "referrer-policy": "no-referrer",
    "cache-control": "no-store",
    "x-robots-tag": "noindex, nofollow",
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
    "permissions-policy": "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
    "strict-transport-security": "max-age=63072000; includeSubDomains",
    "cross-origin-resource-policy": "same-origin",
}
PAGE_CSP = re.compile(
    r"^default-src 'none'; script-src 'nonce-([A-Za-z0-9_-]{16,})'; style-src 'self'; "
    r"img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'$"
)
# What every other response (an error from the framework, a problem document) must say.
PLAIN_HEADERS = {
    "referrer-policy": "no-referrer",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
    "strict-transport-security": "max-age=63072000; includeSubDomains",
    "cross-origin-resource-policy": "same-origin",
}
PLAIN_CSP = "default-src 'none'; frame-ancestors 'none'"
ASSET_HEADERS = {
    "referrer-policy": "no-referrer",
    "cache-control": "public, max-age=3600",
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
    "strict-transport-security": "max-age=63072000; includeSubDomains",
    "cross-origin-resource-policy": "same-origin",
}


def _assert_page(label: str, response: httpx.Response, nonces: set[str]) -> None:
    for name, value in PAGE_HEADERS.items():
        assert response.headers.get(name) == value, (label, name, response.headers.get(name))
    csp = PAGE_CSP.match(response.headers.get("content-security-policy", ""))
    assert csp, (label, response.headers.get("content-security-policy"))
    nonces.add(csp[1])
    assert response.headers.get("x-request-id"), label
    if response.status_code != 303:
        assert response.headers["content-type"].startswith("text/html"), label


def _assert_plain(label: str, response: httpx.Response) -> None:
    for name, value in PLAIN_HEADERS.items():
        assert response.headers.get(name) == value, (label, name, response.headers.get(name))
    assert response.headers.get("content-security-policy") == PLAIN_CSP, label


def _assert_cookies(label: str, response: httpx.Response) -> None:
    for header in response.headers.get_list("set-cookie"):
        name = header.split("=", 1)[0]
        lowered = header.lower()
        assert name.startswith("__Host-"), (label, name)
        for attribute in ("secure", "httponly", "samesite=strict", "path=/"):
            assert attribute in lowered, (label, name, attribute)
        assert "domain" not in lowered, (label, name)


@pytest.fixture
async def staging(world: World) -> AsyncIterator[FastAPI]:
    """The same application, same database and clock, configured as staging (HSTS on)."""
    settings = world.h.settings
    config = Settings.model_construct(
        **{**dict(settings), "app_env": AppEnv.STAGING}, _fields_set=settings.model_fields_set
    )
    app = create_app(config, clock=world.h.clock, email_provider=world.mail)
    yield app
    await app.state.services.db.dispose()


def _browser(app: FastAPI) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app, client=(CLIENT_IP, 51000)), base_url=HOST
    )


async def test_staging_serves_hsts_and_the_test_environment_does_not(
    world: World, staging: FastAPI
) -> None:
    async with _browser(staging) as c:
        assert "max-age=63072000" in (await c.get("/a/login")).headers["strict-transport-security"]
    assert "strict-transport-security" not in (await world.h.client.get("/a/login")).headers


async def test_every_registered_web_route_carries_the_full_set(
    world: World, staging: FastAPI
) -> None:
    nonces: set[str] = set()
    seen = 0
    async with _browser(staging) as c:
        for (method, path), policy in sorted(ROUTE_POLICY.items()):
            if not isinstance(policy, Web):
                continue
            if method == "GET":
                response = await c.get(path)
                if path.startswith("/a/assets"):
                    for name, value in ASSET_HEADERS.items():
                        assert response.headers.get(name) == value, (path, name)
                    assert response.headers["content-type"].startswith("text/css")
                    seen += 1
                    continue
                _assert_page(f"GET {path}", response, nonces)
                _assert_cookies(f"GET {path}", response)
            else:
                # without the CSRF pair (a 403 page) ...
                refused = await c.post(path, data=policy.form or {"x": "y"})
                assert refused.status_code == 403, path
                _assert_page(f"POST {path} (refused)", refused, nonces)
                # ... and with it (whatever page the route then answers with)
                csrf = csrf_of(await c.get(policy.csrf_page))
                answered = await c.post(path, data={**policy.form, "csrf": csrf})
                _assert_page(f"POST {path}", answered, nonces)
                _assert_cookies(f"POST {path}", answered)
            seen += 1
    assert seen >= 20
    # a fresh nonce on every response: a reused one would let a captured page bless a script
    assert len(nonces) >= seen // 2


async def test_error_and_not_found_responses_carry_the_plain_set(
    world: World, staging: FastAPI
) -> None:
    async with _browser(staging) as c:
        for label, response in {
            "unknown /a path": await c.get("/a/nothing-here"),
            "unknown /c path": await c.get("/c/nothing-here"),
            "wrong method on a page": await c.put("/a/login"),
            "delete on release": await c.delete("/c/release"),
            "unknown api path": await c.get("/v1/nothing-here"),
        }.items():
            assert response.status_code in (404, 405), label
            _assert_plain(label, response)


async def test_sessions_content_redirects_and_error_pages_carry_the_full_set(
    world: World, staging: FastAPI
) -> None:
    person = await _released(world)
    link = _link_token(world, person)
    nonces: set[str] = set()
    cookies: list[tuple[str, httpx.Response]] = []

    def page(label: str, response: httpx.Response, status: int) -> httpx.Response:
        assert response.status_code == status, (label, response.status_code, response.text[:200])
        _assert_page(label, response, nonces)
        cookies.append((label, response))
        return response

    # --- the recipient: link -> session -> code -> content -> an unreadable item -> done -----
    visitor = Browser(world, staging)
    try:
        c = visitor.client
        page("release landing", await c.get("/c/release"), 200)
        page(
            "bad link (400)", await visitor.post("/c/release/session", token="rt_" + "A" * 43), 400
        )
        page("session opened", await visitor.open(link), 200)
        page("code asked for", await visitor.code(), 200)
        wrong = "000000" if visitor.last_code(person) != "000000" else "111111"
        page("wrong code (400)", await visitor.verify(wrong), 400)
        page("content", await visitor.verify(visitor.last_code(person)), 200)
        page("content again", await visitor.post("/c/release/view"), 200)
        stored = world.db.execute("SELECT content_key_version AS v FROM instructions").fetchone()
        assert stored is not None
        world.db.execute("UPDATE instructions SET content_key_version = 99")  # cannot be opened
        page("unreadable (503)", await visitor.post("/c/release/view"), 503)
        world.db.execute("UPDATE instructions SET content_key_version = %s", (stored["v"],))
        page("new link asked for", await visitor.post("/c/release/new-link", token=link), 200)
        page("done", await visitor.post("/c/release/end"), 200)
        page("no session any more (400)", await visitor.post("/c/release/view"), 400)
    finally:
        await visitor.close()

    # --- the owner on the web: wrong password, sign in (303), state page, forms, safe -------
    async with _browser(staging) as c:
        form = {"email": person.email, "password": "not the password", "csrf": ""}
        form["csrf"] = csrf_of(await c.get("/a/login"))
        page("wrong password (401)", await c.post("/a/login", data=form), 401)
        form["password"] = PASSWORD
        signed_in = page("signed in (303)", await c.post("/a/login", data=form), 303)
        assert signed_in.headers["location"] == "/a/checkin"
        state = page("state page", await c.get("/a/checkin"), 200)
        csrf = csrf_of(state)
        key = re.search(r'name="key" value="([^"]+)"', state.text)
        incident = re.search(r'name="incident_id" value="([^"]+)"', state.text)
        assert key
        assert incident
        page(
            "I'M OK sent back (303)",
            await c.post("/a/checkin", data={"key": key[1], "csrf": csrf}),
            303,
        )
        page(
            "I'M SAFE wrong password (401)",
            await c.post(
                "/a/safe",
                data={"key": key[1], "incident_id": incident[1], "password": "no", "csrf": csrf},
            ),
            401,
        )
        page(
            "I'M SAFE",
            await c.post(
                "/a/safe",
                data={
                    "key": key[1],
                    "incident_id": incident[1],
                    "password": PASSWORD,
                    "csrf": csrf,
                },
            ),
            200,
        )
        page("signed out", await c.post("/a/logout", data={"csrf": csrf}), 200)
        page("sign-in form again", await c.get("/a/checkin"), 200)

        # --- limits and bad links on the account pages ---------------------------------------
        reset_form = {
            "token": "pr_" + "A" * 43,
            "new_password": "a new passphrase 42",
            "csrf": csrf_of(await c.get("/a/reset")),
        }
        page("reset link invalid (400)", await c.post("/a/reset", data=reset_form), 400)
        for _ in range(12):
            last = await c.post("/a/reset", data={"token": "x", "new_password": "y", "csrf": "z"})
        page("too many attempts (429)", last, 429)
        assert int(last.headers["retry-after"]) >= 1

    # every cookie any of those pages set, or cleared, is host-only and locked down
    assert any(r.headers.get_list("set-cookie") for _, r in cookies)
    for label, response in cookies:
        _assert_cookies(label, response)
    world.clock.advance(timedelta(minutes=1))
    assert len(nonces) > 10
