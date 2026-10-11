"""``python -m cli.admin``: the operator's command line (``afterme-admin``).

    python -m cli.admin status
    python -m cli.admin hold status | enter --reason "..." | exit [--include-ingestion]
    python -m cli.admin incident void <incident-id>
    python -m cli.admin action retry <action-id>
    python -m cli.admin email-test --to ADDRESS     # one message through the configured chain
    python -m cli.admin push-test --token TOKEN     # one push through the configured provider

Connects as the worker role; every command is audited with an operator actor.
"""

from __future__ import annotations

import argparse
import asyncio
import getpass
import json
import sys
import uuid

from app.api.container import build_worker_services
from app.core.config import load_settings
from app.core.logging import configure_logging
from app.notifications.email import EmailMessage
from app.notifications.errors import ProviderError
from app.notifications.providers.factory import build_email_provider, build_push_provider
from app.notifications.push import PushMessage
from app.ops import admin


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
    email = sub.add_parser(
        "email-test", help="send one test message through the configured email provider(s)"
    )
    email.add_argument("--to", required=True)
    push = sub.add_parser("push-test", help="send one test push through the configured provider")
    push.add_argument("--token", required=True, help="an FCM registration token")
    return parser


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


async def run(argv: list[str]) -> int:
    args = _parser().parse_args(argv)
    if args.command in ("email-test", "push-test"):
        configure_logging(load_settings())
        return await _provider_test(args)
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
        if args.command == "action" and args.action_command == "retry":
            outcome = await admin.retry_action(
                services, operator=operator, action_id=args.action_id
            )
            print(outcome)  # noqa: T201
            return 0 if outcome == "retried" else 2
        return 2
    finally:
        await services.db.dispose()


def main() -> None:
    sys.exit(asyncio.run(run(sys.argv[1:])))


if __name__ == "__main__":
    main()
