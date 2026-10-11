"""SEC-21: the rate limits of API_SPEC §16 that had no test (TEST_PLAN §5.2).

Already covered elsewhere and not repeated: register, login, refresh, reauth, forgot, email
change, export, contacts and invitations, ``/a/reset``, ``/c/session`` and the check-in budget in
``test_rate_limits.py`` and the per-feature tests; the per-address POST budget of *every* web
route, including ``/a/delete`` (10/h), ``/a/delete/confirm`` (10/h), ``/a/login`` (10/15 min)
and every ``/c/release/*`` route (60/h), in ``test_authorization_matrix.py``
(``test_web_posts_are_limited_per_address_as_declared``).

What this file adds is what those do not reach:

* ``/a/delete``: the budgets per (address, network) and per address across networks;
* ``/a/delete/confirm``: the per-account password budget;
* ``/c/release/new-link``: 3 a day per access (answered like a sent link, so it is visible only
  as a link that does not arrive);
* ``/c/release/*``: one budget for all six POSTs, separate from the other web budgets;
* ``POST /incidents/{id}/safe`` and ``POST /checkins``: one shared 30-an-hour budget;
* ``POST /webhooks/email/{provider}``: 600 a minute per address.

Clock: frozen at an hour boundary, so a fixed window is entered at its start and ends exactly one
window later.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import timedelta
from typing import Any

import httpx
import psycopg
import pytest

from tests.engine.test_release import DUE, Portal, _link_token, _released, address
from tests.security.sec_support import csrf_of, snapshot
from tests.support import PASSWORD, Harness, problem
from tests.world import Person, World

Db = psycopg.Connection[dict[str, Any]]

DELETE_LINK = re.compile(r"https://afterme\.test/a/delete/confirm#(ad_[A-Za-z0-9_-]+)")
WHSEC = "whsec_" + base64.b64encode(b"0123456789abcdef0123456789abcdef").decode()


@asynccontextmanager
async def from_network(h: Harness, ip: str) -> AsyncIterator[httpx.AsyncClient]:
    """The same application, reached from another address (its own cookies, its own budgets)."""
    transport = httpx.ASGITransport(app=h.app, client=(ip, 52000))
    async with httpx.AsyncClient(transport=transport, base_url="https://api.afterme.test") as c:
        yield c


def assert_limited_page(response: httpx.Response, *, limit: int, window_seconds: int) -> None:
    """A web 429: an HTML page (never a problem document), with the documented headers."""
    assert response.status_code == 429
    assert response.headers["content-type"].startswith("text/html")
    assert 1 <= int(response.headers["retry-after"]) <= window_seconds
    assert response.headers["ratelimit-limit"] == str(limit)
    assert response.headers["ratelimit-remaining"] == "0"
    assert "Too many attempts" in response.text


# --- POST /a/delete: per address and network, and per address ----------------------------------


async def _ask_for_link(client: httpx.AsyncClient, email: str) -> httpx.Response:
    csrf = csrf_of(await client.get("/a/delete"))
    return await client.post("/a/delete", data={"email": email, "csrf": csrf})


async def test_a_deletion_link_is_three_an_hour_per_address_and_network(h: Harness) -> None:
    await h.signup("known@example.com")
    sequences: dict[str, list[int]] = {}
    for email in ("known@example.com", "nobody@example.com"):
        responses = [await _ask_for_link(h.client, email) for _ in range(4)]
        sequences[email] = [r.status_code for r in responses]
        # the fourth is a page with the documented values: 3 an hour, back within the hour
        assert_limited_page(responses[3], limit=3, window_seconds=3600)
    # an address that has an account and one that has not are answered by the same budget
    assert sequences["known@example.com"] == sequences["nobody@example.com"] == [200, 200, 200, 429]
    # the fourth request made no mail: three links, and none for an address with no account
    assert len(h.mail.to("known@example.com", "account_deletion_link")) == 3
    assert h.mail.to("nobody@example.com", "account_deletion_link") == []

    # the budget belongs to the pair: another address from the same network, and the same
    # address from another network, are unaffected
    other_address = await _ask_for_link(h.client, "someone.else@example.com")
    assert other_address.status_code == 200
    async with from_network(h, "198.51.100.20") as elsewhere:
        assert (await _ask_for_link(elsewhere, "known@example.com")).status_code == 200

    # and the window ends
    h.clock.advance(hours=1)
    assert (await _ask_for_link(h.client, "known@example.com")).status_code == 200


async def test_a_deletion_link_is_twelve_an_hour_per_address_across_networks(h: Harness) -> None:
    target = "flooded@example.com"
    networks = [f"198.51.100.{n}" for n in range(1, 5)]
    for ip in networks:
        async with from_network(h, ip) as client:
            for _ in range(3):  # each network is within its own three
                assert (await _ask_for_link(client, target)).status_code == 200
    # twelve in the hour: the thirteenth is refused from a network that has asked for nothing
    async with from_network(h, "198.51.100.99") as fresh:
        refused = await _ask_for_link(fresh, target)
        assert_limited_page(refused, limit=12, window_seconds=3600)
        # another address from that network is not touched
        assert (await _ask_for_link(fresh, "calm@example.com")).status_code == 200
    h.clock.advance(hours=1)
    async with from_network(h, "198.51.100.99") as fresh:
        assert (await _ask_for_link(fresh, target)).status_code == 200


# --- POST /a/delete/confirm: 5 passwords per account per 15 minutes ----------------------------


async def _link_for(h: Harness, email: str) -> str:
    assert (await _ask_for_link(h.client, email)).status_code == 200
    found = DELETE_LINK.search(h.mail.to(email, "account_deletion_link")[-1].text)
    assert found is not None
    return found[1]


async def _confirm(h: Harness, token: str, password: str) -> httpx.Response:
    csrf = csrf_of(await h.client.get("/a/delete/confirm"))
    return await h.client.post(
        "/a/delete/confirm", data={"token": token, "password": password, "csrf": csrf}
    )


def _status(owner_db: Db, tokens: dict[str, Any]) -> str:
    row = owner_db.execute("SELECT status FROM users WHERE id = %s", (tokens["user"]["id"],))
    found = row.fetchone()
    assert found is not None
    return str(found["status"])


async def test_the_deletion_password_is_five_tries_per_account_per_fifteen_minutes(
    h: Harness, owner_db: Db
) -> None:
    target = await h.signup("target@example.com")
    bystander = await h.signup("bystander@example.com")
    target_link = await _link_for(h, "target@example.com")
    bystander_link = await _link_for(h, "bystander@example.com")

    for attempt in range(5):
        wrong = await _confirm(h, target_link, "not the password")
        assert wrong.status_code == 401, attempt
    assert _status(owner_db, target) == "active"

    # the sixth is refused even with the right password, and says when to come back
    before = snapshot(owner_db, ["users", "sessions", "instructions", "trusted_contacts"])
    sixth = await _confirm(h, target_link, PASSWORD)
    assert_limited_page(sixth, limit=5, window_seconds=15 * 60)
    assert snapshot(owner_db, before.keys()) == before
    assert _status(owner_db, target) == "active"

    # the budget is the account's, not the network's: another account behind the same address
    # (and so the same IP budget) can still close its own
    other = await _confirm(h, bystander_link, PASSWORD)
    assert other.status_code == 200, other.text
    assert _status(owner_db, bystander) == "pending_deletion"

    # a new window, and the person who really holds the link and the password gets through
    h.clock.advance(minutes=15)
    done = await _confirm(h, target_link, PASSWORD)
    assert done.status_code == 200, done.text
    assert _status(owner_db, target) == "pending_deletion"


# --- /c/release/new-link: 3 a day per access ---------------------------------------------------


async def test_a_release_link_can_be_asked_for_three_times_a_day(world: World) -> None:
    person = await _released(world)
    brother = address(person, "Brother")
    token = _link_token(world, person)
    portal = Portal(world)

    delivered: list[int] = []
    pages: list[httpx.Response] = []
    for _ in range(4):  # in four different hours (one request an hour is one link)
        pages.append(await portal.post("/c/release/new-link", token=token))
        await world.tick()
        delivered.append(len(world.mail.to(brother, "contact_release")))
        await world.advance(hours=1)

    # three arrive; the fourth is answered exactly like the others and nothing is sent
    assert delivered == [1, 2, 3, 3]
    for page in pages:
        assert page.status_code == 200
        assert "Check your email" in page.text
        assert "retry-after" not in page.headers  # no oracle: the page is the same
    asked = world.db.execute(
        "SELECT count(*) AS n FROM audit_logs WHERE action = 'portal.new_link_requested'"
    ).fetchone()
    assert asked == {"n": 3}
    queued = world.notifications(person, template_key="contact_release")
    assert len(queued) == 3

    # the next day is a new allowance (the release is still open)
    await world.advance_to(world.clock.current.replace(hour=0, minute=30) + timedelta(days=1))
    again = await portal.post("/c/release/new-link", token=token)
    assert again.status_code == 200
    await world.tick()
    assert len(world.mail.to(brother, "contact_release")) == 4


# --- /c/release/*: one budget of 60 an hour ----------------------------------------------------

RELEASE_POSTS: list[tuple[str, dict[str, str]]] = [
    ("/c/release/session", {"token": "rt_" + "A" * 43}),
    ("/c/release/code", {}),
    ("/c/release/verify", {"code": "123456"}),
    ("/c/release/view", {}),
    ("/c/release/new-link", {"token": "rt_" + "A" * 43}),
    ("/c/release/end", {}),
]


async def _post(client: httpx.AsyncClient, page: str, path: str, form: dict[str, str]) -> Any:
    csrf = csrf_of(await client.get(page))
    return await client.post(path, data={**form, "csrf": csrf})


async def test_the_release_pages_share_one_budget_of_sixty_posts_an_hour(h: Harness) -> None:
    for number in range(60):  # ten of each: the six routes draw on one counter
        path, form = RELEASE_POSTS[number % len(RELEASE_POSTS)]
        response = await _post(h.client, "/c/release", path, form)
        assert response.status_code != 429, (number, path)

    for path, form in RELEASE_POSTS:  # every one of the six is now refused
        refused = await _post(h.client, "/c/release", path, form)
        assert_limited_page(refused, limit=60, window_seconds=3600)
    # a GET shows a static page and is not counted
    assert (await h.client.get("/c/release")).status_code == 200
    # other budgets are other counters: the invitation pages and the password-reset page
    invite = await _post(h.client, "/c/open", "/c/session", {"token": "ci_" + "A" * 43})
    assert invite.status_code != 429
    reset = await _post(h.client, "/a/reset", "/a/reset", {"token": "x", "new_password": "x"})
    assert reset.status_code != 429
    # another address has its own sixty
    async with from_network(h, "198.51.100.77") as elsewhere:
        free = await _post(elsewhere, "/c/release", "/c/release/code", {})
        assert free.status_code != 429
    h.clock.advance(hours=1)
    path, form = RELEASE_POSTS[0]
    assert (await _post(h.client, "/c/release", path, form)).status_code != 429


async def test_the_invitation_budget_does_not_spend_the_release_budget(h: Harness) -> None:
    for _ in range(20):  # /c/session, /c/invite/*, /c/optout*: 20 an hour, one budget
        spent = await _post(h.client, "/c/open", "/c/session", {"token": "ci_" + "A" * 43})
        assert spent.status_code != 429
    over = await _post(h.client, "/c/open", "/c/invite/decline", {"token": "ci_" + "A" * 43})
    assert_limited_page(over, limit=20, window_seconds=3600)
    free = await _post(h.client, "/c/release", "/c/release/code", {})
    assert free.status_code != 429


# --- check-in and I'M SAFE: one budget of 30 an hour -------------------------------------------


async def _told_incident(world: World) -> tuple[Person, str]:
    """An incident whose contacts have been told: an I'M OK is refused (409), I'M SAFE is the
    way out. The refusal still counts against the budget (it is taken before the check)."""
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=190))
    incident = world.open_incident(person)
    assert incident is not None
    assert incident["contacts_messaged_at"] is not None
    await world.login(person)
    return person, str(incident["id"])


async def _ok(world: World, person: Person, number: int) -> httpx.Response:
    return await world.h.client.post(
        "/v1/checkins",
        headers={**person.headers, "Idempotency-Key": f"sec21-ok-{number:04d}-padding"},
    )


async def _safe(world: World, person: Person, incident_id: str, key: str) -> httpx.Response:
    return await world.h.client.post(
        f"/v1/incidents/{incident_id}/safe", headers={**person.headers, "Idempotency-Key": key}
    )


async def test_check_in_attempts_never_use_up_the_hour_of_i_am_safe(world: World) -> None:
    """Phase 9: I'M SAFE has a budget of its own. Shared with I'M OK, thirty refused I'M OK
    attempts during an open incident (each answers ``409 safe_required``) used to lock the one
    action that takes an alarm back for up to an hour: a buggy client, or anyone holding the
    access token, could keep a person from telling their contacts they are fine."""
    person, incident_id = await _told_incident(world)
    for number in range(30):
        refused = await _ok(world, person, number)
        assert refused.status_code == 409, number
        assert problem(refused)["code"] == "safe_required"
    over = await _ok(world, person, 99)  # the 31st I'M OK of the hour
    assert over.status_code == 429
    assert problem(over)["code"] == "rate_limited"
    assert over.headers["ratelimit-limit"] == "30"

    assert (await world.h.reauth(person.tokens)).status_code == 204
    key = "sec21-safe-key-0000000001"
    safe = await _safe(world, person, incident_id, key)
    assert safe.status_code == 200, safe.text
    assert world.open_incident(person) is None
    assert safe.headers["ratelimit-limit"] == "30"

    # a retry of the tap that already succeeded is a replay, and a replay is never throttled
    replay = await _safe(world, person, incident_id, key)
    assert replay.status_code == 200
    assert replay.headers["idempotent-replayed"] == "true"

    world.clock.advance(hours=1, seconds=1)
    person.tokens = await world.h.relogin(person.email)
    assert (await _ok(world, person, 100)).status_code == 200


# --- webhooks: 600 a minute per address --------------------------------------------------------


def _signed(raw: bytes, stamp: int) -> dict[str, str]:
    key = base64.b64decode(WHSEC.removeprefix("whsec_"))
    digest = hmac.new(key, f"msg_rl.{stamp}.".encode() + raw, hashlib.sha256).digest()
    return {
        "content-type": "application/json",
        "svix-id": "msg_rl",
        "svix-timestamp": str(stamp),
        "svix-signature": "v1," + base64.b64encode(digest).decode(),
    }


@pytest.mark.settings(
    email_provider="resend", email_api_key="re_test_key_00000000", email_webhook_secret=WHSEC
)
async def test_webhook_requests_are_six_hundred_a_minute_per_address(
    h: Harness, owner_db: Db
) -> None:
    raw = json.dumps({"type": "email.delivered", "data": {"email_id": "not-ours"}}).encode()
    unsigned = {"content-type": "application/json"}
    before = snapshot(owner_db)

    for number in range(600):
        response = await h.client.post("/webhooks/email/resend", content=raw, headers=unsigned)
        assert response.status_code == 401, number  # reaches the signature check, and fails it
    over = await h.client.post("/webhooks/email/resend", content=raw, headers=unsigned)
    assert over.status_code == 429
    assert problem(over)["code"] == "rate_limited"
    assert 1 <= int(over.headers["retry-after"]) <= 60
    assert over.headers["ratelimit-limit"] == "600"
    assert over.headers["ratelimit-remaining"] == "0"
    assert snapshot(owner_db) == before  # a flood of forged events changed nothing

    # the limit is on the address, and a path that is not configured is no different
    async with from_network(h, "198.51.100.88") as other:
        accepted = await other.post(
            "/webhooks/email/resend",
            content=raw,
            headers=_signed(raw, int(h.clock.current.timestamp())),
        )
        assert accepted.status_code == 204
    unused = await h.client.post("/webhooks/email/postmark", content=raw, headers=unsigned)
    assert unused.status_code == 429

    # a minute later a genuine, signed event from the first address is read again
    h.clock.advance(minutes=1)
    later = await h.client.post(
        "/webhooks/email/resend",
        content=raw,
        headers=_signed(raw, int(h.clock.current.timestamp())),
    )
    assert later.status_code == 204
