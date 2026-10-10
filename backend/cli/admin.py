"""``python -m cli.admin``: the operator's command line (``afterme-admin``).

    python -m cli.admin status
    python -m cli.admin hold status | enter --reason "..." | exit [--include-ingestion]
    python -m cli.admin incident void <incident-id>
    python -m cli.admin action retry <action-id>

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
    return parser


async def run(argv: list[str]) -> int:
    args = _parser().parse_args(argv)
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
