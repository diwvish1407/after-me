"""A fake Cloud KMS for the tests: ``httpx.MockTransport`` that really encrypts.

It answers the two REST calls the adapter makes
(``POST https://cloudkms.googleapis.com/v1/{cryptoKey}:encrypt`` and ``:decrypt``) with the
request and response shapes of the real API: base64 ``plaintext`` / ``ciphertext`` /
``additionalAuthenticatedData`` fields, int64 CRC32C checksums as strings, ``name`` of the key
*version* in an encrypt answer, ``usedPrimary`` in a decrypt answer, and Google's error envelope
(``{"error": {"code": ..., "status": ...}}``) for failures.

It really encrypts (AES-256-GCM, a key per version, the version recorded in the ciphertext) and
really checks the additional authenticated data, so the wrong user id or the wrong key id fail
the way they would against the real service (400 INVALID_ARGUMENT). It checks the checksums the
adapter sends, and refuses a request without a bearer token.
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

import httpx
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from app.security.gcp_kms import crc32c

KEY_NAME = "projects/afterme-test/locations/asia-south1/keyRings/afterme/cryptoKeys/instruction-kek"
OTHER_KEY_NAME = (
    "projects/afterme-test/locations/asia-south1/keyRings/afterme/cryptoKeys/another-key"
)
TOKEN = "ya29.fake-access-token"


class StaticToken:
    """An access-token source that always answers the token the fake accepts."""

    def __init__(self) -> None:
        self.forced = 0
        self.fail: Exception | None = None

    async def token(self, *, force: bool = False) -> str:
        if self.fail is not None:
            raise self.fail
        self.forced += int(force)
        return TOKEN


def error(status: int, google_status: str = "INTERNAL", message: str = "an internal error") -> Any:
    return httpx.Response(
        status,
        json={"error": {"code": status, "message": message, "status": google_status}},
    )


@dataclass
class Call:
    operation: str
    key_name: str
    body: dict[str, Any]
    authorization: str


@dataclass
class FakeCloudKms:
    key_name: str = KEY_NAME
    versions: list[bytes] = field(default_factory=lambda: [os.urandom(32)])
    primary: int = 0  # index into ``versions``
    calls: list[Call] = field(default_factory=list)
    # What to do with the next calls, consumed in order: an int is an HTTP status, an Exception
    # is raised from the transport, a callable is awaited and returns the response.
    script: list[int | Exception | Callable[[], Awaitable[httpx.Response]]] = field(
        default_factory=list
    )
    down: Exception | int | None = None  # every call, until cleared

    # ------------------------------------------------------------------ control

    def rotate(self) -> None:
        """Cloud KMS key rotation: a new version becomes primary; the old one still decrypts."""
        self.versions.append(os.urandom(32))
        self.primary = len(self.versions) - 1

    def outage(self, how: Exception | int = 503) -> None:
        self.down = how

    def recover(self) -> None:
        self.down = None
        self.script.clear()

    def count(self, operation: str | None = None) -> int:
        return len([c for c in self.calls if operation is None or c.operation == operation])

    # ------------------------------------------------------------------ the transport

    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handle)

    def client(self, timeout: float = 3.0) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=self.transport(), timeout=timeout)

    async def handle(self, request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        prefix = "https://cloudkms.googleapis.com/v1/"
        assert url.startswith(prefix), url
        assert request.method == "POST"
        path = url.removeprefix(prefix)
        name, _, operation = path.rpartition(":")
        assert operation in ("encrypt", "decrypt"), operation
        body = json.loads(request.content)
        self.calls.append(Call(operation, name, body, request.headers.get("authorization", "")))
        for scripted in ([self.script.pop(0)] if self.script else []) + (
            [self.down] if self.down is not None else []
        ):
            if isinstance(scripted, Exception):
                raise scripted
            if isinstance(scripted, int):
                return error(scripted, "UNAVAILABLE" if scripted >= 500 else "PERMISSION_DENIED")
            return await scripted()
        if request.headers.get("authorization") != f"Bearer {TOKEN}":
            return error(401, "UNAUTHENTICATED", "no credentials")
        if name != self.key_name:
            return error(404, "NOT_FOUND", "no such key")
        return self._encrypt(body) if operation == "encrypt" else self._decrypt(body)

    # ------------------------------------------------------------------ the two calls

    def _check_crc(self, body: dict[str, Any], field_name: str, data: bytes) -> bool:
        wanted = body.get(field_name)
        return wanted is None or int(wanted) == crc32c(data)

    def _encrypt(self, body: dict[str, Any]) -> httpx.Response:
        plaintext = base64.b64decode(body["plaintext"], validate=True)
        aad = base64.b64decode(body.get("additionalAuthenticatedData", ""), validate=True)
        if not self._check_crc(body, "plaintextCrc32c", plaintext) or not self._check_crc(
            body, "additionalAuthenticatedDataCrc32c", aad
        ):
            return error(400, "INVALID_ARGUMENT", "checksum mismatch")
        nonce = os.urandom(12)
        sealed = AESGCM(self.versions[self.primary]).encrypt(nonce, plaintext, aad)
        blob = b"\x01" + bytes([self.primary]) + nonce + sealed
        return httpx.Response(
            200,
            json={
                "name": f"{self.key_name}/cryptoKeyVersions/{self.primary + 1}",
                "ciphertext": base64.b64encode(blob).decode(),
                "ciphertextCrc32c": str(crc32c(blob)),
                "verifiedPlaintextCrc32c": "plaintextCrc32c" in body,
                "verifiedAdditionalAuthenticatedDataCrc32c": (
                    "additionalAuthenticatedDataCrc32c" in body
                ),
                "protectionLevel": "SOFTWARE",
            },
        )

    def _decrypt(self, body: dict[str, Any]) -> httpx.Response:
        blob = base64.b64decode(body["ciphertext"], validate=True)
        aad = base64.b64decode(body.get("additionalAuthenticatedData", ""), validate=True)
        if not self._check_crc(body, "ciphertextCrc32c", blob) or not self._check_crc(
            body, "additionalAuthenticatedDataCrc32c", aad
        ):
            return error(400, "INVALID_ARGUMENT", "checksum mismatch")
        if len(blob) < 2 + 12 + 16 or blob[0] != 1 or blob[1] >= len(self.versions):
            return error(400, "INVALID_ARGUMENT", "Decryption failed: the ciphertext is invalid")
        index = blob[1]
        try:
            plaintext = AESGCM(self.versions[index]).decrypt(blob[2:14], blob[14:], aad)
        except InvalidTag:
            return error(400, "INVALID_ARGUMENT", "Decryption failed: the ciphertext is invalid")
        return httpx.Response(
            200,
            json={
                "plaintext": base64.b64encode(plaintext).decode(),
                "plaintextCrc32c": str(crc32c(plaintext)),
                "usedPrimary": index == self.primary,
                "protectionLevel": "SOFTWARE",
            },
        )


async def slow(seconds: float) -> httpx.Response:
    """A call that answers after ``seconds`` (to be cut off by the adapter's ceiling)."""
    await asyncio.sleep(seconds)
    return httpx.Response(200, json={})
