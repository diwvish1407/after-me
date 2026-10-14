"""The pure parts of the game-day harness (``scripts/gameday.py``): what it will and will not
work in, how it reads ``afterme-admin``, what it counts, and how it reports. The rehearsal
itself needs PostgreSQL and real processes; run it with ``make gameday``."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from scripts.gameday_support import procs
from scripts.gameday_support.checks import (
    close_to,
    count_differences,
    count_mismatches,
    duplicates,
    expected_shift,
    extract_json,
    format_excerpt,
    held_back,
    is_loopback_host,
    not_before_full_grace,
    parse_mail_file,
    pick_port,
    process_matches,
    reconcile_outbox,
    scrub,
    seconds_between,
    status_excerpt,
    valid_database_name,
)
from scripts.gameday_support.procs import Database, HarnessError, Secrets, process_env
from scripts.gameday_support.report import DEFECT, FAIL, OK, Report

pytestmark = pytest.mark.no_db

T0 = datetime(2026, 10, 12, 9, 0, tzinfo=UTC)


# --- which database the harness may drop ---------------------------------------------------


@pytest.mark.parametrize("name", ["afterme_gameday", "afterme_gameday_2", "afterme_gameday_x1"])
def test_the_throwaway_database_names_are_accepted(name: str) -> None:
    assert valid_database_name(name)
    assert Database(name=name).name == name


@pytest.mark.parametrize(
    "name",
    [
        "afterme_dev",
        "afterme_test",
        "afterme_it",
        "afterme_test_gd",
        "postgres",
        "template1",
        "",
        "afterme_gameday; DROP DATABASE afterme_dev",
        "afterme_gameday-2",
        "AFTERME_GAMEDAY",
        "afterme_gamedayxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    ],
)
def test_no_other_database_is_ever_accepted(name: str) -> None:
    assert not valid_database_name(name)
    with pytest.raises(HarnessError):
        Database(name=name)


# --- the environment of the processes ------------------------------------------------------


def test_the_processes_get_a_clean_environment_that_cannot_reach_the_dev_database(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("AFTERME_DATABASE_URL", "postgresql+psycopg://x@localhost/afterme_dev")
    monkeypatch.setenv("AFTERME_PROBE_TOKEN", "p" * 40)
    monkeypatch.setenv("AFTERME_APP_ENV", "dev")
    db = Database(name="afterme_gameday")
    keys = Secrets()
    env = process_env(db, keys, port=8010, mail_dir=tmp_path, probe_token=None)

    assert env["AFTERME_APP_ENV"] == "test"  # .env (and so afterme_dev) is never read
    for name in (
        "AFTERME_DATABASE_URL",
        "AFTERME_WORKER_DATABASE_URL",
        "AFTERME_MIGRATION_DATABASE_URL",
        "AFTERME_MAINTENANCE_DATABASE_URL",
    ):
        assert env[name].endswith("/afterme_gameday")
    assert "AFTERME_PROBE_TOKEN" not in env  # monitoring is off until it is configured
    assert env["AFTERME_TEST_SUPPORT_ENABLED"] == "true"
    assert env["AFTERME_TEST_SUPPORT_TOKEN"] == keys.test_token
    assert len(keys.test_token) >= 32
    assert env["AFTERME_TICK_SECONDS"] == "1"

    monitored = process_env(db, keys, port=8010, mail_dir=tmp_path, probe_token=keys.probe_token)
    assert monitored["AFTERME_PROBE_TOKEN"] == keys.probe_token


# --- reading the operator CLI --------------------------------------------------------------

STATUS = """{
  "now": "2026-10-12T09:00:00+00:00",
  "hold_active": true,
  "hold_reasons": [
    "ingestion"
  ],
  "worker_heartbeat_age_seconds": 12.5,
  "pages": [
    "hold active"
  ],
  "warnings": []
}
"""


def test_the_status_document_is_found_after_log_lines() -> None:
    logs = '{"event": "system.hold_entered", "reason": "operator"}\n{"event": "x", "pages": 1}\n'
    found = extract_json(logs + STATUS)
    assert found is not None
    assert found["hold_reasons"] == ["ingestion"]
    assert found["pages"] == ["hold active"]


def test_text_without_a_status_document_is_none() -> None:
    assert extract_json("Holds ended: 1\n") is None
    assert extract_json('{"event": "only a log line"}\n') is None
    assert extract_json("") is None


def test_the_excerpt_keeps_what_the_runbook_needs_and_rounds_ages() -> None:
    document = extract_json(STATUS)
    excerpt = status_excerpt(document)
    assert list(excerpt) == [
        "hold_active",
        "hold_reasons",
        "worker_heartbeat_age_seconds",
        "pages",
        "warnings",
    ]
    lines = format_excerpt(excerpt)
    assert lines[2] == "worker_heartbeat_age_seconds: 12"
    assert status_excerpt(None) == {}


# --- the arithmetic of the assertions ------------------------------------------------------


def test_the_shift_is_the_window_plus_the_buffer() -> None:
    assert expected_shift(T0, T0 + timedelta(minutes=22), 30) == timedelta(minutes=52)
    assert seconds_between(T0, T0 + timedelta(seconds=90)) == 90
    assert close_to(T0, T0 + timedelta(milliseconds=400), 1.0)
    assert not close_to(T0, T0 + timedelta(seconds=2), 1.0)


def test_repeated_keys_and_disagreeing_counts_are_found() -> None:
    assert duplicates(["a", "b", "a", "c", "b", "a"]) == ["a", "b"]
    assert duplicates(["a", "b"]) == []
    sent = {("mom@example.com", "contact_alert"): 1, ("u@example.com", "incident_missed"): 2}
    assert count_mismatches(sent, dict(sent)) == []
    twice = {**sent, ("mom@example.com", "contact_alert"): 2}
    [problem] = count_mismatches(sent, twice)
    assert "contact_alert to mom@example.com" in problem
    assert "outbox says 1" in problem
    assert "recording says 2" in problem
    never_left = {("u@example.com", "incident_missed"): 2}
    assert len(count_mismatches(sent, never_left)) == 1


def test_a_port_is_picked_from_the_first_free_one() -> None:
    busy = {8010, 8011}
    assert pick_port(8010, lambda p: p not in busy) == 8012
    with pytest.raises(RuntimeError):
        pick_port(8010, lambda _p: False, limit=3)


def test_secrets_are_scrubbed_from_what_is_printed() -> None:
    assert scrub("token=abc123 and abc123", ["abc123", ""]) == "token=<secret> and <secret>"


def test_a_console_mail_is_parsed_like_the_test_mail_endpoint_reads_it() -> None:
    raw = (
        "From: AfterMe <no-reply@afterme.invalid>\nTo: Mom@Example.com\n"
        "Subject: Please read\nX-Template: contact_alert\n\nBody text\n"
    )
    parsed = parse_mail_file(raw)
    assert parsed is not None
    assert (parsed["to"], parsed["template"], parsed["subject"]) == (
        "mom@example.com",
        "contact_alert",
        "Please read",
    )
    assert parse_mail_file("not a mail") is None


# --- the report ----------------------------------------------------------------------------


def test_a_failed_promise_is_a_defect_and_any_other_failure_is_a_failure() -> None:
    lines: list[str] = []
    report = Report(out=lines.append)
    report.check("T.1", "holds", True, expected="x", actual="x", promise="DOC §1")
    assert report.passed
    assert report.exit_code() == 0

    report.check("T.2", "promised", False, expected="a", actual="b", promise="DOC §2")
    report.check("T.3", "precondition", False, expected="c", actual="d")
    report.fail("T.4", "harness", "timed out")

    assert [r.status for r in report.rows] == [OK, DEFECT, FAIL, FAIL]
    assert report.counts() == (1, 2, 1)
    assert report.exit_code() == 1
    assert [r.ident for r in report.defects()] == ["T.2"]
    assert "DOC §2" in report.defect_list()
    assert any("FAIL" in line and "T.2" in line for line in lines)


def test_an_empty_report_is_not_a_pass() -> None:
    assert Report(out=lambda _s: None).exit_code() == 1


def test_the_table_lists_every_check_with_its_result() -> None:
    report = Report(out=lambda _s: None)
    report.check(
        "OPS-09.1", "something long " * 6, True, expected="e" * 50, actual="a", promise="P"
    )
    report.check("OPS-09.2", "short", False, expected="e", actual="a", promise="P")
    table = report.table()
    assert "OPS-09.1" in table
    assert "OPS-09.2" in table
    assert "PASS" in table
    assert DEFECT in table
    assert table.splitlines()[-1] == "1 PASS, 0 FAIL, 1 FAIL (defect)"


# --- assertions that must be able to fail ---------------------------------------------------

DUE = {"status": "queued"}


def test_held_back_passes_only_when_a_due_message_was_actually_held() -> None:
    assert held_back([DUE], 0, None, hold_open=True) == []


@pytest.mark.parametrize(
    ("due", "mails", "messaged_at", "hold_open", "fragment"),
    [
        ([], 0, None, True, "nothing was tested"),  # not yet due: vacuous, so a failure
        ([{"status": "sent"}], 0, None, True, "is sent"),  # it left
        ([DUE], 1, None, True, "mails were written"),  # a mail exists
        ([DUE], 0, T0, True, "contacts were messaged"),  # the incident says it was handed over
        ([DUE], 0, None, False, "no Hold is open"),
    ],
)
def test_held_back_fails_in_every_situation_where_a_message_got_through(
    due: list[dict[str, str]], mails: int, messaged_at: object, hold_open: bool, fragment: str
) -> None:
    problems = held_back(due, mails, messaged_at, hold_open=hold_open)
    assert any(fragment in p for p in problems), problems


def test_count_differences_sees_an_extra_a_missing_and_a_foreign_message() -> None:
    expected = {("b", "contact_alert"): 1, ("a", "contact_alert"): 1}
    assert count_differences(dict(expected), expected) == []
    extra = {**expected, ("a2", "contact_alert"): 1}  # a wrongful alert to somebody else
    twice = {**expected, ("b", "contact_alert"): 2}  # sent twice
    other = {**expected, ("b", "contact_all_clear"): 1}  # a different template
    missing = {("b", "contact_alert"): 1}  # never sent
    for actual in (extra, twice, other, missing):
        assert count_differences(actual, expected), actual


def test_reconcile_outbox_agrees_only_when_rows_and_mails_match_by_provider_id() -> None:
    sent = [("m1", "contact_alert", "mom@x.org"), ("m2", "incident_missed", "u@x.org")]
    files = [
        ("m1", "contact_alert", "mom@x.org"),
        ("m2", "incident_missed", "u@x.org"),
        ("m3", "signup_code", "u@x.org"),  # not an outbox template: ignored
    ]
    templates = {"contact_alert", "incident_missed"}
    assert reconcile_outbox(sent, files, templates, minimum=2) == []

    too_few = reconcile_outbox(sent, files, templates, minimum=5)
    assert any("only 2 sent rows" in p for p in too_few)
    never_written = reconcile_outbox(sent, files[1:], templates, minimum=2)
    assert any("no mail was written" in p for p in never_written)
    wrong_recipient = reconcile_outbox(
        sent, [("m1", "contact_alert", "other@x.org"), files[1]], templates, minimum=2
    )
    assert any("m1" in p for p in wrong_recipient)
    stray = reconcile_outbox(
        sent, [*files, ("m4", "contact_alert", "mom@x.org")], templates, minimum=2
    )
    assert any("no outbox row accounts for" in p for p in stray)
    shared = reconcile_outbox(
        [*sent, ("m1", "contact_alert", "mom@x.org")], files, templates, minimum=2
    )
    assert any("recorded by 2 rows" in p for p in shared)


def test_an_alert_before_the_full_grace_is_caught() -> None:
    anchor = T0
    ok = anchor + timedelta(minutes=60, seconds=300)
    assert not_before_full_grace(ok, anchor, grace_minutes=60, settle_seconds=300)
    early = anchor + timedelta(minutes=60)  # before the settle delay
    assert not not_before_full_grace(early, anchor, grace_minutes=60, settle_seconds=300)
    from_missed_deadline = anchor - timedelta(minutes=14) + timedelta(minutes=65)
    assert not not_before_full_grace(
        from_missed_deadline, anchor, grace_minutes=60, settle_seconds=300
    )


# --- what the harness may kill and drop ------------------------------------------------------


@pytest.mark.parametrize("host", ["localhost", "127.0.0.1", "::1", " LOCALHOST "])
def test_only_this_machine_is_a_database_host(host: str) -> None:
    assert is_loopback_host(host)


@pytest.mark.parametrize(
    "host",
    ["", "db.internal", "10.0.0.5", "staging.example.com", "0.0.0.0"],  # noqa: S104
)
def test_any_other_host_is_refused_before_a_drop_database_can_reach_it(host: str) -> None:
    assert not is_loopback_host(host)
    with pytest.raises(HarnessError):
        Database(name="afterme_gameday", host=host)


def test_a_process_matches_only_with_the_same_start_and_the_same_command_line() -> None:
    recorded = {"start": "Mon Oct 12 12:41:03 2026", "command": "python -m workers.engine"}
    assert process_matches(recorded, dict(recorded))
    assert not process_matches(recorded, {**recorded, "start": "Mon Oct 12 13:00:00 2026"})
    assert not process_matches(recorded, {**recorded, "command": "uvicorn app.main:app"})
    assert not process_matches({"start": "", "command": ""}, {"start": "", "command": ""})
    assert not process_matches({}, recorded)


def _sleeper() -> subprocess.Popen[bytes]:
    return subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(120)"], start_new_session=True
    )


def test_reaping_kills_only_a_process_whose_start_and_command_line_still_match(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(procs, "PIDDIR", tmp_path)
    dead_harness = {"pid": 999_999, "start": "Mon Jan  1 00:00:00 2001", "command": "gone"}
    ours, reused = _sleeper(), _sleeper()
    try:
        true_ours = procs.identity(ours.pid)
        true_reused = procs.identity(reused.pid)
        assert true_ours is not None
        assert true_reused is not None
        record = {
            "harness": dead_harness,
            "children": {
                str(ours.pid): true_ours,
                # the PID was reused by another process: the recorded command line differs
                str(reused.pid): {**true_reused, "command": "uvicorn app.main:app --port 8010"},
            },
        }
        (tmp_path / "111.json").write_text(json.dumps(record))

        reaped = procs.reap_stale()

        assert reaped == [ours.pid]
        assert ours.wait(timeout=5) == -signal.SIGKILL
        assert reused.poll() is None  # untouched
        assert not (tmp_path / "111.json").exists()
    finally:
        for proc in (ours, reused):
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=5)


def test_a_run_that_is_still_alive_is_refused_not_reaped(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(procs, "PIDDIR", tmp_path)
    me = procs.identity(os.getpid())
    assert me is not None
    # another run's record whose harness process is in fact alive (this one, standing in)
    other = {"harness": {"pid": os.getpid(), **me}, "children": {}}
    (tmp_path / "222.json").write_text(json.dumps(other))
    with pytest.raises(HarnessError, match="in progress"):
        procs.reap_stale()
    assert (tmp_path / "222.json").exists()
