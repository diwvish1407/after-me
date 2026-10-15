"""``python -m cli.admin``: the operator's command line (``afterme-admin``).

    python -m cli.admin status
    python -m cli.admin hold status | enter --reason "..." | exit [--include-ingestion]
    python -m cli.admin incident void <incident-id>
    python -m cli.admin action retry <action-id>
    python -m cli.admin user set-tier <user-id> free|premium --reason "..."  # users.tier only
    python -m cli.admin user suspend <user-id> --reason "..."    # suspended; every session revoked
    python -m cli.admin user unsuspend <user-id> --reason "..."  # suspended back to active
    python -m cli.admin kms check                  # wrap/unwrap 32 random bytes with the real KMS
    python -m cli.admin kms rewrap [--dry-run] [--limit N]   # wrapped keys -> the primary version
    python -m cli.admin kms rotate-user <user-id> --reason "..."   # a new DEK for one account
    python -m cli.admin email-test --to ADDRESS     # one message through the configured chain
    python -m cli.admin push-test --token TOKEN     # one push through the configured provider
    python -m cli.admin beta-report [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--json]
    python -m cli.admin reviewer-account create --email ADDR --contact-email INBOX --reason "..."
    python -m cli.admin reviewer-account reset <user-id> [--contact-email INBOX]
        # both: [--allow-public-contact] [--password-env NAME]

Connects as the worker role; every command that changes something is audited with an operator
actor. ``status``, ``hold status`` and ``beta-report`` only read, and are not.

The ``kms`` commands are the exception: they connect as the **API role** (``DATABASE_URL``),
because only that role may read keys and content, and use the configured KMS identity (run them
where the API's service account is, e.g. a Cloud Run job of the API image). ``kms check`` needs
no database. See ``app/ops/kms.py`` for what is safe to interrupt and re-run.

``reviewer-account`` runs the same way (API role + KMS: it seals the two sample instructions).
It makes or restores the Google Play reviewer's demo account (``app/ops/reviewer.py``). The
password is generated and printed once **only to a terminal**; where stdout is a log (Cloud Run,
CI, a pipe) it is refused unless ``--password-env NAME`` names an environment variable that holds
it (a secret). The password is never logged and never in the audit record.

``beta-report`` is the closed-beta review: metrics for the period, then every incident in which
a contact was messaged, with deterministic verdict hints. It is read-only (a READ ONLY
transaction) and carries UUIDs, counts, template keys, statuses and times, never a name, an
address, a token or instruction text. Dates are UTC days, both ends inclusive. Exit status 0;
2 (nothing printed on stdout) for a bad period, or a database that is not migrated to this
code's head or lacks a table.
"""

from __future__ import annotations

import argparse
import asyncio
import getpass
import json
import os
import re
import sys
import uuid
from datetime import date

from app.api.container import AppServices, build_kms, build_services, build_worker_services
from app.auth.models import USER_TIERS
from app.core.config import load_settings
from app.core.logging import configure_logging
from app.notifications.email import EmailMessage
from app.notifications.errors import ProviderError
from app.notifications.providers.factory import build_email_provider, build_push_provider
from app.notifications.push import PushMessage
from app.ops import admin, beta, reviewer, users
from app.ops import kms as kms_ops

_DAY_RE = re.compile(r"\d{4}-\d{2}-\d{2}")
_ENV_NAME_RE = re.compile(r"[A-Z_][A-Z0-9_]{0,63}")


def _day(value: str) -> date:
    """``YYYY-MM-DD`` only: ``20261001`` and ISO week dates are parsed by ``fromisoformat`` too,
    and an operator who typed one of those probably meant something else."""
    if _DAY_RE.fullmatch(value):
        try:
            return date.fromisoformat(value)
        except ValueError:
            pass
    msg = f"not a date (YYYY-MM-DD): {value!r}"
    raise argparse.ArgumentTypeError(msg)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="afterme-admin")
    parser.add_argument("--operator", default=None, help="who is running this (default: OS user)")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status", help="engine health and the alerts that would page")
    hold = sub.add_parser("hold", help="the system circuit breaker")
    hold_sub = hold.add_subparsers(dest="hold_command", required=True)
    hold_sub.add_parser("status")
    enter = hold_sub.add_parser("enter")
    enter.add_argument("--reason", required=True)
    leave = hold_sub.add_parser("exit")
    leave.add_argument("--include-ingestion", action="store_true")
    incident = sub.add_parser("incident")
    incident_sub = incident.add_subparsers(dest="incident_command", required=True)
    void = incident_sub.add_parser("void")
    void.add_argument("incident_id", type=uuid.UUID)
    action = sub.add_parser("action", help="a held timeline action")
    action_sub = action.add_subparsers(dest="action_command", required=True)
    retry = action_sub.add_parser("retry", help="put a held action back to pending")
    retry.add_argument("action_id", type=uuid.UUID)
    user = sub.add_parser("user", help="one account: its tier and its suspension")
    user_sub = user.add_subparsers(dest="user_command", required=True)
    set_tier = user_sub.add_parser("set-tier", help="change users.tier and nothing else")
    set_tier.add_argument("user_id", type=uuid.UUID)
    set_tier.add_argument("tier", choices=USER_TIERS)
    set_tier.add_argument("--reason", required=True, help="why (kept in the audit record)")
    for name, text in (
        ("suspend", "suspend the account and end every session; voids and sends nothing"),
        ("unsuspend", "suspended back to active"),
    ):
        one = user_sub.add_parser(name, help=text)
        one.add_argument("user_id", type=uuid.UUID)
        one.add_argument("--reason", required=True, help="why (kept in the audit record)")
    kms = sub.add_parser("kms", help="key management: check, re-wrap, rotate one user's key")
    kms_sub = kms.add_subparsers(dest="kms_command", required=True)
    kms_sub.add_parser("check", help="prove the configured KMS wraps and unwraps (no database)")
    rewrap = kms_sub.add_parser(
        "rewrap", help="rewrite every wrapped key under the KMS's current key version"
    )
    rewrap.add_argument(
        "--dry-run", action="store_true", help="count what would change; write nothing"
    )
    rewrap.add_argument(
        "--limit", type=int, default=None, metavar="N", help="rewrite at most N keys this run"
    )
    rotate = kms_sub.add_parser(
        "rotate-user", help="a new data key for one account; its instructions are re-encrypted"
    )
    rotate.add_argument("user_id", type=uuid.UUID)
    rotate.add_argument("--reason", required=True, help="why (kept in the audit record)")
    email = sub.add_parser(
        "email-test", help="send one test message through the configured email provider(s)"
    )
    email.add_argument("--to", required=True)
    push = sub.add_parser("push-test", help="send one test push through the configured provider")
    push.add_argument("--token", required=True, help="an FCM registration token")
    report = sub.add_parser(
        "beta-report",
        help="closed-beta metrics and every escalated incident, for review (read-only)",
    )
    report.add_argument(
        "--since", type=_day, metavar="YYYY-MM-DD", help="first UTC day (default: the beginning)"
    )
    report.add_argument(
        "--until", type=_day, metavar="YYYY-MM-DD", help="last UTC day, inclusive (default: now)"
    )
    report.add_argument("--json", action="store_true", help="a machine-readable document")
    reviewer_parser = sub.add_parser(
        "reviewer-account",
        help="the Google Play reviewer (demo) account: create or reset (API role + KMS)",
    )
    reviewer_sub = reviewer_parser.add_subparsers(dest="reviewer_command", required=True)
    make = reviewer_sub.add_parser(
        "create", help="a verified Premium account with our inbox as its one contact"
    )
    make.add_argument("--email", required=True, help="the reviewer's login address (ours)")
    make.add_argument(
        "--contact-email", required=True, help="OUR inbox: the account's one verified contact"
    )
    make.add_argument("--reason", required=True, help="why (kept in the audit record)")
    again = reviewer_sub.add_parser(
        "reset", help="a new password, no session, and the seeded state back"
    )
    again.add_argument("user_id", type=uuid.UUID)
    again.add_argument(
        "--contact-email",
        default=None,
        help="OUR inbox (default: the account's one verified contact)",
    )
    again.add_argument(
        "--reason",
        default="reset of the Play reviewer account",
        help="why (kept in the audit record)",
    )
    for one in (make, again):
        one.add_argument(
            "--allow-public-contact",
            action="store_true",
            help="accept a contact address on a public mail provider (it must still be ours)",
        )
        one.add_argument(
            "--password-env",
            default=None,
            metavar="NAME",
            help="read the password from this environment variable (a secret) instead of "
            "generating one and printing it once (required when stdout is not a terminal)",
        )
    return parser


def _parse(argv: list[str]) -> argparse.Namespace:
    parser = _parser()
    args = parser.parse_args(argv)
    if args.command == "beta-report" and args.since and args.until and args.since > args.until:
        parser.error("--since is after --until")
    if (
        args.command == "kms"
        and args.kms_command == "rewrap"
        and (args.limit is not None and args.limit < 1)
    ):
        parser.error("--limit must be at least 1")
    if (
        args.command == "reviewer-account"
        and args.password_env is not None
        and not _ENV_NAME_RE.fullmatch(args.password_env)
    ):
        parser.error("--password-env takes the NAME of an environment variable")
    return args


async def _provider_test(args: argparse.Namespace) -> int:
    """Prove a provider configuration end to end (DNS, keys, project) without touching the
    database or any account. Prints what happened by *kind*; secrets and addresses never go to
    the log, only to the terminal that asked."""
    settings = load_settings()
    key = f"admin-test-{uuid.uuid4().hex[:12]}"
    try:
        if args.command == "email-test":
            provider = build_email_provider(settings)
            text = "This is a test message from AfterMe's operator tool. Nothing needs doing.\n"
            result = await provider.send(
                EmailMessage(
                    to=args.to,
                    subject="AfterMe test message",
                    text=text,
                    template="operator_test",
                    sender=settings.email_from,
                    html=None,
                ),
                idempotency_key=key,
            )
        else:
            result = await build_push_provider(settings).send(
                PushMessage(
                    token=args.token,
                    type="operator_test",
                    title="AfterMe test",
                    body="This is a test from the operator tool.",
                ),
                idempotency_key=key,
            )
    except ProviderError as exc:
        print(f"failed: {type(exc).__name__} code={exc.code}")  # noqa: T201
        return 1
    except Exception as exc:
        print(f"failed: {type(exc).__name__}")  # noqa: T201
        return 1
    print(f"ok: provider={result.provider} message_id={result.message_id}")  # noqa: T201
    return 0


async def _user_command(args: argparse.Namespace, services: AppServices, operator: str) -> int:
    """``user set-tier | suspend | unsuspend``. Exit ``0`` when the account is as asked (also
    when it already was), ``2`` when the command was refused."""
    try:
        if args.user_command == "set-tier":
            change = await users.set_tier(
                services,
                operator=operator,
                user_id=args.user_id,
                tier=args.tier,
                reason=args.reason,
            )
        elif args.user_command == "suspend":
            change = await users.suspend(
                services, operator=operator, user_id=args.user_id, reason=args.reason
            )
        else:
            change = await users.unsuspend(
                services, operator=operator, user_id=args.user_id, reason=args.reason
            )
    except users.UserCommandError as exc:
        print(f"refused: {exc}")  # noqa: T201
        return 2
    if change.command == "set_tier":
        said = (
            f"tier set: {change.before} -> {change.after}"
            if change.changed
            else f"tier is already {change.after}; nothing changed"
        )
    elif change.command == "suspend":
        said = (
            f"suspended (was {change.before}); sessions revoked: {change.sessions_revoked}"
            if change.changed
            else "already suspended and no session was open; nothing changed"
        )
    else:
        said = (
            "unsuspended: the account is active again (the person signs in again)"
            if change.changed
            else f"the account is not suspended (status {change.before}); nothing changed"
        )
    print(said)  # noqa: T201
    for note in change.notes:
        print(f"note: {note}")  # noqa: T201
    return 0


async def _kms_command(args: argparse.Namespace, operator: str) -> int:
    """``kms check | rewrap | rotate-user``. Exit ``0`` when done, ``1`` when something is left
    for a rerun (busy users, a failing KMS), ``2`` when refused."""
    settings = load_settings()
    configure_logging(settings)
    if args.kms_command == "check":
        ok, said = await kms_ops.check(build_kms(settings))
        print(said)  # noqa: T201
        return 0 if ok else 1
    services = build_services(settings, application_name="afterme-admin-kms")
    try:
        if settings.is_production_like:
            role = await services.db.current_role()
            if role != "afterme_api":
                print(f"refused: the kms commands must connect as afterme_api, not {role}")  # noqa: T201
                return 2
        if args.kms_command == "rewrap":
            report = await kms_ops.rewrap(
                services, operator=operator, dry_run=args.dry_run, limit=args.limit
            )
            print(json.dumps(report.as_dict(), indent=2))  # noqa: T201
            return 0 if report.complete or report.stopped_by_limit else 1
        try:
            rotation = await kms_ops.rotate_user(
                services, operator=operator, user_id=args.user_id, reason=args.reason
            )
        except users.UserCommandError as exc:
            print(f"refused: {exc}")  # noqa: T201
            return 2
        print(  # noqa: T201
            f"rotated: key version {rotation.from_version} -> {rotation.to_version}; "
            f"instructions re-encrypted: {rotation.instructions}"
        )
        return 0
    finally:
        await services.db.dispose()


def _stdout_is_terminal() -> bool:
    """Whether a printed password reaches a person and not a log (Cloud Run, CI and a pipe all
    capture stdout into a log)."""
    return sys.stdout.isatty()


def _reviewer_password(args: argparse.Namespace) -> tuple[str | None, str]:
    """``(password, how it was obtained)``, or ``(None, why it was refused)``. A generated
    password is printed once by the caller, only to a terminal."""
    if args.password_env is not None:
        value = os.environ.get(args.password_env, "")
        if not value:
            return None, f"the environment variable {args.password_env} is unset or empty"
        return value, f"from {args.password_env} (not printed)"
    if not _stdout_is_terminal():
        return None, (
            "stdout is not a terminal, so a generated password would be written to a log; "
            "put the password in a secret and pass --password-env NAME instead"
        )
    return reviewer.generate_password(), "generated"


async def _reviewer_command(args: argparse.Namespace, operator: str) -> int:
    """``reviewer-account create | reset``. Exit ``0`` when done, ``2`` when refused (nothing
    changed). Runs as the API role with the KMS, like ``kms``."""
    password, how = _reviewer_password(args)
    if password is None:
        print(f"refused: {how}")  # noqa: T201
        return 2
    settings = load_settings()
    configure_logging(settings)
    services = build_services(settings, application_name="afterme-admin-reviewer")
    try:
        if settings.is_production_like:
            role = await services.db.current_role()
            if role != "afterme_api":
                print(  # noqa: T201
                    f"refused: reviewer-account must connect as afterme_api, not {role}"
                )
                return 2
        try:
            if args.reviewer_command == "create":
                account = await reviewer.create(
                    services,
                    operator=operator,
                    email=args.email,
                    contact_email=args.contact_email,
                    reason=args.reason,
                    password=password,
                    allow_public_contact=args.allow_public_contact,
                )
            else:
                account = await reviewer.reset(
                    services,
                    operator=operator,
                    user_id=args.user_id,
                    reason=args.reason,
                    password=password,
                    contact_email=args.contact_email,
                    allow_public_contact=args.allow_public_contact,
                )
        except users.UserCommandError as exc:
            print(f"refused: {exc}")  # noqa: T201
            return 2
    finally:
        await services.db.dispose()
    done = "created" if account.command == "create" else "reset"
    print(f"{done}: user_id={account.user_id} login={account.email}")  # noqa: T201
    print(  # noqa: T201
        f"contact: {account.contact_id} (verified; our inbox); plan: 2 stages; "
        f"instructions: {len(reviewer.SAMPLES)} samples; schedule: active, daily 20:00 "
        f"{reviewer.TIMEZONE}; tier: {reviewer.TIER}"
    )
    if account.command == "reset":
        print(  # noqa: T201
            f"sessions ended: {account.sessions_revoked}; contacts removed: "
            f"{account.contacts_removed}; instructions replaced: {account.instructions_replaced}"
        )
    if how == "generated":
        # The one place the password exists in clear outside the hash: this terminal, once.
        print(  # noqa: T201
            "password (shown once; put it in the password manager and Play Console now, it is "
            f"not stored anywhere else): {password}"
        )
    else:
        print(f"password: {how}")  # noqa: T201
    return 0


async def run(argv: list[str]) -> int:  # noqa: PLR0911 - one return per command
    args = _parse(argv)
    if args.command in ("email-test", "push-test"):
        configure_logging(load_settings())
        return await _provider_test(args)
    if args.command == "kms":
        return await _kms_command(args, args.operator or getpass.getuser())
    if args.command == "reviewer-account":
        return await _reviewer_command(args, args.operator or getpass.getuser())
    settings = load_settings()
    configure_logging(settings)
    services = build_worker_services(settings)
    operator = args.operator or getpass.getuser()
    try:
        if args.command == "status" or (args.command == "hold" and args.hold_command == "status"):
            status = await admin.engine_status(services)
            print(json.dumps(status.as_dict(), indent=2))  # noqa: T201
            return 1 if status.pages and args.command == "status" else 0
        if args.command == "hold" and args.hold_command == "enter":
            hold_id = await admin.hold_enter(services, operator=operator, reason=args.reason)
            print(f"Hold entered: {hold_id}")  # noqa: T201
            return 0
        if args.command == "hold" and args.hold_command == "exit":
            ended = await admin.hold_exit(
                services, operator=operator, include_ingestion=args.include_ingestion
            )
            print(f"Holds ended: {ended}")  # noqa: T201
            return 0
        if args.command == "incident" and args.incident_command == "void":
            ok = await admin.void_incident(
                services, operator=operator, incident_id=args.incident_id
            )
            print("voided" if ok else "no open incident with that id")  # noqa: T201
            return 0 if ok else 2
        if args.command == "beta-report":
            try:
                report = await beta.beta_report(services, since=args.since, until=args.until)
            except beta.SchemaMismatch as exc:
                # not a report: a database that is empty or behind would read as a quiet beta
                print(f"refused: {exc}", file=sys.stderr)  # noqa: T201
                return 2
            document = report.as_dict()
            print(json.dumps(document, indent=2) if args.json else beta.format_text(document))  # noqa: T201
            return 0
        if args.command == "action" and args.action_command == "retry":
            outcome = await admin.retry_action(
                services, operator=operator, action_id=args.action_id
            )
            print(outcome)  # noqa: T201
            return 0 if outcome == "retried" else 2
        if args.command == "user":
            return await _user_command(args, services, operator)
        return 2
    finally:
        await services.db.dispose()


def main() -> None:
    sys.exit(asyncio.run(run(sys.argv[1:])))


if __name__ == "__main__":
    main()
