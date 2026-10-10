"""AES-256-GCM sealing of instruction content (SECURITY §6.2).

Stored format: ``0x01 || nonce(12) || ciphertext || tag(16)``. The additional authenticated data
binds each ciphertext to its owner, its row and the key version, so a ciphertext that is copied
or swapped to another row, user or version fails to decrypt instead of showing someone else's
text. Nothing here logs, caches or persists plaintext.
"""

from __future__ import annotations

import os
import uuid
from typing import Final

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

FORMAT_VERSION: Final = b"\x01"
NONCE_BYTES: Final = 12
TAG_BYTES: Final = 16
KEY_BYTES: Final = 32


class DecryptionError(Exception):
    """The ciphertext is malformed, was changed, or does not belong where it was found."""


def new_key() -> bytes:
    return os.urandom(KEY_BYTES)


def encrypt(key: bytes, plaintext: bytes, *, aad: bytes) -> bytes:
    nonce = os.urandom(NONCE_BYTES)  # a fresh random 96-bit nonce per encryption
    return FORMAT_VERSION + nonce + AESGCM(key).encrypt(nonce, plaintext, aad)


def decrypt(key: bytes, blob: bytes, *, aad: bytes) -> bytes:
    if len(blob) < 1 + NONCE_BYTES + TAG_BYTES or blob[:1] != FORMAT_VERSION:
        raise DecryptionError
    try:
        return AESGCM(key).decrypt(blob[1 : 1 + NONCE_BYTES], blob[1 + NONCE_BYTES :], aad)
    except InvalidTag:
        raise DecryptionError from None


def instruction_aad(user_id: uuid.UUID, instruction_id: uuid.UUID, key_version: int) -> bytes:
    return f"afterme/instruction/v1|{user_id}|{instruction_id}|{key_version}".encode()


def dek_aad(user_id: uuid.UUID, kek_id: str) -> bytes:
    return f"afterme/dek/v1|{user_id}|{kek_id}".encode()
