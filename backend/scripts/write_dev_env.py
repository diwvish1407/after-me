"""Create backend/.env for local development, atomically and readable only by you.

    uv run python scripts/write_dev_env.py

* Starts from ``.env.example`` and puts the role passwords from AFTERME_OWNER_DB_PASSWORD /
  AFTERME_API_DB_PASSWORD (the same variables ``dev_db_setup.sh`` reads; dev defaults otherwise)
  into the two database URLs, so a customised password does not break ``alembic upgrade head``.
* Appends a fresh JWT signing key and HMAC pepper from ``generate_jwt_key.py --with-pepper``.
* Writes to a private (0600) temporary file in the same directory and renames it into place, so a
  failure part-way never leaves a ``.env`` without secrets behind, and the secrets are never
  readable by other users.
* An existing ``.env`` is left unchanged.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote

BACKEND = Path(__file__).resolve().parents[1]
TARGET = BACKEND / ".env"
EXAMPLE = BACKEND / ".env.example"
KEYGEN = Path(__file__).with_name("generate_jwt_key.py")

# (role, environment variable, dev default): the defaults match dev_db_setup.sh and .env.example.
ROLES = (
    ("afterme_api", "AFTERME_API_DB_PASSWORD", "afterme_api_dev"),
    ("afterme_owner", "AFTERME_OWNER_DB_PASSWORD", "afterme_owner_dev"),
)


def build_env() -> str:
    text = EXAMPLE.read_text(encoding="utf-8")
    for role, variable, default in ROLES:
        password = os.environ.get(variable, default)
        text = text.replace(f"//{role}:{default}@", f"//{role}:{quote(password, safe='')}@")
    secrets_block = subprocess.run(  # noqa: S603 - fixed argument list, no user input
        [sys.executable, str(KEYGEN), "--with-pepper"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return text.rstrip("\n") + "\n" + secrets_block


def main() -> int:
    if TARGET.exists():
        print("backend/.env exists; left unchanged")
        return 0
    content = build_env()
    fd, tmp_name = tempfile.mkstemp(prefix=".env.", dir=BACKEND)  # created with mode 0600
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.replace(tmp_name, TARGET)
    except BaseException:
        Path(tmp_name).unlink(missing_ok=True)
        raise
    print("Created backend/.env with fresh dev secrets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
