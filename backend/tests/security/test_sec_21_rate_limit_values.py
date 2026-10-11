"""SEC-21: the limiters API_SPEC §16 lists that had no test, at the documented values.

``test_rate_limits.py`` and the per-feature tests cover register, login, refresh, reauth, reset,
contacts and export. This adds the rest: the account-deletion page (per address, per email, per
account), the release pages (60 an hour per address, 3 new links a day per access), check-in and
I'M SAFE sharing one budget, and the webhook ingress. Each refusal is checked for the 429, the
``Retry-After`` and the ``RateLimit-*`` values the document gives; each also checks that the
budget is the *right* one (another address, or the next window, is served).

The per-address budgets of every ``/a`` and ``/c`` POST are also declared in the route registry
and flooded by ``test_authorization_matrix.py``; here they are asserted by hand, with numbers.
"""

from __future__ import annotations

import re
from typing import Any

import httpx

from tests.engine.test_release import Portal, _link_token, _released, address
from tests.security.sec_support import csrf_of
from tests.support import PASSWORD, Harness, bearer, problem
from tests.world import World

DELETE_LINK = re.compile(r"/a/delete/confirm#(ad_[A-Za-z0-9_-]{43})")
Db = Any


def _from(app: Any, ip: str) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app, client=(ip, 52000)),
        base_url="https://api.afterme.test",
    )


def _is_429_page(response: httpx.Response, limit: int, *, within: int) -> None:
    """The document's ``429`` for a page: the status, a retry time inside the window, and the
    budget that was used up."""
    assert response.status_code == 429, response.text[:200]
    assert response.headers["content-type"].startswith("text/html")
    assert 1 <= int(response.headers["retry-after"]) <= within
    assert response.headers["ratelimit-limit"] == str(limit)
    assert response.headers["ratelimit-remaining"] == "0"
    assert 1 <= int(response.headers["ratelimit-reset"]) <= within


# --- POST /a/delete: 10/h per address, 3/h per email ----------------------------------------------


async def _ask_for_deletion(client: httpx.AsyncClient, email: str) -> httpx.Response:
    csrf = csrf_of(await client.get("/a/delete"))  # the success page clears the cookie: re-fetch
    return await client.post("/a/delete", data={"email": email, "csrf": csrf})


async def test_the_deletion_page_allows_three_requests_an_hour_per_email(h: Harness) -> None:
    tokens = await h.signup("leaving@example.com")
    assert tokens["user"]["email"] == "leaving@example.com"
    for number in range(3):
        response = await _ask_for_deletion(h.client, "leaving@example.com")
        assert response.status_code == 200, number
    fourth = await _ask_for_deletion(h.client, "leaving@example.com")
    _is_429_page(fourth, 3, within=3600)
    assert len(h.mail.to("leaving@example.com", "account_deletion_link")) == 3  # no fourth link
    # the budget is the address's: somebody else's page request is still served
    other = await _ask_for_deletion(h.client, "someone.else@example.com")
    assert other.status_code == 200
    # ... and the window ends
    h.clock.advance(hours=1)
    again = await _ask_for_deletion(h.client, "leaving@example.com")
    assert again.status_code == 200


async def test_the_deletion_page_allows_ten_requests_an_hour_per_address(h: Harness) -> None:
    for number in range(10):
        response = await _ask_for_deletion(h.client, f"person{number}@example.com")
        assert response.status_code == 200, number
    eleventh = await _ask_for_deletion(h.client, "person10@example.com")
    _is_429_page(eleventh, 10, within=3600)
    async with _from(h.app, "198.51.100.30") as elsewhere:
        assert (await _ask_for_deletion(elsewhere, "person10@example.com")).status_code == 200
    h.clock.advance(hours=1)
    assert (await _ask_for_deletion(h.client, "person10@example.com")).status_code == 200


# --- POST /a/delete/confirm: 10/h per address, 5 passwords/15 min per account ---------------------


async def test_the_deletion_confirmation_allows_ten_attempts_an_hour_per_address(
    h: Harness,
) -> None:
    csrf = csrf_of(await h.client.get("/a/delete/confirm"))
    form = {"token": "ad_" + "A" * 43, "password": "whatever it is", "csrf": csrf}
    for number in range(10):
        response = await h.client.post("/a/delete/confirm", data=form)
        assert response.status_code == 400, number  # a link that does not exist
    eleventh = await h.client.post("/a/delete/confirm", data=form)
    _is_429_page(eleventh, 10, within=3600)
    async with _from(h.app, "198.51.100.31") as elsewhere:
        own = csrf_of(await elsewhere.get("/a/delete/confirm"))
        served = await elsewhere.post("/a/delete/confirm", data={**form, "csrf": own})
        assert served.status_code == 400  # served (and refused for the link, not the budget)


async def test_the_deletion_confirmation_allows_five_wrong_passwords_per_account(
    h: Harness, owner_db: Db
) -> None:
    tokens = await h.signup("careful@example.com")
    assert (await _ask_for_deletion(h.client, "careful@example.com")).status_code == 200
    [mail] = h.mail.to("careful@example.com", "account_deletion_link")
    found = DELETE_LINK.search(mail.text)
    assert found is not None
    link = found[1]
    csrf = csrf_of(await h.client.get("/a/delete/confirm"))

    for number in range(5):
        wrong = await h.client.post(
            "/a/delete/confirm", data={"token": link, "password": f"not it {number}", "csrf": csrf}
        )
        assert wrong.status_code == 401, number
    # the sixth is refused whatever the password: that is what the budget is for
    sixth = await h.client.post(
        "/a/delete/confirm", data={"token": link, "password": PASSWORD, "csrf": csrf}
    )
    _is_429_page(sixth, 5, within=15 * 60)
    status = owner_db.execute(
        "SELECT status FROM users WHERE id = %s", (tokens["user"]["id"],)
    ).fetchone()
    assert status == {"status": "active"}  # the right password was not even looked at
    # the budget belongs to the account, not to the address that guessed
    async with _from(h.app, "198.51.100.32") as elsewhere:
        own = csrf_of(await elsewhere.get("/a/delete/confirm"))
        other = await elsewhere.post(
            "/a/delete/confirm", data={"token": link, "password": PASSWORD, "csrf": own}
        )
        _is_429_page(other, 5, within=15 * 60)

    # after the window the owner can still finish (the link lives 30 minutes)
    h.clock.advance(minutes=15)
    done = await h.client.post(
        "/a/delete/confirm", data={"token": link, "password": PASSWORD, "csrf": csrf}
    )
    assert done.status_code == 200, done.text[:300]
    status = owner_db.execute(
        "SELECT status FROM users WHERE id = %s", (tokens["user"]["id"],)
    ).fetchone()
    assert status == {"status": "pending_deletion"}


# --- /c/release/*: 60/h per address, 3 new links/day per access -----------------------------------


async def test_the_release_pages_share_sixty_posts_an_hour_per_address(world: World) -> None:
    portal = Portal(world)
    routes = (
        ("/c/release/session", {"token": "rt_" + "A" * 43}),
        ("/c/release/code", {}),
        ("/c/release/verify", {"code": "123456"}),
        ("/c/release/view", {}),
        ("/c/release/new-link", {"token": "rt_" + "A" * 43}),
        ("/c/release/end", {}),
    )
    for number in range(60):
        path, fields = routes[number % len(routes)]
        response = await portal.post(path, **fields)
        assert response.status_code != 429, (number, path)
    # the 61st, on any of the routes, from the same address
    for path, fields in routes:
        _is_429_page(await portal.post(path, **fields), 60, within=3600)
    async with _from(world.h.app, "198.51.100.33") as elsewhere:
        own = csrf_of(await elsewhere.get("/c/release"))
        served = await elsewhere.post("/c/release/end", data={"csrf": own})
        assert served.status_code == 200
    world.clock.advance(hours=1)
    assert (await portal.post("/c/release/end")).status_code == 200


async def test_a_release_link_can_be_asked_for_again_three_times_a_day(world: World) -> None:
    """The fourth request is answered exactly like the others (the page must not say whether
    a link exists), so the budget shows in what was sent: three mails, then none."""
    person = await _released(world)
    brother = address(person, "Brother")
    token = _link_token(world, person)
    portal = Portal(world)
    sent_before = len(world.mail.to(brother, "contact_release"))
    pages: list[str] = []

    for number in range(4):  # an hour apart: the same UTC day, a new queue slot each time
        asked = await portal.post("/c/release/new-link", token=token)
        assert asked.status_code == 200
        pages.append(asked.text)
        await world.dispatch()
        sent = len(world.mail.to(brother, "contact_release")) - sent_before
        assert sent == min(number + 1, 3), (number, sent)
        world.clock.advance(hours=1)
    assert len(set(pages)) == 1  # not one word differs between the sent and the refused answer

    # the next day has a new budget
    world.clock.advance(hours=12)
    await portal.post("/c/release/new-link", token=token)
    await world.dispatch()
    assert len(world.mail.to(brother, "contact_release")) - sent_before == 4


# --- check-ins and I'M SAFE: 30 an hour each, two budgets (Phase 9) -------------------------


async def test_checkins_and_im_safe_have_thirty_an_hour_each(world: World) -> None:
    person = await world.ready()
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    client = world.h.client

    async def checkin(number: int) -> httpx.Response:
        return await client.post(
            "/v1/checkins",
            headers={**bearer(person.tokens), "Idempotency-Key": f"sec21-checkin-{number:06d}-x"},
        )

    async def safe(number: int) -> httpx.Response:
        # an incident that does not exist: after the limiter, so a 404 means "counted, allowed"
        return await client.post(
            "/v1/incidents/00000000-0000-4000-8000-000000000001/safe",
            headers={**bearer(person.tokens), "Idempotency-Key": f"sec21-safe-{number:06d}-xxx"},
        )

    for number in range(30):
        assert (await checkin(number)).status_code == 200, number
    over = await checkin(100)
    assert over.status_code == 429
    assert problem(over)["code"] == "rate_limited"
    assert 1 <= int(over.headers["retry-after"]) <= 3600
    assert over.headers["ratelimit-limit"] == "30"
    assert over.headers["ratelimit-remaining"] == "0"

    # I'M SAFE is not behind that wall: it has a budget of its own, which is also thirty
    for number in range(30):
        assert (await safe(number)).status_code == 404, number
    refused = await safe(30)
    assert refused.status_code == 429
    assert refused.headers["ratelimit-limit"] == "30"

    # a replay of a recorded check-in is answered from the record, never counted
    replay = await checkin(0)
    assert replay.status_code == 200
    assert replay.headers["idempotent-replayed"] == "true"
    # the next hour is a new budget
    world.clock.advance(hours=1)
    await world.login(person)
    assert (await checkin(200)).status_code == 200


# --- POST /webhooks/email/{provider}: 600 a minute per address ------------------------------------


async def test_the_webhook_ingress_allows_six_hundred_requests_a_minute_per_address(
    h: Harness,
) -> None:
    for number in range(600):
        response = await h.client.post("/webhooks/email/resend", content=b"{}")
        assert response.status_code == 404, number  # not configured here: counted all the same
    over = await h.client.post("/webhooks/email/resend", content=b"{}")
    assert over.status_code == 429
    assert problem(over)["code"] == "rate_limited"
    assert 1 <= int(over.headers["retry-after"]) <= 60
    assert over.headers["ratelimit-limit"] == "600"
    assert over.headers["ratelimit-remaining"] == "0"
    async with _from(h.app, "198.51.100.34") as elsewhere:
        assert (await elsewhere.post("/webhooks/email/resend", content=b"{}")).status_code == 404
    h.clock.advance(minutes=1)
    assert (await h.client.post("/webhooks/email/resend", content=b"{}")).status_code == 404
