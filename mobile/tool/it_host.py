#!/usr/bin/env python3
"""Host-side hands for the emulator integration tests (started by tool/integration.sh).

The tests run inside the app on the emulator and can only make HTTP calls. Two things a
person (or an operator) does are not HTTP calls the backend offers, and are done here:

  POST /hold/enter | /hold/exit | /hold/status
      the operator's circuit breaker: `python -m cli.admin hold enter|exit|status`
      (API_SPEC §14: "not exposed over HTTP"), run in backend/ against the throwaway
      database and the same test clock as the API and the worker;
  POST /tier {"user_id": "<uuid>", "tier": "free" | "premium"}
      the account's plan. There is no billing yet, so the tier is changed in the throwaway
      database, as the owner role, for the account the test created.

It is deliberately small:
  * it listens on 127.0.0.1 only (the emulator reaches the host's loopback as 10.0.2.2);
  * every request needs the run's random test token in `X-Test-Token`;
  * the commands are fixed argument lists: nothing from a request is ever put in a shell
    or in a command, only a validated UUID and one of two tier names in a SQL parameter.

Environment (set by integration.sh; the backend's own variables are inherited by the CLI):
  IT_HOST_TOKEN   the run's test token          IT_HOST_PORT   port to listen on
  IT_BACKEND_DIR  the backend directory         IT_OWNER_URL   libpq URL of the owner role
"""

from __future__ import annotations

import hmac
import json
import os
import subprocess
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ["IT_HOST_TOKEN"]
PORT = int(os.environ["IT_HOST_PORT"])
BACKEND_DIR = os.environ["IT_BACKEND_DIR"]
OWNER_URL = os.environ["IT_OWNER_URL"]

MAX_BODY = 4096
CLI_TIMEOUT_SECONDS = 90
OPERATOR = "integration-test"
REASON = "integration test (MOB-68)"

# The only commands there are. `sys.executable` is the backend's own interpreter.
COMMANDS = {
    "/hold/enter": ["hold", "enter", "--reason", REASON],
    "/hold/exit": ["hold", "exit"],
    "/hold/status": ["hold", "status"],
}


def run_cli(arguments: list[str]) -> tuple[int, str, str]:
    """(exit code, stdout, stderr). Logging goes to stderr, the answer to stdout."""
    done = subprocess.run(  # noqa: S603 - a fixed argument list
        [sys.executable, "-m", "cli.admin", "--operator", OPERATOR, *arguments],
        cwd=BACKEND_DIR,
        capture_output=True,
        text=True,
        timeout=CLI_TIMEOUT_SECONDS,
        check=False,
    )
    return done.returncode, done.stdout.strip(), done.stderr.strip()


def set_tier(user_id: str, tier: str) -> int:
    import psycopg  # the backend's own driver; this runs under its interpreter

    with psycopg.connect(OWNER_URL, autocommit=True) as connection:
        cursor = connection.execute(
            "UPDATE users SET tier = %s WHERE id = %s", (tier, uuid.UUID(user_id))
        )
        return cursor.rowcount


class Handler(BaseHTTPRequestHandler):
    server_version = "afterme-it-host"

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        sys.stderr.write("it_host: %s\n" % (format % args))

    def _reply(self, status: int, body: dict[str, object]) -> None:
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _authorised(self) -> bool:
        given = self.headers.get("X-Test-Token", "")
        return hmac.compare_digest(given.encode(), TOKEN.encode())

    @staticmethod
    def _body(raw: bytes) -> dict[str, object]:
        value = json.loads(raw or b"{}")
        if not isinstance(value, dict):
            raise ValueError("body must be an object")
        return value

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/ping" and self._authorised():
            self._reply(200, {"ok": True})
        else:
            self._reply(404, {"ok": False})

    def do_POST(self) -> None:  # noqa: N802
        # The body is always read, whatever the path: closing a socket with unread bytes
        # makes the OS reset the connection and the caller never sees the answer.
        try:
            raw_length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            raw_length = 0
        raw_body = self.rfile.read(min(raw_length, MAX_BODY)) if raw_length > 0 else b""
        if not self._authorised():
            self._reply(401, {"ok": False, "error": "token"})
            return
        try:
            if self.path in COMMANDS:
                code, out, err = run_cli(COMMANDS[self.path])
                status: dict[str, object] | None = None
                if self.path == "/hold/status" and code == 0:
                    status = json.loads(out)
                self._reply(
                    200 if code == 0 else 500,
                    {
                        "ok": code == 0,
                        "exit": code,
                        "output": (out + "\n" + err).strip()[-1500:],
                        "status": status,
                    },
                )
            elif self.path == "/tier":
                body = self._body(raw_body)
                tier = str(body.get("tier", ""))
                if tier not in ("free", "premium"):
                    raise ValueError("tier must be free or premium")
                changed = set_tier(str(body.get("user_id", "")), tier)
                self._reply(200 if changed == 1 else 404, {"ok": changed == 1, "rows": changed})
            else:
                self._reply(404, {"ok": False})
        except (ValueError, KeyError) as error:
            self._reply(400, {"ok": False, "error": str(error)[:200]})
        except Exception as error:  # the test reads this; the log has the rest
            self._reply(500, {"ok": False, "error": f"{type(error).__name__}: {str(error)[:200]}"})


def main() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    sys.stderr.write(f"it_host: listening on 127.0.0.1:{PORT}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
