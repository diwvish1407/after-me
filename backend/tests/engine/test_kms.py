"""Cloud KMS in the running system: an outage, the worker, re-wrap and key rotation (Phase 12).

The application runs with ``KMS_PROVIDER=gcp_kms`` against a fake Cloud KMS that really encrypts
(``tests/fake_cloud_kms.py``). Two questions matter:

* **A KMS outage must not hurt what keeps people safe.** Check-in, I'M SAFE, login, home and the
  engine, which never decrypt, work with the KMS down; a release email still goes out; only the
  paths that need a key say "temporarily unavailable", and say nothing else.
* **Rotation must be safe to interrupt, safe to repeat, and safe against a process that still
  holds the old key.**
"""

from __future__ import annotations

import asyncio
import json
import uuid
from collections.abc import AsyncIterator
from datetime import timedelta
from typing import Any

import httpx
import pytest

from app.api.container import AppServices, build_services, build_worker_services
from app.core.config import Settings
from app.ops import kms as kms_ops
from app.ops.users import UserCommandError
from app.security import envelope
from app.security.envelope import DecryptionError
from app.security.gcp_kms import GcpKms
from app.security.kms import KmsError, UnavailableKms
from cli import admin as cli
from tests.engine.test_release import STAGE_2, TITLE, Portal, _setup, address
from tests.fake_cloud_kms import KEY_NAME, FakeCloudKms, StaticToken
from tests.support import make_settings
from tests.world import Person, World

pytestmark = pytest.mark.settings()


@pytest.fixture
def fake_kms(monkeypatch: pytest.MonkeyPatch) -> FakeCloudKms:
    fake = FakeCloudKms()
    fake.builds = 0  # type: ignore[attr-defined]

    def build(_settings: Settings, *, client: httpx.AsyncClient | None = None) -> GcpKms:
        fake.builds += 1  # type: ignore[attr-defined]
        return GcpKms(
            KEY_NAME, StaticToken(), client=fake.client(), retry_delays=(0.0,), breaker_seconds=0.0
        )

    monkeypatch.setattr("app.api.container.build_gcp_kms", build)
    return fake


@pytest.fixture
def settings(fake_kms: FakeCloudKms) -> Settings:  # overrides tests/conftest.py's
    return make_settings(kms_provider="gcp_kms", kms_key_name=KEY_NAME)


@pytest.fixture
async def ops(world: World) -> AsyncIterator[AppServices]:
    """What ``python -m cli.admin kms ...`` builds: its own container (its own vault, so its
    own key cache), connected as the API role, on the test clock."""
    services = build_services(
        world.h.settings, clock=world.clock, application_name="test-kms-admin"
    )
    yield services
    await services.db.dispose()


def _uid(person: Person) -> uuid.UUID:
    return uuid.UUID(person.user_id)


async def _with_instructions(world: World, email: str = "keys@example.com", n: int = 3) -> Person:
    person = await world.person(email, premium=True)
    for i in range(n):
        made = await world.call(
            person,
            "POST",
            "/v1/instructions",
            json={"category": "home", "title": f"Title {i}", "body": f"Body number {i}"},
        )
        assert made.status_code == 201, made.text
    return person


def _key_row(world: World, person: Person) -> dict[str, Any]:
    row = world.db.execute(
        "SELECT * FROM user_keys WHERE user_id = %s", (person.user_id,)
    ).fetchone()
    assert row is not None
    return dict(row)


def _blobs(world: World, person: Person) -> dict[uuid.UUID, tuple[bytes, int]]:
    rows = world.db.execute(
        "SELECT id, content_ciphertext, content_key_version FROM instructions "
        "WHERE user_id = %s ORDER BY id",
        (person.user_id,),
    ).fetchall()
    return {r["id"]: (bytes(r["content_ciphertext"]), r["content_key_version"]) for r in rows}


async def _read_all(world: World, person: Person) -> list[dict[str, Any]]:
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    listed = await world.h.client.get("/v1/instructions", headers=person.headers)
    assert listed.status_code == 200, listed.text
    items: list[dict[str, Any]] = listed.json()["items"]
    return items


# =========================================================================== the outage


async def test_the_worker_never_builds_or_uses_a_kms(world: World, fake_kms: FakeCloudKms) -> None:
    assert fake_kms.builds == 1  # type: ignore[attr-defined]  # the API's, and not the world's worker
    worker = world.engine.services
    assert isinstance(worker.vault.kms, UnavailableKms)
    other = build_worker_services(world.h.settings)
    try:
        assert isinstance(other.vault.kms, UnavailableKms)
        assert fake_kms.builds == 1  # type: ignore[attr-defined]
        with pytest.raises(KmsError) as refused:
            await other.vault.kms.wrap(b"x" * 32, user_id=uuid.uuid4())
        assert refused.value.code == "not_configured"
    finally:
        await other.db.dispose()
    assert fake_kms.count() == 0


async def test_what_keeps_people_safe_works_with_the_kms_down(
    world: World, fake_kms: FakeCloudKms
) -> None:
    person = await _setup(world)
    api_vault = world.h.app.state.services.vault
    api_vault.forget(_uid(person))  # a cold cache: nothing can be served from memory
    fake_kms.outage(503)
    calls_before = fake_kms.count()

    # login, home, a check-in: no key involved
    await world.login(person)
    home = await world.h.client.get("/v1/home", headers=person.headers)
    assert home.status_code == 200, home.text
    await world.checkin(person)
    assert (await world.h.client.get("/v1/me", headers=person.headers)).status_code == 200

    # the engine ticks (and, in the next test, runs a whole release) without a key
    await world.tick()
    assert fake_kms.count() == calls_before  # nothing in all of that asked the KMS


async def test_a_release_email_goes_out_and_the_portal_says_temporarily_unavailable(
    world: World, fake_kms: FakeCloudKms
) -> None:
    person = await _setup(world)
    world.h.app.state.services.vault.forget(_uid(person))
    fake_kms.outage(503)
    await world.advance_to(STAGE_2 + timedelta(minutes=6))

    # the link went out although no key could have been unwrapped
    alerts = world.mail.to(address(person, "Brother"), "contact_alert_with_release")
    assert len(alerts) == 1
    assert "/c/release#rt_" in alerts[0].text
    assert TITLE not in alerts[0].text
    assert world.db.execute("SELECT count(*) AS n FROM release_events").fetchone()["n"] == 1  # type: ignore[index]

    # the contact gets as far as the code and then a plain page, not an error page
    shown = await Portal(world).reach_content(person)
    assert shown.status_code == 503
    page = shown.text.replace("&#39;", "'")
    assert "couldn't show this right now" in page
    assert "Nothing has been lost" in page
    assert "withdrawn" not in page
    for leaked in (TITLE, "kms", "KMS", "cloudkms", KEY_NAME, "Traceback", "Error"):
        assert leaked not in page, leaked
    assert world.db.execute("SELECT view_count FROM release_events").fetchone()["view_count"] == 0  # type: ignore[index]

    # I'M SAFE still works with the KMS down, and takes the release back
    incident = world.open_incident(person)
    assert incident is not None
    await world.safe(person, str(incident["id"]))
    await world.tick()
    assert world.db.execute("SELECT revoked_at FROM release_events").fetchone()["revoked_at"]  # type: ignore[index]


async def test_the_portal_shows_the_content_again_when_the_kms_recovers(
    world: World, fake_kms: FakeCloudKms
) -> None:
    person = await _setup(world)
    world.h.app.state.services.vault.forget(_uid(person))
    fake_kms.outage(httpx.ConnectError("no route"))
    await world.advance_to(STAGE_2 + timedelta(minutes=6))
    portal = Portal(world)
    assert (await portal.reach_content(person)).status_code == 503
    fake_kms.recover()
    shown = await portal.post("/c/release/view")
    assert shown.status_code == 200
    assert TITLE in shown.text


async def test_the_paths_that_need_a_key_say_temporarily_unavailable_and_nothing_else(
    world: World, fake_kms: FakeCloudKms
) -> None:
    person = await _with_instructions(world, n=1)
    first = (await _read_all(world, person))[0]["id"]
    world.h.app.state.services.vault.forget(_uid(person))
    fake_kms.outage(403)  # even a refusal (an IAM mistake) is "unavailable" to the person
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204

    responses = {
        "create": await world.h.client.post(
            "/v1/instructions",
            json={"category": "home", "title": "New", "body": "text"},
            headers=person.headers,
        ),
        "list": await world.h.client.get("/v1/instructions", headers=person.headers),
        "read": await world.h.client.get(f"/v1/instructions/{first}", headers=person.headers),
        "edit text": await world.h.client.patch(
            f"/v1/instructions/{first}", json={"body": "other"}, headers=person.headers
        ),
    }
    for name, response in responses.items():
        assert response.status_code == 503, (name, response.status_code, response.text)
        assert response.headers["retry-after"] == "5"
        body = response.json()
        assert body["code"] == "service_unavailable"
        assert "temporarily unavailable" in body["detail"]
        for leaked in ("kms", "KMS", "cloudkms", KEY_NAME, "permission", "denied", "Traceback"):
            assert leaked not in response.text, (name, leaked)
    # nothing was half-written
    assert len(_blobs(world, person)) == 1
    # the response of an edit shows the text, so even a status change waits for the key; and the
    # refused change is rolled back, not half applied
    status_only = await world.h.client.patch(
        f"/v1/instructions/{first}", json={"status": "inactive"}, headers=person.headers
    )
    assert status_only.status_code == 503
    row = world.db.execute("SELECT status FROM instructions WHERE id = %s", (first,)).fetchone()
    assert row is not None
    assert row["status"] == "active"

    # the export names what it could not open instead of failing as a whole
    export = await world.h.client.post("/v1/me/export", json={}, headers=person.headers)
    assert export.status_code in (200, 201, 202), export.text
    document = json.loads(export.text)
    assert document["instructions"][0]["error"] == "content_unavailable"
    assert "Body number" not in export.text

    fake_kms.recover()
    assert (await world.h.reauth(person.tokens)).status_code == 204
    again = await world.h.client.get(f"/v1/instructions/{first}", headers=person.headers)
    assert again.status_code == 200
    assert again.json()["body"] == "Body number 0"


# =========================================================================== re-wrap


async def test_rewrap_skips_what_is_current_and_dry_run_writes_nothing(
    world: World, fake_kms: FakeCloudKms, ops: AppServices
) -> None:
    people = [await _with_instructions(world, f"p{i}@example.com", n=1) for i in range(2)]
    before = [_key_row(world, p) for p in people]
    report = await kms_ops.rewrap(ops, operator="alice")
    assert (report.examined, report.current, report.rewrapped) == (2, 2, 0)
    assert report.complete
    assert [_key_row(world, p) for p in people] == before

    fake_kms.rotate()
    dry = await kms_ops.rewrap(ops, operator="alice", dry_run=True)
    assert (dry.would_rewrap, dry.rewrapped, dry.dry_run) == (2, 0, True)
    assert [_key_row(world, p) for p in people] == before
    assert (
        world.db.execute(
            "SELECT count(*) AS n FROM audit_logs WHERE action = 'operator.kms_rewrap'"
        ).fetchone()["n"]
        == 0
    )  # type: ignore[index]


async def test_rewrap_moves_every_key_to_the_new_version_without_touching_the_content(
    world: World, fake_kms: FakeCloudKms, ops: AppServices
) -> None:
    people = [await _with_instructions(world, f"p{i}@example.com", n=2) for i in range(3)]
    old_keys = {p.user_id: _key_row(world, p) for p in people}
    old_blobs = {p.user_id: _blobs(world, p) for p in people}
    fake_kms.rotate()

    # in pieces: --limit 2, then the rest, then nothing left
    first = await kms_ops.rewrap(ops, operator="alice", limit=2)
    assert (first.rewrapped, first.stopped_by_limit, first.complete) == (2, True, False)
    second = await kms_ops.rewrap(ops, operator="alice")
    assert (second.rewrapped, second.current, second.complete) == (1, 2, True)
    third = await kms_ops.rewrap(ops, operator="alice")
    assert (third.rewrapped, third.current) == (0, 3)

    for p in people:
        row = _key_row(world, p)
        assert row["wrapped_dek"] != old_keys[p.user_id]["wrapped_dek"]
        assert row["dek_version"] == old_keys[p.user_id]["dek_version"] == 1  # the DEK is the same
        assert row["rotated_at"] is None
        assert _blobs(world, p) == old_blobs[p.user_id]  # not one content byte changed
    # the old version can now be disabled: everything still opens (this process caches nothing)
    fake_kms.versions[0] = b"\x00" * 32
    for p in people:
        world.h.app.state.services.vault.forget(_uid(p))
        titles = [i["title"] for i in await _read_all(world, p)]
        assert len(titles) == 2

    audit = world.db.execute(
        "SELECT * FROM audit_logs WHERE action = 'operator.kms_rewrap' ORDER BY id"
    ).fetchall()
    assert len(audit) == 3
    assert {a["subject_user_id"] for a in audit} == {uuid.UUID(p.user_id) for p in people}
    for a in audit:
        assert a["actor_type"] == "operator"
        assert a["user_visible"] is False
        assert a["metadata"]["operator"] == "alice"
        assert set(a["metadata"]) == {"operator", "dek_version"}


async def test_a_killed_rewrap_leaves_every_user_whole_and_the_rerun_finishes(
    world: World, fake_kms: FakeCloudKms, ops: AppServices, monkeypatch: pytest.MonkeyPatch
) -> None:
    people = [await _with_instructions(world, f"p{i}@example.com", n=1) for i in range(2)]
    fake_kms.rotate()
    before = {p.user_id: _key_row(world, p) for p in people}
    real_record = ops.audit.record
    calls = {"n": 0}

    async def die_on_the_second(session: Any, event: Any) -> None:
        calls["n"] += 1
        if calls["n"] == 2:
            raise RuntimeError("the process was killed")
        await real_record(session, event)

    monkeypatch.setattr(ops.audit, "record", die_on_the_second)
    with pytest.raises(RuntimeError):
        await kms_ops.rewrap(ops, operator="alice")
    rows = [_key_row(world, p) for p in people]
    changed = [r for r, p in zip(rows, people, strict=True) if r != before[p.user_id]]
    assert len(changed) == 1  # one user wholly done, the other wholly untouched
    assert (
        world.db.execute(
            "SELECT count(*) AS n FROM audit_logs WHERE action = 'operator.kms_rewrap'"
        ).fetchone()["n"]
        == 1
    )  # type: ignore[index]

    monkeypatch.setattr(ops.audit, "record", real_record)
    done = await kms_ops.rewrap(ops, operator="alice")
    assert (done.rewrapped, done.current, done.complete) == (1, 1, True)


async def test_rewrap_leaves_a_busy_user_for_the_next_run_and_never_waits(
    world: World, fake_kms: FakeCloudKms, ops: AppServices
) -> None:
    person = await _with_instructions(world, n=1)
    fake_kms.rotate()
    before = _key_row(world, person)
    with world.db.transaction():  # a request holds the user's lock
        world.db.execute(
            "SELECT 1 FROM checkin_configurations WHERE user_id = %s FOR UPDATE", (person.user_id,)
        )
        report = await asyncio.wait_for(kms_ops.rewrap(ops, operator="alice"), timeout=5)
    assert (report.busy, report.rewrapped, report.complete) == (1, 0, False)
    assert _key_row(world, person) == before
    assert (await kms_ops.rewrap(ops, operator="alice")).rewrapped == 1


async def test_rewrap_does_not_overwrite_a_key_that_changed_under_it(
    world: World, fake_kms: FakeCloudKms, ops: AppServices, monkeypatch: pytest.MonkeyPatch
) -> None:
    person = await _with_instructions(world, n=1)
    fake_kms.rotate()
    kms = ops.vault.kms
    real_wrap = kms.wrap

    async def wrap_then_someone_rotates(dek: bytes, *, user_id: uuid.UUID) -> tuple[bytes, str]:
        result = await real_wrap(dek, user_id=user_id)
        world.db.execute(
            "UPDATE user_keys SET dek_version = dek_version + 1 WHERE user_id = %s",
            (person.user_id,),
        )
        return result

    monkeypatch.setattr(kms, "wrap", wrap_then_someone_rotates)
    report = await kms_ops.rewrap(ops, operator="alice")
    assert (report.changed, report.rewrapped, report.complete) == (1, 0, False)
    assert _key_row(world, person)["dek_version"] == 2  # theirs, not overwritten


async def test_rewrap_stops_when_the_kms_keeps_failing_and_changes_nothing(
    world: World, fake_kms: FakeCloudKms, ops: AppServices, monkeypatch: pytest.MonkeyPatch
) -> None:
    people = [await _with_instructions(world, f"p{i}@example.com", n=1) for i in range(3)]
    before = [_key_row(world, p) for p in people]
    monkeypatch.setattr(kms_ops, "ABORT_AFTER_CONSECUTIVE_FAILURES", 2)
    fake_kms.outage(503)
    report = await kms_ops.rewrap(ops, operator="alice")
    assert report.aborted
    assert report.failed == 2
    assert report.failure_codes == {"unavailable": 2}
    assert not report.complete
    assert [_key_row(world, p) for p in people] == before


# =========================================================================== rotate-user


async def test_rotate_user_replaces_the_key_and_re_encrypts_every_instruction(
    world: World, fake_kms: FakeCloudKms, ops: AppServices
) -> None:
    person = await _with_instructions(world, n=3)
    bystander = await _with_instructions(world, "other@example.com", n=1)
    old_key, old_blobs = _key_row(world, person), _blobs(world, person)
    other_key, other_blobs = _key_row(world, bystander), _blobs(world, bystander)
    meta_before = world.db.execute(
        "SELECT id, content_version, updated_at FROM instructions WHERE user_id = %s ORDER BY id",
        (person.user_id,),
    ).fetchall()
    expected = {i["id"]: i["title"] for i in await _read_all(world, person)}
    assert len(expected) == 3

    result = await kms_ops.rotate_user(
        ops, operator="alice", user_id=_uid(person), reason="ticket SEC-7: key may have been seen"
    )
    assert (result.from_version, result.to_version, result.instructions) == (1, 2, 3)

    key = _key_row(world, person)
    assert key["dek_version"] == 2
    assert key["wrapped_dek"] != old_key["wrapped_dek"]
    assert key["rotated_at"] is not None
    blobs = _blobs(world, person)
    assert set(blobs) == set(old_blobs)
    for instruction_id, (blob, version) in blobs.items():
        assert version == 2
        assert blob != old_blobs[instruction_id][0]
    # content_version and updated_at are the person's edits, not the operator's rotation
    assert (
        world.db.execute(
            "SELECT id, content_version, updated_at FROM instructions "
            "WHERE user_id = %s ORDER BY id",
            (person.user_id,),
        ).fetchall()
        == meta_before
    )
    # somebody else's key and content: untouched
    assert _key_row(world, bystander) == other_key
    assert _blobs(world, bystander) == other_blobs

    # the owner reads the same text (this process's cache was warm with the OLD key)
    assert {i["id"]: i["title"] for i in await _read_all(world, person)} == {
        str(k): v for k, v in expected.items()
    }

    audit = world.db.execute(
        "SELECT * FROM audit_logs WHERE action = 'operator.kms_rotate_user'"
    ).fetchall()
    assert len(audit) == 1
    meta = audit[0]["metadata"]
    assert audit[0]["actor_type"] == "operator"
    assert audit[0]["user_visible"] is False
    assert audit[0]["subject_user_id"] == _uid(person)
    assert (meta["from_version"], meta["to_version"], meta["instructions"]) == (1, 2, 3)
    assert meta["operator_note"] == "ticket SEC-7: key may have been seen"
    assert "wrapped" not in json.dumps(meta)


async def test_an_api_process_holding_the_old_key_reads_and_writes_correctly_after_a_rotation(
    world: World, fake_kms: FakeCloudKms, ops: AppServices
) -> None:
    person = await _with_instructions(world, n=2)
    uid = _uid(person)
    api_vault = world.h.app.state.services.vault
    assert uid in api_vault._cache  # warm: this process holds DEK version 1
    old_dek = api_vault._cache[uid].dek

    await kms_ops.rotate_user(ops, operator="alice", user_id=uid, reason="suspected exposure")
    assert api_vault._cache[uid].version == 1  # stale: another process rotated

    # a READ with the stale key: finds the ciphertext one version ahead, looks again, succeeds
    items = await _read_all(world, person)
    assert sorted(i["title"] for i in items) == ["Title 0", "Title 1"]
    assert api_vault._cache[uid].version == 2
    # and the retired key opens nothing that exists now
    for instruction_id, (blob, version) in _blobs(world, person).items():
        with pytest.raises(DecryptionError):
            envelope.decrypt(
                old_dek, blob, aad=envelope.instruction_aad(uid, instruction_id, version)
            )


async def test_an_api_process_with_the_old_key_never_seals_under_it(
    world: World, fake_kms: FakeCloudKms, ops: AppServices
) -> None:
    person = await _with_instructions(world, n=1)
    uid = _uid(person)
    api_vault = world.h.app.state.services.vault
    assert api_vault._cache[uid].version == 1
    await kms_ops.rotate_user(ops, operator="alice", user_id=uid, reason="suspected exposure")

    # a WRITE from the stale process: the vault checks dek_version under the user's lock
    created = await world.call(
        person,
        "POST",
        "/v1/instructions",
        json={"category": "home", "title": "After rotation", "body": "sealed under key 2"},
    )
    assert created.status_code == 201, created.text
    versions = {v for _, v in _blobs(world, person).values()}
    assert versions == {2}  # nothing is sealed under the retired key, and so nothing is lost
    titles = sorted(i["title"] for i in await _read_all(world, person))
    assert titles == ["After rotation", "Title 0"]


async def test_a_stale_process_that_cannot_reach_the_kms_fails_closed(
    world: World, fake_kms: FakeCloudKms, ops: AppServices
) -> None:
    person = await _with_instructions(world, n=1)
    await kms_ops.rotate_user(
        ops, operator="alice", user_id=_uid(person), reason="suspected exposure"
    )
    fake_kms.outage(503)
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    response = await world.h.client.get("/v1/instructions", headers=person.headers)
    assert response.status_code == 503  # not a wrong answer, not old content, not a 500
    created = await world.h.client.post(
        "/v1/instructions",
        json={"category": "home", "title": "x", "body": "y"},
        headers=person.headers,
    )
    assert created.status_code == 503
    assert {v for _, v in _blobs(world, person).values()} == {2}


async def test_rotate_user_does_not_hold_the_users_lock_across_the_kms_call(
    world: World, fake_kms: FakeCloudKms, ops: AppServices
) -> None:
    person = await _with_instructions(world, n=1)
    kms = ops.vault.kms
    real_wrap = kms.wrap
    entered, release = asyncio.Event(), asyncio.Event()

    async def slow_wrap(dek: bytes, *, user_id: uuid.UUID) -> tuple[bytes, str]:
        entered.set()
        await release.wait()
        return await real_wrap(dek, user_id=user_id)

    kms.wrap = slow_wrap  # type: ignore[method-assign]
    task = asyncio.create_task(
        kms_ops.rotate_user(ops, operator="alice", user_id=_uid(person), reason="slow KMS")
    )
    await asyncio.wait_for(entered.wait(), timeout=5)
    # the KMS call is in flight: a check-in (which takes the same lock) goes straight through
    await asyncio.wait_for(world.checkin(person), timeout=5)
    release.set()
    result = await asyncio.wait_for(task, timeout=10)
    assert result.to_version == 2


async def test_a_failed_rotation_changes_nothing(
    world: World, fake_kms: FakeCloudKms, ops: AppServices, monkeypatch: pytest.MonkeyPatch
) -> None:
    person = await _with_instructions(world, n=3)
    key, blobs = _key_row(world, person), _blobs(world, person)

    # killed after the instructions were rewritten, before the commit
    async def die(_session: Any, _event: Any) -> None:
        raise RuntimeError("the process was killed")

    real = ops.audit.record
    monkeypatch.setattr(ops.audit, "record", die)
    with pytest.raises(RuntimeError):
        await kms_ops.rotate_user(ops, operator="alice", user_id=_uid(person), reason="try")
    monkeypatch.setattr(ops.audit, "record", real)
    assert (_key_row(world, person), _blobs(world, person)) == (key, blobs)

    # the KMS is down at the start
    fake_kms.outage(503)
    with pytest.raises(UserCommandError, match="KMS refused"):
        await kms_ops.rotate_user(ops, operator="alice", user_id=_uid(person), reason="try")
    fake_kms.recover()
    assert (_key_row(world, person), _blobs(world, person)) == (key, blobs)

    # one ciphertext does not open under the current key: refuse, with nothing half-done
    victim = sorted(blobs)[1]
    world.db.execute(
        "UPDATE instructions SET content_ciphertext = %s WHERE id = %s",
        (blobs[victim][0][:-1] + bytes([blobs[victim][0][-1] ^ 1]), victim),
    )
    damaged = _blobs(world, person)
    with pytest.raises(UserCommandError, match="cannot be opened"):
        await kms_ops.rotate_user(ops, operator="alice", user_id=_uid(person), reason="try")
    assert _blobs(world, person) == damaged
    assert _key_row(world, person) == key
    assert (
        world.db.execute(
            "SELECT count(*) AS n FROM audit_logs WHERE action = 'operator.kms_rotate_user'"
        ).fetchone()["n"]
        == 0
    )  # type: ignore[index]


async def test_rotate_user_refuses_what_it_cannot_do(
    world: World, fake_kms: FakeCloudKms, ops: AppServices
) -> None:
    with pytest.raises(UserCommandError, match="no such user"):
        await kms_ops.rotate_user(ops, operator="a", user_id=uuid.uuid4(), reason="r")
    nobody = await world.person("nokey@example.com")
    with pytest.raises(UserCommandError, match="no key"):
        await kms_ops.rotate_user(ops, operator="a", user_id=_uid(nobody), reason="r")
    person = await _with_instructions(world, n=1)
    with pytest.raises(UserCommandError, match="--reason"):
        await kms_ops.rotate_user(ops, operator="a", user_id=_uid(person), reason="  ")
    world.db.execute(
        "UPDATE users SET status = 'pending_deletion', deletion_requested_at = now() WHERE id = %s",
        (person.user_id,),
    )
    with pytest.raises(UserCommandError, match="closed"):
        await kms_ops.rotate_user(ops, operator="a", user_id=_uid(person), reason="r")
    world.db.execute("UPDATE users SET status = 'active' WHERE id = %s", (person.user_id,))
    with world.db.transaction():
        world.db.execute(
            "SELECT 1 FROM checkin_configurations WHERE user_id = %s FOR UPDATE", (person.user_id,)
        )
        with pytest.raises(UserCommandError, match="busy"):
            await asyncio.wait_for(
                kms_ops.rotate_user(ops, operator="a", user_id=_uid(person), reason="r"), 5
            )


async def test_rotating_twice_moves_forward_by_one_each_time(
    world: World, fake_kms: FakeCloudKms, ops: AppServices
) -> None:
    person = await _with_instructions(world, n=2)
    for expected in (2, 3):
        result = await kms_ops.rotate_user(ops, operator="a", user_id=_uid(person), reason="again")
        assert result.to_version == expected
    assert {v for _, v in _blobs(world, person).values()} == {3}
    assert len(await _read_all(world, person)) == 2


async def test_nothing_secret_is_logged_or_printed_by_the_key_commands(
    world: World,
    fake_kms: FakeCloudKms,
    ops: AppServices,
    capsys: pytest.CaptureFixture[str],
    caplog: pytest.LogCaptureFixture,
) -> None:
    person = await _with_instructions(world, n=1)
    dek = world.h.app.state.services.vault._cache[_uid(person)].dek
    fake_kms.rotate()
    await kms_ops.rewrap(ops, operator="alice")
    await kms_ops.rotate_user(ops, operator="alice", user_id=_uid(person), reason="routine check")
    seen = capsys.readouterr().out + caplog.text + str(_key_row(world, person)["rotated_at"])
    assert dek.hex() not in seen
    assert KEY_NAME not in seen


# =========================================================================== the command line


@pytest.fixture
def kms_cli(
    world: World,
    ops: AppServices,
    fake_kms: FakeCloudKms,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> Any:
    monkeypatch.setattr(cli, "load_settings", lambda: world.h.settings)
    monkeypatch.setattr(cli, "configure_logging", lambda _settings: None)
    monkeypatch.setattr(cli, "build_services", lambda _settings, **_kw: ops)
    monkeypatch.setattr(cli, "build_kms", lambda _settings: ops.vault.kms)

    async def run(*argv: str) -> tuple[int, str]:
        capsys.readouterr()
        code = await cli.run(list(argv))
        return code, capsys.readouterr().out

    return run


async def test_kms_check_says_ok_and_proves_the_user_binding(
    kms_cli: Any, fake_kms: FakeCloudKms
) -> None:
    code, out = await kms_cli("kms", "check")
    assert code == 0
    assert out.startswith("ok: wrapped and unwrapped 32 random bytes")
    assert "current_version=True" in out
    assert KEY_NAME not in out
    # for the nil user, then the same ciphertext presented as another user (refused)
    ops_seen = [c.operation for c in fake_kms.calls]
    assert ops_seen == ["encrypt", "decrypt", "decrypt"]
    nil = "afterme/dek/v1|00000000-0000-0000-0000-000000000000|gcp:"
    import base64

    assert (
        base64.b64decode(fake_kms.calls[0].body["additionalAuthenticatedData"])
        .decode()
        .startswith(nil)
    )


@pytest.mark.parametrize(
    ("outage", "code"),
    [(403, "permission_denied"), (404, "not_found"), (503, "unavailable")],
)
async def test_kms_check_names_the_failure_by_code(
    kms_cli: Any, fake_kms: FakeCloudKms, outage: int, code: str
) -> None:
    fake_kms.outage(outage)
    exit_code, out = await kms_cli("kms", "check")
    assert exit_code == 1
    assert out.strip() == f"failed: code={code}"


async def test_kms_check_fails_a_kms_that_does_not_bind_the_user() -> None:
    class Careless:
        active_key_id = "careless"

        async def wrap(self, dek: bytes, *, user_id: uuid.UUID) -> tuple[bytes, str]:
            self.dek = dek
            return b"blob", "careless"

        async def unwrap(self, wrapped: bytes, *, user_id: uuid.UUID, key_id: str) -> bytes:
            return self.dek

        async def unwrap_status(self, wrapped: bytes, *, user_id: uuid.UUID, key_id: str) -> Any:
            from app.security.kms import Unwrapped

            return Unwrapped(self.dek, current=True)

    ok, said = await kms_ops.check(Careless())
    assert not ok
    assert said == "failed: code=aad_not_enforced"


async def test_the_rewrap_and_rotate_commands_and_their_exit_codes(
    world: World, kms_cli: Any, fake_kms: FakeCloudKms
) -> None:
    person = await _with_instructions(world, n=1)
    fake_kms.rotate()
    code, out = await kms_cli("kms", "rewrap", "--dry-run")
    assert code == 0
    report = json.loads(out)
    assert (report["would_rewrap"], report["rewrapped"], report["complete"]) == (1, 0, True)
    code, out = await kms_cli("--operator", "alice", "kms", "rewrap", "--limit", "1")
    assert code == 0
    assert json.loads(out)["rewrapped"] == 1

    code, out = await kms_cli("kms", "rotate-user", person.user_id, "--reason", "drill")
    assert code == 0
    assert out.strip() == "rotated: key version 1 -> 2; instructions re-encrypted: 1"
    code, out = await kms_cli("kms", "rotate-user", str(uuid.uuid4()), "--reason", "drill")
    assert (code, out.strip()) == (2, "refused: no such user")

    fake_kms.outage(503)
    code, out = await kms_cli("kms", "rewrap")
    assert code == 1  # a re-wrap has to decrypt to know: a KMS outage is 'run again later'
    assert json.loads(out)["failure_codes"] == {"unavailable": 1}
    fake_kms.recover()


def test_the_commands_parse() -> None:
    parser = cli._parser()
    assert parser.parse_args(["kms", "rewrap", "--dry-run", "--limit", "5"]).limit == 5
    with pytest.raises(SystemExit):
        parser.parse_args(["kms", "rotate-user", str(uuid.uuid4())])  # --reason is required
    with pytest.raises(SystemExit):
        cli._parse(["kms", "rewrap", "--limit", "0"])


# =========================================================================== K-1, K-2


@pytest.fixture
def kms_log() -> Any:
    import io
    import logging

    from app.core.logging import build_formatter

    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(build_formatter(json=True))
    root = logging.getLogger()
    previous = root.level
    root.addHandler(handler)
    root.setLevel(logging.DEBUG)

    def failures() -> list[tuple[str, str]]:
        found = []
        for line in stream.getvalue().splitlines():
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if record.get("event") == "kms.call_failed":
                found.append((record["operation"], record["failure"]))
        return found

    try:
        yield failures
    finally:
        root.removeHandler(handler)
        root.setLevel(previous)


async def test_a_persons_first_instruction_during_a_kms_outage_is_503_with_retry_after(
    world: World, fake_kms: FakeCloudKms, kms_log: Any
) -> None:
    """K-1: creating a person's FIRST key (onboarding step 7) meets the KMS answering 503: the
    person gets the same 503 + Retry-After as every other KMS path, not a 500, and no key row is
    left behind. One kms.call_failed line says so."""
    person = await world.person("first@example.com", premium=True)
    fake_kms.outage(503)
    response = await world.call(
        person,
        "POST",
        "/v1/instructions",
        json={"category": "home", "title": "First", "body": "text"},
    )
    assert response.status_code == 503, response.text
    assert response.headers["retry-after"] == "5"
    assert response.json()["code"] == "service_unavailable"
    assert fake_kms.count("encrypt") >= 1
    keys = world.db.execute(
        "SELECT count(*) AS n FROM user_keys WHERE user_id = %s", (person.user_id,)
    ).fetchone()
    assert keys is not None
    assert keys["n"] == 0
    assert kms_log() == [("encrypt", "unavailable")]

    fake_kms.recover()
    again = await world.call(
        person,
        "POST",
        "/v1/instructions",
        json={"category": "home", "title": "First", "body": "text"},
    )
    assert again.status_code == 201, again.text


async def test_a_key_wrapped_by_another_cryptokey_is_logged_and_unavailable(
    world: World, fake_kms: FakeCloudKms, kms_log: Any
) -> None:
    """K-2: a changed KMS_KEY_NAME (every stored key names the old CryptoKey) is refused
    without a call, and still logs kms.call_failed (unknown_key), exactly once per failure,
    so the KMS alert sees it."""
    person = await _with_instructions(world, email="moved@example.com", n=1)
    world.db.execute(
        "UPDATE user_keys SET kek_id = %s WHERE user_id = %s",
        ("gcp:projects/p/locations/l/keyRings/r/cryptoKeys/old", person.user_id),
    )
    world.h.app.state.services.vault.forget(_uid(person))
    calls = fake_kms.count()
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    listed = await world.h.client.get("/v1/instructions", headers=person.headers)
    assert listed.status_code == 503
    assert fake_kms.count() == calls  # never attempted
    assert kms_log() == [("decrypt", "unknown_key")]
