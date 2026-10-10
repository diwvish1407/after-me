"""Generate an Ed25519 JWT signing key (and optionally an HMAC pepper) as .env lines.

    uv run python scripts/generate_jwt_key.py                 # key only
    uv run python scripts/generate_jwt_key.py --with-pepper   # key + AFTERME_HMAC_PEPPER
    uv run python scripts/generate_jwt_key.py --kid 2026-10   # choose the key ID

The output is secret. `make setup` appends it to backend/.env (git-ignored) for local development.
Staging/production keys are generated the same way and stored only in the secret manager.
For rotation, add the new kid to AFTERME_JWT_SIGNING_KEYS next to the old one, switch
AFTERME_JWT_ACTIVE_KID, and drop the old key after the access-token lifetime has passed.
"""

from __future__ import annotations

import argparse
import json
import re
import secrets
from datetime import UTC, datetime

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    NoEncryption,
    PrivateFormat,
)

_KID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--kid", default=datetime.now(UTC).strftime("k%Y%m%d%H%M%S"))
    parser.add_argument("--with-pepper", action="store_true", help="also print a new pepper")
    args = parser.parse_args()
    if not _KID_RE.match(args.kid):
        parser.error("kid must match [A-Za-z0-9._-]{1,64}")

    pem = (
        Ed25519PrivateKey.generate()
        .private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
        .decode()
    )
    keys = json.dumps({args.kid: pem})
    # Single quotes: dotenv keeps the JSON (and its \n escapes) verbatim.
    print(f"AFTERME_JWT_SIGNING_KEYS='{keys}'")
    print(f"AFTERME_JWT_ACTIVE_KID={args.kid}")
    if args.with_pepper:
        print(f"AFTERME_HMAC_PEPPER={secrets.token_urlsafe(48)}")


if __name__ == "__main__":
    main()
