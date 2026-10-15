"""The Google Play reviewer (demo) account (Phase 13; ``app/ops/reviewer.py``).

The command runs as the API role with the KMS (it seals the two samples), here against the fake
Cloud KMS that really encrypts, on the test clock. What matters:

* the account it makes is an ordinary one a reviewer can sign in to with email + password, with
  every screen reachable and nothing special about it for the API or the engine;
* ``reset`` restores it, twice in a row gives the same state, and it only ever touches an
  account that ``create`` made;
* refusals change nothing; a KMS outage leaves no half-made account;
* the password goes nowhere but the hash and, once, a terminal.
"""

from __future__ import annotations

import json
import logging
import re
import uuid
from collections.abc import AsyncIterator
from datetime import timedelta
from typing import Any

import httpx
import pytest

from app.api.container import AppServices, build_services
from app.core.config import Settings
from app.ops import reviewer
from app.ops.reviewer import ReviewerCommandError
from app.ops.users import UserCommandError
from app.security.gcp_kms import GcpKms
from cli import admin as cli
from tests.fake_cloud_kms import KEY_NAME, FakeCloudKms, StaticToken
from tests.support import bearer, make_settings
from tests.world import World

pytestmark = pytest.mark.settings()

LOGIN = "play-review@afterme.app"
INBOX = "review-inbox@afterme.app"
PASSWORD = "tqx7m-k2hpa-9vwzr-b4dne"  # the shape generate_password() makes
REASON = "Play submission 1.0.0"


@pytest.fixture
def fake_kms(monkeypatch: pytest.MonkeyPatch) -> FakeCloudKms:
    fake = FakeCloudKms()

    def build(_settings: Settings, *, client: httpx.AsyncClient | None = None) -> GcpKms:
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
    """What ``python -m cli.admin reviewer-account ...`` builds: its own container, the API
    role, the test clock."""
    services = build_services(world.h.settings, clock=world.clock, application_name="test-rev")
    yield services
    await services.db.dispose()


async def _create(ops: AppServices, **overrides: Any) -> reviewer.ReviewerAccount:
    values: dict[str, Any] = {
        "operator": "owner",
        "email": LOGIN,
        "contact_email": INBOX,
        "reason": REASON,
        "password": PASSWORD,
    }
    values.update(overrides)
    return await reviewer.create(ops, **values)


async def _reset(
    ops: AppServices, user_id: uuid.UUID, password: str = PASSWORD, **kw: Any
) -> reviewer.ReviewerAccount:
    return await reviewer.reset(
        ops, operator="owner", user_id=user_id, reason="before review", password=password, **kw
    )


async def _sign_in(world: World, password: str = PASSWORD) -> dict[str, Any]:
    response = await world.h.login(LOGIN, password)
    assert response.status_code == 200, response.text
    tokens: dict[str, Any] = response.json()
    return tokens


async def _get(world: World, tokens: dict[str, Any], path: str) -> Any:
    response = await world.h.client.get(path, headers=bearer(tokens))
    assert response.status_code == 200, (path, response.text)
    return response.json()


async def _seen_by_the_reviewer(world: World, password: str = PASSWORD) -> dict[str, Any]:
    """Every screen a reviewer opens, through the real API."""
    tokens = await _sign_in(world, password)
    seen = {
        "home": await _get(world, tokens, "/v1/home"),
        "me": await _get(world, tokens, "/v1/me"),
        "entitlements": await _get(world, tokens, "/v1/me/entitlements"),
        "contacts": await _get(world, tokens, "/v1/contacts"),
        "plan": await _get(world, tokens, "/v1/plan"),
        "schedule": await _get(world, tokens, "/v1/checkin/schedule"),
    }
    reauth = await world.h.client.post(
        "/v1/auth/reauth", json={"password": password}, headers=bearer(tokens)
    )
    assert reauth.status_code == 204, reauth.text
    seen["instructions"] = await _get(world, tokens, "/v1/instructions")
    seen["tokens"] = tokens
    return seen


def _assert_seeded(seen: dict[str, Any]) -> None:
    assert seen["entitlements"]["tier"] == "premium"
    contacts = seen["contacts"]["items"]
    assert len(contacts) == 1
    assert contacts[0]["display_name"] == reviewer.CONTACT_NAME
    assert contacts[0]["email"] == INBOX
    assert contacts[0]["verification_status"] == "verified"
    stages = seen["plan"]["stages"]
    assert [s["offset_minutes"] for s in stages] == [180, 1440]
    assert all(s["notify_contact_ids"] == [contacts[0]["id"]] for s in stages)
    assert seen["plan"]["grace_minutes"] == 180
    assert seen["schedule"]["status"] == "active"
    assert seen["schedule"]["interval_days"] == 1
    assert seen["schedule"]["due_local_time"] == "20:00"
    assert seen["schedule"]["timezone"] == "Asia/Kolkata"
    titles = sorted(i["title"] for i in seen["instructions"]["items"])
    assert titles == sorted(t for _, t, _ in reviewer.SAMPLES)
    for item in seen["instructions"]["items"]:
        assert [r["release_stage_id"] for r in item["recipients"]] == [stages[1]["id"]]


def _audit(world: World) -> list[dict[str, Any]]:
    return [
        dict(r)
        for r in world.db.execute(
            "SELECT * FROM audit_logs WHERE action = 'operator.reviewer_account' ORDER BY id"
        ).fetchall()
    ]


def _count(world: World, query: str, *params: Any) -> int:
    row = world.db.execute(query, params).fetchone()
    assert row is not None
    return int(row["n"])


# =========================================================================== create


async def test_create_makes_an_ordinary_verified_premium_account_a_reviewer_can_use(
    world: World, ops: AppServices
) -> None:
    made = await _create(ops)
    assert made.email == LOGIN
    seen = await _seen_by_the_reviewer(world)
    _assert_seeded(seen)
    assert seen["me"]["profile"]["display_name"] == reviewer.REVIEWER_NAME
    # the samples are sealed with the account's key like any instruction: no plaintext stored
    blobs = world.db.execute(
        "SELECT content_ciphertext FROM instructions WHERE user_id = %s", (made.user_id,)
    ).fetchall()
    assert len(blobs) == 2
    for row in blobs:
        assert b"sample" not in bytes(row["content_ciphertext"])
    # nothing was sent to anyone: no invitation, no code (the contact is our own inbox)
    assert world.mail.to(INBOX) == []
    assert world.mail.to(LOGIN, "signup_code") == []

    audit = _audit(world)
    assert len(audit) == 1
    row = audit[0]
    assert row["actor_type"] == "operator"
    assert row["user_visible"] is False
    assert row["subject_user_id"] == made.user_id
    assert row["metadata"]["command"] == "create"
    assert row["metadata"]["operator_note"] == REASON
    assert (row["metadata"]["contacts"], row["metadata"]["instructions"]) == (1, 2)
    assert PASSWORD not in json.dumps(row["metadata"])
    assert LOGIN not in json.dumps(row["metadata"])
    assert INBOX not in json.dumps(row["metadata"])
    # and the reviewer's own Activity feed shows nothing of the operator's work
    activity = await _get(world, seen["tokens"], "/v1/activity")
    assert "reviewer" not in json.dumps(activity)


async def test_the_engine_treats_the_reviewer_account_like_any_other(
    world: World, ops: AppServices
) -> None:
    made = await _create(ops)
    due = world.db.execute(
        "SELECT next_due_at FROM checkin_configurations WHERE user_id = %s", (made.user_id,)
    ).fetchone()
    assert due is not None
    # nobody checks in: the incident opens at the deadline, our inbox is told after the grace
    # period, and the samples are shared with it after 24 hours, exactly as for a person
    await world.advance_to(due["next_due_at"] + timedelta(minutes=180 + 6))
    incident = world.db.execute(
        "SELECT * FROM escalation_incidents WHERE user_id = %s", (made.user_id,)
    ).fetchone()
    assert incident is not None
    alerts = [m for m in world.mail.to(INBOX) if m.template.startswith("contact_alert")]
    assert len(alerts) == 1
    for _, title, body in reviewer.SAMPLES:
        assert title not in alerts[0].text
        assert body not in alerts[0].text
    await world.advance_to(due["next_due_at"] + timedelta(minutes=1440 + 6))
    released = world.mail.to(INBOX, "contact_release")
    assert len(released) == 1
    assert "/c/release#rt_" in released[0].text
    for _, title, body in reviewer.SAMPLES:
        assert title not in released[0].text
        assert body not in released[0].text


# =========================================================================== reset


async def test_reset_restores_the_seeded_state_and_is_idempotent(
    world: World, ops: AppServices
) -> None:
    made = await _create(ops)
    seen = await _seen_by_the_reviewer(world)
    tokens = seen["tokens"]
    headers = bearer(tokens)
    # the reviewer wanders: deletes a sample, adds a contact, switches check-ins off
    first = seen["instructions"]["items"][0]["id"]
    assert (
        await world.h.client.delete(f"/v1/instructions/{first}", headers=headers)
    ).status_code == 204
    added = await world.h.client.post(
        "/v1/contacts",
        json={"display_name": "Someone", "relationship": "friend", "email": "x@example.com"},
        headers=headers,
    )
    assert added.status_code == 201, added.text
    off = await world.h.client.post("/v1/checkin/deactivate", headers=headers)
    assert off.status_code == 200, off.text

    new_password = reviewer.generate_password()
    done = await _reset(ops, made.user_id, new_password)
    assert (done.contacts_removed, done.instructions_replaced) == (1, 1)
    assert done.sessions_revoked >= 1
    # the old password and the old session are gone
    assert (await world.h.login(LOGIN, PASSWORD)).status_code == 401
    refreshed = await world.h.refresh(tokens["refresh_token"])
    assert refreshed.status_code == 401
    _assert_seeded(await _seen_by_the_reviewer(world, new_password))

    # twice in a row: the same state
    again = await _reset(ops, made.user_id, new_password)
    assert (again.contacts_removed, again.instructions_replaced) == (0, 2)
    _assert_seeded(await _seen_by_the_reviewer(world, new_password))
    assert (
        _count(
            world,
            "SELECT count(*) AS n FROM instructions WHERE user_id = %s AND deleted_at IS NULL",
            made.user_id,
        )
        == 2
    )
    assert (
        _count(
            world,
            "SELECT count(*) AS n FROM escalation_steps WHERE user_id = %s",
            made.user_id,
        )
        == 2
    )
    assert [r["metadata"]["command"] for r in _audit(world)] == ["create", "reset", "reset"]


async def test_reset_keeps_the_inbox_contact_row_and_takes_the_contact_from_the_account(
    world: World, ops: AppServices
) -> None:
    made = await _create(ops)
    await _reset(ops, made.user_id)
    rows = world.db.execute(
        "SELECT id, deleted_at FROM trusted_contacts WHERE user_id = %s", (made.user_id,)
    ).fetchall()
    assert [r["id"] for r in rows] == [made.contact_id]
    assert rows[0]["deleted_at"] is None


# =========================================================================== refusals


@pytest.mark.parametrize(
    ("overrides", "message"),
    [
        ({"contact_email": "someone@gmail.com"}, "public mail provider"),
        ({"contact_email": LOGIN}, "different inbox"),
        ({"contact_email": "not an address"}, "--contact-email is not a valid"),
        ({"email": "nope"}, "--email is not a valid"),
        ({"password": "short"}, "policy (too_short)"),
        ({"password": "password1234"}, "policy (password_too_common)"),
        ({"reason": "   "}, "--reason"),
    ],
)
async def test_create_refuses_and_changes_nothing(
    world: World, ops: AppServices, overrides: dict[str, Any], message: str
) -> None:
    # UserCommandError: the parent of ReviewerCommandError (the --reason check is shared)
    with pytest.raises(UserCommandError, match=re.escape(message)):
        await _create(ops, **overrides)
    assert _count(world, "SELECT count(*) AS n FROM users") == 0
    assert _audit(world) == []


async def test_a_public_contact_needs_the_explicit_flag(world: World, ops: AppServices) -> None:
    made = await _create(ops, contact_email="our.review.inbox@gmail.com", allow_public_contact=True)
    # reset reads the inbox from the account, and asks for the flag again
    with pytest.raises(ReviewerCommandError, match="public mail provider"):
        await _reset(ops, made.user_id)
    await _reset(ops, made.user_id, allow_public_contact=True)


async def test_create_never_takes_over_an_existing_account(world: World, ops: AppServices) -> None:
    person = await world.person(LOGIN)
    before = world.db.execute("SELECT * FROM users WHERE id = %s", (person.user_id,)).fetchone()
    with pytest.raises(ReviewerCommandError, match="already exists"):
        await _create(ops)
    after = world.db.execute("SELECT * FROM users WHERE id = %s", (person.user_id,)).fetchone()
    assert before == after
    assert _audit(world) == []


async def test_reset_only_touches_an_account_that_create_made(
    world: World, ops: AppServices
) -> None:
    person = await world.person("real.person@example.com")
    before = world.db.execute("SELECT * FROM users WHERE id = %s", (person.user_id,)).fetchone()
    with pytest.raises(ReviewerCommandError, match="not made by"):
        await _reset(ops, uuid.UUID(person.user_id), contact_email=INBOX)
    assert (
        world.db.execute("SELECT * FROM users WHERE id = %s", (person.user_id,)).fetchone()
        == before
    )
    with pytest.raises(ReviewerCommandError, match="no such user"):
        await _reset(ops, uuid.uuid4())


async def test_reset_refuses_an_open_incident_and_a_closed_account(
    world: World, ops: AppServices
) -> None:
    made = await _create(ops)
    due = world.db.execute(
        "SELECT next_due_at FROM checkin_configurations WHERE user_id = %s", (made.user_id,)
    ).fetchone()
    assert due is not None
    await world.advance_to(due["next_due_at"] + timedelta(minutes=1))
    incident = world.db.execute(
        "SELECT id FROM escalation_incidents WHERE user_id = %s", (made.user_id,)
    ).fetchone()
    assert incident is not None
    hash_before = world.db.execute(
        "SELECT password_hash FROM users WHERE id = %s", (made.user_id,)
    ).fetchone()
    with pytest.raises(ReviewerCommandError, match=f"incident void {incident['id']}"):
        await _reset(ops, made.user_id)
    assert (
        world.db.execute(
            "SELECT password_hash FROM users WHERE id = %s", (made.user_id,)
        ).fetchone()
        == hash_before
    )

    world.db.execute(
        "UPDATE users SET status = 'pending_deletion', deletion_requested_at = now() WHERE id = %s",
        (made.user_id,),
    )
    with pytest.raises(ReviewerCommandError, match="pending_deletion"):
        await _reset(ops, made.user_id)


async def test_a_suppressed_inbox_is_never_marked_verified(world: World, ops: AppServices) -> None:
    from app.contacts.tokens import suppression_hash

    world.db.execute(
        "INSERT INTO email_suppressions (email_hash, reason) VALUES (%s, 'contact_block_all')",
        (suppression_hash(ops.pepper, INBOX),),
    )
    with pytest.raises(ReviewerCommandError, match="suppression list"):
        await _create(ops)
    assert _count(world, "SELECT count(*) AS n FROM users") == 0


async def test_an_opted_out_inbox_contact_is_not_overridden_by_reset(
    world: World, ops: AppServices
) -> None:
    made = await _create(ops)
    world.db.execute(
        "UPDATE trusted_contacts SET verification_status = 'opted_out' WHERE id = %s",
        (made.contact_id,),
    )
    with pytest.raises(ReviewerCommandError, match="opted_out"):
        await _reset(ops, made.user_id, contact_email=INBOX)


async def test_reset_of_a_busy_account_is_refused_and_never_waits(
    world: World, ops: AppServices
) -> None:
    import asyncio

    made = await _create(ops)
    with world.db.transaction():
        world.db.execute(
            "SELECT 1 FROM checkin_configurations WHERE user_id = %s FOR UPDATE", (made.user_id,)
        )
        with pytest.raises(ReviewerCommandError, match="busy"):
            await asyncio.wait_for(_reset(ops, made.user_id), 5)


# =========================================================================== the KMS


async def test_a_kms_outage_leaves_no_half_made_account(
    world: World, ops: AppServices, fake_kms: FakeCloudKms
) -> None:
    fake_kms.outage(503)
    with pytest.raises(ReviewerCommandError, match="KMS is unavailable; nothing was created"):
        await _create(ops)
    for table in ("users", "user_keys", "trusted_contacts", "instructions", "audit_logs"):
        assert _count(world, f"SELECT count(*) AS n FROM {table}") == 0, table  # noqa: S608
    fake_kms.recover()
    await _create(ops)
    _assert_seeded(await _seen_by_the_reviewer(world))


async def test_a_kms_outage_during_reset_changes_nothing(
    world: World, ops: AppServices, fake_kms: FakeCloudKms
) -> None:
    made = await _create(ops)
    ops.vault.forget(made.user_id)
    before = world.db.execute(
        "SELECT u.password_hash, (SELECT count(*) FROM instructions i WHERE i.user_id = u.id "
        "AND i.deleted_at IS NULL) AS live FROM users u WHERE u.id = %s",
        (made.user_id,),
    ).fetchone()
    fake_kms.outage(503)
    with pytest.raises(ReviewerCommandError, match="KMS is unavailable; nothing was changed"):
        await _reset(ops, made.user_id, reviewer.generate_password())
    after = world.db.execute(
        "SELECT u.password_hash, (SELECT count(*) FROM instructions i WHERE i.user_id = u.id "
        "AND i.deleted_at IS NULL) AS live FROM users u WHERE u.id = %s",
        (made.user_id,),
    ).fetchone()
    assert before == after
    assert [r["metadata"]["command"] for r in _audit(world)] == ["create"]


# =========================================================================== the command line


@pytest.fixture
def reviewer_cli(
    world: World,
    ops: AppServices,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> Any:
    monkeypatch.setattr(cli, "load_settings", lambda: world.h.settings)
    monkeypatch.setattr(cli, "configure_logging", lambda _settings: None)
    monkeypatch.setattr(cli, "build_services", lambda _settings, **_kw: ops)

    async def run(*argv: str, terminal: bool = True) -> tuple[int, str]:
        monkeypatch.setattr(cli, "_stdout_is_terminal", lambda: terminal)
        capsys.readouterr()
        code = await cli.run(list(argv))
        return code, capsys.readouterr().out

    return run


def _printed_password(out: str) -> str:
    line = next(x for x in out.splitlines() if x.startswith("password (shown once"))
    return line.rsplit(": ", 1)[1]


async def test_the_command_prints_a_generated_password_once_and_never_logs_it(
    world: World, reviewer_cli: Any, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.DEBUG)
    code, out = await reviewer_cli(
        "--operator",
        "owner",
        "reviewer-account",
        "create",
        "--email",
        LOGIN,
        "--contact-email",
        INBOX,
        "--reason",
        REASON,
    )
    assert code == 0, out
    password = _printed_password(out)
    assert len(password) == 23
    assert out.count(password) == 1
    assert out.startswith("created: user_id=")
    assert password not in caplog.text
    hashed = world.db.execute("SELECT password_hash FROM users").fetchone()
    assert hashed is not None
    assert password not in hashed["password_hash"]
    assert hashed["password_hash"] not in out + caplog.text
    assert password not in json.dumps([r["metadata"] for r in _audit(world)])
    await _seen_by_the_reviewer(world, password)  # and it works

    user_id = str(world.db.execute("SELECT id FROM users").fetchone()["id"])  # type: ignore[index]
    code, out = await reviewer_cli("reviewer-account", "reset", user_id)
    assert code == 0, out
    second = _printed_password(out)
    assert second != password
    assert second not in caplog.text
    assert "sessions ended: 1" in out
    assert (await world.h.login(LOGIN, password)).status_code == 401
    await _seen_by_the_reviewer(world, second)


async def test_without_a_terminal_the_password_comes_from_a_secret_or_nothing_happens(
    world: World,
    reviewer_cli: Any,
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
) -> None:
    caplog.set_level(logging.DEBUG)
    argv = ("reviewer-account", "create", "--email", LOGIN, "--contact-email", INBOX)
    code, out = await reviewer_cli(*argv, "--reason", REASON, terminal=False)
    assert code == 2
    assert out.startswith("refused: stdout is not a terminal")
    assert _count(world, "SELECT count(*) AS n FROM users") == 0

    code, out = await reviewer_cli(
        *argv, "--reason", REASON, "--password-env", "REVIEWER_PW", terminal=False
    )
    assert (code, out.strip()) == (
        2,
        "refused: the environment variable REVIEWER_PW is unset or empty",
    )

    monkeypatch.setenv("REVIEWER_PW", PASSWORD)
    code, out = await reviewer_cli(
        *argv, "--reason", REASON, "--password-env", "REVIEWER_PW", terminal=False
    )
    assert code == 0, out
    assert PASSWORD not in out
    assert PASSWORD not in caplog.text
    assert "password: from REVIEWER_PW (not printed)" in out
    await _seen_by_the_reviewer(world, PASSWORD)


async def test_the_command_refuses_with_exit_2(world: World, reviewer_cli: Any) -> None:
    code, out = await reviewer_cli(
        "reviewer-account",
        "create",
        "--email",
        LOGIN,
        "--contact-email",
        "stranger@gmail.com",
        "--reason",
        REASON,
    )
    assert code == 2
    assert out.startswith("refused: --contact-email is on a public mail provider")
    assert "stranger" not in out  # the address is never repeated back
    code, out = await reviewer_cli("reviewer-account", "reset", str(uuid.uuid4()))
    assert (code, out.strip()) == (2, "refused: no such user")


def test_the_commands_parse() -> None:
    parser = cli._parser()
    with pytest.raises(SystemExit):  # --contact-email is required for create
        parser.parse_args(["reviewer-account", "create", "--email", LOGIN, "--reason", "r"])
    with pytest.raises(SystemExit):  # --reason is required for create
        parser.parse_args(
            ["reviewer-account", "create", "--email", LOGIN, "--contact-email", INBOX]
        )
    with pytest.raises(SystemExit):  # an env NAME, not a value
        cli._parse(["reviewer-account", "reset", str(uuid.uuid4()), "--password-env", "hunter2 x"])
    args = parser.parse_args(["reviewer-account", "reset", str(uuid.uuid4())])
    assert args.reason
    assert args.contact_email is None


def test_generated_passwords_meet_the_policy_and_differ() -> None:
    from app.security.passwords import check_password_policy

    made = {reviewer.generate_password() for _ in range(50)}
    assert len(made) == 50
    for password in made:
        check_password_policy(password, email=LOGIN)
        assert len(password) == 23
