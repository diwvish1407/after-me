"""``POST /v1/checkins`` (I'M OK) and ``GET /v1/checkins`` (API_SPEC §6.2; ESCALATION_ENGINE §9.1;
TEST_PLAN CHK-*)."""

from __future__ import annotations

import asyncio
import json
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import psycopg
import pytest
from psycopg.types.json import Jsonb
from sqlalchemy.exc import OperationalError
from sqlalchemy.ext.asyncio import AsyncSession

from tests.support import Harness, bearer, conninfo, problem, rows

Db = psycopg.Connection[dict[str, Any]]

OWNER = "owner@example.com"


def key() -> str:
    return str(uuid.uuid4())


async def _checkin(
    h: Harness,
    tokens: dict[str, Any],
    idempotency_key: str | None = None,
    body: Any = None,
    *,
    send_key: bool = True,
) -> httpx.Response:
    headers = bearer(tokens)
    if send_key:
        headers["Idempotency-Key"] = idempotency_key or key()
    return await h.client.post("/v1/checkins", json=body, headers=headers)


async def _activate(h: Harness, tokens: dict[str, Any]) -> None:
    await h.add_contact(tokens, f"mom.{uuid.uuid4().hex[:6]}@example.com")
    await h.plan_for_contacts(tokens)
    assert (await h.client.post("/v1/checkin/activate", headers=bearer(tokens))).status_code == 200


def _config(owner_db: Db, tokens: dict[str, Any]) -> dict[str, Any]:
    (row,) = rows(
        owner_db, "SELECT * FROM checkin_configurations WHERE user_id = %s", tokens["user"]["id"]
    )
    return dict(row)


def _events(owner_db: Db, tokens: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        dict(r)
        for r in rows(
            owner_db,
            "SELECT * FROM checkin_events WHERE user_id = %s ORDER BY received_at, id",
            tokens["user"]["id"],
        )
    ]


# --- recording --------------------------------------------------------------------------------


async def test_a_checkin_on_an_inactive_schedule_is_recorded_without_a_deadline(
    h: Harness, owner_db: Db
) -> None:
    tokens = await h.signup(OWNER)
    response = await _checkin(h, tokens)
    assert response.status_code == 200
    body = response.json()
    assert body["next_due_at"] is None
    assert body["incident_resolved"] is False
    assert body["server_time"] == "2026-10-08T09:00:00Z"
    assert body["checkin"]["kind"] == "ok"
    assert body["checkin"]["received_at"] == "2026-10-08T09:00:00Z"
    assert set(body) == {"checkin", "next_due_at", "incident_resolved", "server_time"}

    config = _config(owner_db, tokens)
    assert config["last_checkin_at"] == h.clock.current
    assert (config["status"], config["baseline_at"], config["next_due_at"]) == (
        "inactive",
        None,
        None,
    )
    (event,) = _events(owner_db, tokens)
    assert event["kind"] == "ok"
    assert event["source"] == "app"
    assert event["session_id"] is not None
    assert str(event["session_id"]) == tokens["session_id"]
    assert str(event["device_id"]) == tokens["device_id"]
    assert event["incident_id"] is None
    assert str(event["id"]) == body["checkin"]["id"]


async def test_a_checkin_on_an_active_schedule_moves_the_deadline(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(OWNER)
    await _activate(h, tokens)
    version = (await h.client.get("/v1/checkin/schedule", headers=bearer(tokens))).json()["version"]
    h.clock.advance(hours=2)  # 11:00Z = 16:30 IST
    tokens = await h.relogin(OWNER)

    response = await _checkin(h, tokens)
    assert response.status_code == 200
    assert response.json()["next_due_at"] == "2026-10-09T14:30:00Z"
    config = _config(owner_db, tokens)
    assert config["baseline_at"] == h.clock.current
    assert config["last_checkin_at"] == h.clock.current
    assert config["status"] == "active"
    # A check-in is not a schedule edit: the ETag a client holds stays valid.
    assert config["version"] == version
    (event,) = rows(owner_db, "SELECT * FROM audit_logs WHERE action = 'checkin.recorded'")
    assert event["user_visible"] is True
    assert event["resource_type"] == "checkin"
    assert event["metadata"] == {}


@pytest.mark.parametrize(
    ("now", "expected"),
    [
        # Daily 20:00 IST (14:30Z)
        (datetime(2026, 10, 13, 14, 0, tzinfo=UTC), "2026-10-14T14:30:00Z"),  # Tue 19:30 IST
        (datetime(2026, 10, 13, 4, 30, tzinfo=UTC), "2026-10-14T14:30:00Z"),  # Tue 10:00 IST
        (datetime(2026, 10, 13, 18, 29, tzinfo=UTC), "2026-10-14T14:30:00Z"),  # Tue 23:59 IST
        (datetime(2026, 10, 13, 18, 31, tzinfo=UTC), "2026-10-15T14:30:00Z"),  # Wed 00:01 IST
    ],
)
async def test_the_documented_vectors_through_the_api(
    h: Harness, now: datetime, expected: str
) -> None:
    h.clock.set(now)
    tokens = await h.signup(OWNER)
    await _activate(h, tokens)
    response = await _checkin(h, tokens)
    assert response.json()["next_due_at"] == expected


async def test_checking_in_early_is_fine(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    await _activate(h, tokens)
    first = await _checkin(h, tokens)
    second = await _checkin(h, tokens)
    assert first.status_code == second.status_code == 200
    assert first.json()["checkin"]["id"] != second.json()["checkin"]["id"]


# --- idempotency ------------------------------------------------------------------------------


async def test_the_same_key_replays_the_original_answer(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(OWNER)
    await _activate(h, tokens)
    k = key()
    first = await _checkin(h, tokens, k)
    h.clock.advance(minutes=10)
    tokens = await h.relogin(OWNER)
    config_after_first = _config(owner_db, tokens)
    second = await _checkin(h, tokens, k, body={"client_reported_at": "2026-10-08T12:00:00Z"})
    assert second.status_code == 200
    assert second.json() == first.json()
    assert second.headers["idempotent-replayed"] == "true"
    assert "idempotent-replayed" not in first.headers
    assert len(_events(owner_db, tokens)) == 1
    assert _config(owner_db, tokens) == config_after_first  # nothing moved on the replay
    assert len(rows(owner_db, "SELECT 1 FROM audit_logs WHERE action = 'checkin.recorded'")) == 1


async def test_keys_belong_to_the_user(h: Harness, owner_db: Db) -> None:
    alice = await h.signup("alice@example.com")
    bob = await h.signup("bob@example.com")
    k = key()
    assert (await _checkin(h, alice, k)).status_code == 200
    bobs = await _checkin(h, bob, k)
    assert bobs.status_code == 200
    assert len(_events(owner_db, alice)) == 1
    assert len(_events(owner_db, bob)) == 1


async def test_concurrent_requests_with_one_key_record_one_event(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(OWNER)
    await _activate(h, tokens)
    k = key()
    responses = await asyncio.gather(*(_checkin(h, tokens, k) for _ in range(8)))
    assert {r.status_code for r in responses} == {200}
    # (jsonb stores keys in its own order, so compare the parsed bodies, not the text)
    assert len({json.dumps(r.json(), sort_keys=True) for r in responses}) == 1
    assert len(_events(owner_db, tokens)) == 1


async def test_concurrent_requests_with_different_keys_are_all_recorded(
    h: Harness, owner_db: Db
) -> None:
    tokens = await h.signup(OWNER)
    await _activate(h, tokens)
    responses = await asyncio.gather(*(_checkin(h, tokens) for _ in range(6)))
    assert {r.status_code for r in responses} == {200}
    assert len(_events(owner_db, tokens)) == 6
    config = _config(owner_db, tokens)
    assert config["last_checkin_at"] == h.clock.current
    assert config["next_due_at"] == datetime(2026, 10, 9, 14, 30, tzinfo=UTC)


@pytest.mark.parametrize(
    "bad_key", ["", "short", "x" * 65, "has spaces in it......", "semi;colon;;;;;;;;;;"]
)
async def test_a_missing_or_malformed_key_is_rejected(
    h: Harness, owner_db: Db, bad_key: str
) -> None:
    tokens = await h.signup(OWNER)
    response = await h.client.post(
        "/v1/checkins", headers={**bearer(tokens), "Idempotency-Key": bad_key}
    )
    assert response.status_code == 422
    error = problem(response)
    assert error["code"] == "validation_failed"
    assert error["errors"][0]["field"] == "Idempotency-Key"
    assert _events(owner_db, tokens) == []


async def test_no_key_header_is_rejected(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(OWNER)
    response = await _checkin(h, tokens, send_key=False)
    assert response.status_code == 422
    assert problem(response)["errors"] == [
        {
            "field": "Idempotency-Key",
            "code": "required",
            "message": "Send a unique Idempotency-Key header (16 to 64 characters).",
        }
    ]
    assert _events(owner_db, tokens) == []


# --- client_reported_at is informational and never blocks a check-in --------------------------


async def test_the_client_time_is_stored_for_information(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(OWNER)
    response = await _checkin(h, tokens, body={"client_reported_at": "2026-10-08T14:31:00+05:30"})
    assert response.status_code == 200
    (event,) = _events(owner_db, tokens)
    assert event["client_reported_at"] == datetime(2026, 10, 8, 9, 1, tzinfo=UTC)
    assert event["received_at"] == h.clock.current  # the server's time decides everything


@pytest.mark.parametrize(
    "reported",
    [
        "1970-01-01T00:00:00Z",  # a phone whose clock battery died
        "2099-12-31T23:59:59Z" if False else "2101-01-01T00:00:00Z",
        "yesterday",
        "0001-01-01T00:00:00+05:00",  # cannot be expressed in UTC
        "2026-10-08T12:00:00",  # no offset
        12345,
        None,
        "",
    ],
)
async def test_an_unusable_client_time_never_blocks_the_checkin(
    h: Harness, owner_db: Db, reported: Any
) -> None:
    tokens = await h.signup(OWNER)
    response = await _checkin(h, tokens, body={"client_reported_at": reported})
    assert response.status_code == 200
    (event,) = _events(owner_db, tokens)
    assert event["client_reported_at"] is None


async def test_unknown_fields_are_rejected(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(OWNER)
    response = await _checkin(h, tokens, body={"next_due_at": "2030-01-01T00:00:00Z"})
    assert response.status_code == 422
    assert _events(owner_db, tokens) == []


@pytest.mark.parametrize("body", [None, {}])
async def test_the_body_is_optional(h: Harness, body: Any) -> None:
    tokens = await h.signup(OWNER)
    assert (await _checkin(h, tokens, body=body)).status_code == 200


async def test_the_client_cannot_choose_the_deadline(h: Harness, owner_db: Db) -> None:
    """INV-3: client timestamps are information, never inputs to a decision."""
    tokens = await h.signup(OWNER)
    await _activate(h, tokens)
    await _checkin(h, tokens, body={"client_reported_at": "2026-12-31T23:59:00Z"})
    assert _config(owner_db, tokens)["next_due_at"] == datetime(2026, 10, 9, 14, 30, tzinfo=UTC)


# --- limits and failure modes -----------------------------------------------------------------


async def test_thirty_distinct_checkins_per_hour_then_429_but_replays_still_work(
    h: Harness, owner_db: Db
) -> None:
    tokens = await h.signup(OWNER)
    keys = [key() for _ in range(30)]
    for k in keys:
        assert (await _checkin(h, tokens, k)).status_code == 200
    over = await _checkin(h, tokens)
    assert over.status_code == 429
    assert problem(over)["code"] == "rate_limited"
    assert int(over.headers["retry-after"]) > 0
    # A retry of something already recorded must always be answerable.
    assert (await _checkin(h, tokens, keys[0])).status_code == 200
    assert len(_events(owner_db, tokens)) == 30
    h.clock.advance(hours=1)
    tokens = await h.relogin(OWNER)
    assert (await _checkin(h, tokens)).status_code == 200


async def test_a_request_that_waited_for_the_lock_replays_what_the_holder_committed(
    h: Harness, owner_db: Db, migrated_database: str
) -> None:
    """Two taps with one key race: the loser blocks on the user lock, then must find the
    winner's event and return its answer instead of recording a second one."""
    tokens = await h.signup(OWNER)
    k = key()
    user_id = tokens["user"]["id"]
    event_id = str(uuid.uuid4())
    snapshot = {
        "checkin": {"id": event_id, "kind": "ok", "received_at": "2026-10-08T09:00:00Z"},
        "next_due_at": None,
        "incident_resolved": False,
        "server_time": "2026-10-08T09:00:00Z",
    }
    holder = psycopg.connect(conninfo("afterme_owner", "afterme_owner_dev", migrated_database))
    try:
        holder.execute(
            "SELECT 1 FROM checkin_configurations WHERE user_id = %s FOR UPDATE", (user_id,)
        )
        waiting = asyncio.create_task(_checkin(h, tokens, k))
        await asyncio.sleep(0.4)  # the request has passed its first lookup and waits for the lock
        assert not waiting.done()
        holder.execute(
            "INSERT INTO checkin_events (id, user_id, kind, source, received_at, "
            "idempotency_key, response_snapshot) VALUES (%s, %s, 'ok', 'app', now(), %s, %s)",
            (event_id, user_id, k, Jsonb(snapshot)),
        )
        holder.commit()
    finally:
        holder.close()
    response = await waiting
    assert response.status_code == 200
    assert response.json() == snapshot
    assert len(_events(owner_db, tokens)) == 1


@pytest.mark.settings(api_lock_timeout_ms=300)
async def test_a_busy_user_lock_is_a_retryable_503_and_the_retry_succeeds(
    h: Harness, owner_db: Db, migrated_database: str
) -> None:
    tokens = await h.signup(OWNER)
    k = key()
    holder = psycopg.connect(conninfo("afterme_owner", "afterme_owner_dev", migrated_database))
    try:
        holder.execute(
            "SELECT 1 FROM checkin_configurations WHERE user_id = %s FOR UPDATE",
            (tokens["user"]["id"],),
        )
        blocked = await _checkin(h, tokens, k)
        assert blocked.status_code == 503
        assert problem(blocked)["code"] == "service_unavailable"
        assert _events(owner_db, tokens) == []
    finally:
        holder.rollback()
        holder.close()
    retried = await _checkin(h, tokens, k)
    assert retried.status_code == 200
    assert len(_events(owner_db, tokens)) == 1


async def test_a_checkin_requires_a_session(h: Harness) -> None:
    response = await h.client.post("/v1/checkins", headers={"Idempotency-Key": key()})
    assert response.status_code == 401


async def test_one_users_checkin_never_touches_anothers_schedule(h: Harness, owner_db: Db) -> None:
    alice = await h.signup("alice@example.com")
    bob = await h.signup("bob@example.com")
    await _activate(h, alice)
    before = _config(owner_db, alice)
    await _checkin(h, bob)
    assert _config(owner_db, alice) == before


# --- history ----------------------------------------------------------------------------------


async def _history(h: Harness, tokens: dict[str, Any], **params: Any) -> httpx.Response:
    return await h.client.get("/v1/checkins", params=params, headers=bearer(tokens))


async def test_history_is_newest_first_and_paged(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    ids: list[str] = []
    for _ in range(5):
        h.clock.advance(minutes=1)  # five minutes in all: inside the access token's lifetime
        ids.append((await _checkin(h, tokens)).json()["checkin"]["id"])

    first = (await _history(h, tokens, limit=2)).json()
    assert [i["id"] for i in first["items"]] == ids[::-1][:2]
    assert first["next_cursor"]
    assert set(first["items"][0]) == {"id", "kind", "source", "received_at"}
    assert first["items"][0]["kind"] == "ok"
    assert first["items"][0]["source"] == "app"

    second = (await _history(h, tokens, limit=2, cursor=first["next_cursor"])).json()
    assert [i["id"] for i in second["items"]] == ids[::-1][2:4]
    third = (await _history(h, tokens, limit=2, cursor=second["next_cursor"])).json()
    assert [i["id"] for i in third["items"]] == ids[::-1][4:]
    assert third["next_cursor"] is None


async def test_history_paging_is_stable_when_timestamps_tie(h: Harness) -> None:
    """The frozen clock gives every event the same ``received_at``: the id breaks the tie."""
    tokens = await h.signup(OWNER)
    ids = {(await _checkin(h, tokens)).json()["checkin"]["id"] for _ in range(7)}
    seen: list[str] = []
    cursor: str | None = None
    while True:
        params: dict[str, Any] = {"limit": 3}
        if cursor:
            params["cursor"] = cursor
        page = (await _history(h, tokens, **params)).json()
        seen += [i["id"] for i in page["items"]]
        cursor = page["next_cursor"]
        if cursor is None:
            break
    assert len(seen) == 7
    assert set(seen) == ids


async def test_history_defaults_and_bounds(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    empty = (await _history(h, tokens)).json()
    assert empty == {"items": [], "next_cursor": None}
    for bad in (0, 101, -1):
        response = await _history(h, tokens, limit=bad)
        assert response.status_code == 422, bad
        assert problem(response)["code"] == "validation_failed"
    assert (await _history(h, tokens, limit=100)).status_code == 200


@pytest.mark.parametrize("cursor", ["!!!", "bm90LWEtY3Vyc29y", "djE6eDp5", "A" * 300])
async def test_a_bad_cursor_is_rejected(h: Harness, cursor: str) -> None:
    tokens = await h.signup(OWNER)
    response = await _history(h, tokens, cursor=cursor)
    assert response.status_code == 422
    assert problem(response)["code"] == "validation_failed"


async def test_history_shows_only_the_callers_events(h: Harness) -> None:
    alice = await h.signup("alice@example.com")
    bob = await h.signup("bob@example.com")
    mine = (await _checkin(h, alice)).json()["checkin"]["id"]
    await _checkin(h, bob)
    page = (await _history(h, alice)).json()
    assert [i["id"] for i in page["items"]] == [mine]

    # Another user's cursor only ever pages through the caller's own rows.
    bobs_page = (await _history(h, bob, limit=1)).json()
    assert bobs_page["next_cursor"] is None


# --- review findings: monotonic baseline, verbatim replay, fail-safe states -------------------


def _received_times(owner_db: Db, tokens: dict[str, Any]) -> list[datetime]:
    return [e["received_at"] for e in _events(owner_db, tokens)]


async def test_the_last_checkin_and_the_baseline_never_move_backwards(
    h: Harness, owner_db: Db
) -> None:
    """A request whose transaction started earlier can commit after a later one (it waited for
    the lock). The frozen clock is moved back to stand for that."""
    tokens = await h.signup(OWNER)
    await _activate(h, tokens)
    h.clock.advance(minutes=10)
    assert (await _checkin(h, tokens)).status_code == 200
    later = _config(owner_db, tokens)

    h.clock.set(h.clock.current - timedelta(minutes=5))
    response = await _checkin(h, tokens)
    assert response.status_code == 200

    config = _config(owner_db, tokens)
    assert config["last_checkin_at"] == later["last_checkin_at"]
    assert config["baseline_at"] == later["baseline_at"]
    assert config["next_due_at"] == later["next_due_at"]
    # The event itself keeps its own receipt time.
    assert max(_received_times(owner_db, tokens)) == later["last_checkin_at"]
    assert min(_received_times(owner_db, tokens)) < later["last_checkin_at"]


async def test_a_schedule_change_never_sets_a_baseline_before_a_recorded_checkin(
    h: Harness, owner_db: Db
) -> None:
    """ESCALATION_ENGINE §6.3: a check-in with received_at > baseline_at is an inconsistency
    the engine refuses to escalate over, so no restart may produce one."""
    tokens = await h.signup(OWNER)
    await _activate(h, tokens)
    h.clock.advance(minutes=10)
    assert (await _checkin(h, tokens)).status_code == 200
    newest = max(_received_times(owner_db, tokens))

    h.clock.set(h.clock.current - timedelta(minutes=5))  # a request that started earlier
    assert (await h.reauth(tokens)).status_code == 204  # lengthening an active schedule
    version = (await h.client.get("/v1/checkin/schedule", headers=bearer(tokens))).json()["version"]
    put = await h.client.put(
        "/v1/checkin/schedule",
        json={"interval_days": 2, "due_local_time": "21:30", "reminder_lead_minutes": 30},
        headers={**bearer(tokens), "If-Match": f'"sched-{version}"'},
    )
    assert put.status_code == 200
    assert _config(owner_db, tokens)["baseline_at"] >= newest

    patched = await h.client.patch(
        "/v1/me/profile", json={"timezone": "America/New_York"}, headers=bearer(tokens)
    )
    assert patched.status_code == 200
    assert _config(owner_db, tokens)["baseline_at"] >= newest


async def test_activation_never_sets_a_baseline_before_a_recorded_checkin(
    h: Harness, owner_db: Db
) -> None:
    tokens = await h.signup(OWNER)
    await h.add_contact(tokens, "mom@example.com")
    h.clock.advance(minutes=10)
    assert (await _checkin(h, tokens)).status_code == 200  # inactive: history only
    newest = max(_received_times(owner_db, tokens))

    h.clock.set(h.clock.current - timedelta(minutes=5))
    await h.plan_for_contacts(tokens)
    activated = await h.client.post("/v1/checkin/activate", headers=bearer(tokens))
    assert activated.status_code == 200
    config = _config(owner_db, tokens)
    assert config["baseline_at"] >= newest
    assert config["baseline_at"] == config["last_checkin_at"]


async def test_a_replay_is_the_stored_json_even_if_the_response_model_has_changed(
    h: Harness, owner_db: Db
) -> None:
    """A release that adds, renames or drops a response field must not turn the retry of a
    tap the server already recorded into an error."""
    tokens = await h.signup(OWNER)
    k = key()
    stored = {
        "checkin": {"id": str(uuid.uuid4()), "kind": "ok", "received_at": "2026-10-08T09:00:00Z"},
        "next_due_at": None,
        "server_time": "2026-10-08T09:00:00Z",
        "a_field_from_an_older_release": {"nested": [1, 2, 3]},
        # no "incident_resolved": a newer model would require it
    }
    owner_db.execute(
        "INSERT INTO checkin_events (user_id, kind, source, received_at, idempotency_key, "
        "response_snapshot) VALUES (%s, 'ok', 'app', now(), %s, %s)",
        (tokens["user"]["id"], k, Jsonb(stored)),
    )
    response = await _checkin(h, tokens, k)
    assert response.status_code == 200
    assert response.json() == stored
    assert response.headers["idempotent-replayed"] == "true"
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["content-type"].startswith("application/json")


async def test_a_first_answer_is_not_marked_as_a_replay(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    first = await _checkin(h, tokens)
    assert "idempotent-replayed" not in first.headers
    assert first.headers["cache-control"] == "no-store"


async def test_a_checkin_repairs_a_configuration_that_claims_a_missing_incident(
    h: Harness, owner_db: Db
) -> None:
    """The configuration says an incident is open but no incident row exists (it cannot happen
    through the API). The person's check-in is the stop operation: it is recorded and the
    schedule is restored, instead of leaving them unable to check in."""
    tokens = await h.signup(OWNER)
    await _activate(h, tokens)
    owner_db.execute(
        "UPDATE checkin_configurations SET status = 'incident_open' WHERE user_id = %s",
        (tokens["user"]["id"],),
    )
    response = await _checkin(h, tokens)
    assert response.status_code == 200
    assert response.json()["incident_resolved"] is False
    config = _config(owner_db, tokens)
    assert config["status"] == "active"
    assert config["next_due_at"] is not None
    assert len(_events(owner_db, tokens)) == 1


async def test_a_failed_commit_leaves_nothing_behind_and_the_retry_records_once(
    h: Harness, owner_db: Db, monkeypatch: pytest.MonkeyPatch
) -> None:
    """ENG-FS-01: a database error at COMMIT is a retryable 503, with no partial rows."""
    tokens = await h.signup(OWNER)
    await _activate(h, tokens)
    before = _config(owner_db, tokens)
    k = key()

    real_commit = AsyncSession.commit
    calls = {"n": 0}

    async def failing_commit(self: AsyncSession) -> None:
        calls["n"] += 1
        if calls["n"] == 1:
            await self.rollback()
            raise OperationalError("COMMIT", {}, psycopg.errors.AdminShutdown("shutdown"))
        await real_commit(self)

    monkeypatch.setattr(AsyncSession, "commit", failing_commit)
    failed = await _checkin(h, tokens, k)
    assert failed.status_code == 503
    assert _events(owner_db, tokens) == []
    assert _config(owner_db, tokens) == before
    assert rows(owner_db, "SELECT 1 FROM audit_logs WHERE action = 'checkin.recorded'") == []

    retried = await _checkin(h, tokens, k)
    assert retried.status_code == 200
    assert len(_events(owner_db, tokens)) == 1
