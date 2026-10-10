"""The envelope (SECURITY §6.2) and the development KMS: round trips, binding, tampering,
rotation. Nothing here touches the database."""

from __future__ import annotations

import os
import uuid

import pytest

from app.security import envelope
from app.security.envelope import DecryptionError
from app.security.kms import KmsError, LocalKms, local_key_id

pytestmark = pytest.mark.no_db

USER = uuid.UUID("11111111-1111-4111-8111-111111111111")
OTHER = uuid.UUID("22222222-2222-4222-8222-222222222222")
INSTRUCTION = uuid.UUID("33333333-3333-4333-8333-333333333333")


def test_a_sealed_value_round_trips_and_has_the_documented_format() -> None:
    key = envelope.new_key()
    aad = envelope.instruction_aad(USER, INSTRUCTION, 1)
    blob = envelope.encrypt(key, b"plain text", aad=aad)
    assert blob[:1] == b"\x01"
    assert len(blob) == 1 + 12 + len("plain text") + 16
    assert envelope.decrypt(key, blob, aad=aad) == b"plain text"
    assert b"plain text" not in blob


def test_the_same_plaintext_never_seals_the_same_way_twice() -> None:
    key = envelope.new_key()
    aad = envelope.instruction_aad(USER, INSTRUCTION, 1)
    blobs = {envelope.encrypt(key, b"same", aad=aad) for _ in range(50)}
    assert len(blobs) == 50  # a fresh 96-bit nonce each time


@pytest.mark.parametrize(
    "other_aad",
    [
        envelope.instruction_aad(OTHER, INSTRUCTION, 1),  # another owner
        envelope.instruction_aad(USER, uuid.uuid4(), 1),  # another row
        envelope.instruction_aad(USER, INSTRUCTION, 2),  # another key version
    ],
)
def test_the_aad_binds_a_ciphertext_to_its_owner_row_and_key_version(other_aad: bytes) -> None:
    key = envelope.new_key()
    blob = envelope.encrypt(key, b"secret", aad=envelope.instruction_aad(USER, INSTRUCTION, 1))
    with pytest.raises(DecryptionError):
        envelope.decrypt(key, blob, aad=other_aad)


def test_another_key_or_a_flipped_bit_or_a_truncation_fails() -> None:
    key = envelope.new_key()
    aad = envelope.instruction_aad(USER, INSTRUCTION, 1)
    blob = bytearray(envelope.encrypt(key, b"secret", aad=aad))
    with pytest.raises(DecryptionError):
        envelope.decrypt(envelope.new_key(), bytes(blob), aad=aad)
    for index in (0, 5, 13, len(blob) - 1):  # version, nonce, ciphertext, tag
        broken = bytearray(blob)
        broken[index] ^= 0x01
        with pytest.raises(DecryptionError):
            envelope.decrypt(key, bytes(broken), aad=aad)
    for cut in (0, 1, 12, 28):
        with pytest.raises(DecryptionError):
            envelope.decrypt(key, bytes(blob[:cut]), aad=aad)


async def test_a_wrapped_key_unwraps_for_its_user_only() -> None:
    kms = LocalKms(os.urandom(32))
    dek = envelope.new_key()
    wrapped, key_id = await kms.wrap(dek, user_id=USER)
    assert key_id == kms.active_key_id
    assert await kms.unwrap(wrapped, user_id=USER, key_id=key_id) == dek
    with pytest.raises(KmsError):  # the user is part of what it was sealed with
        await kms.unwrap(wrapped, user_id=OTHER, key_id=key_id)
    with pytest.raises(KmsError):
        await kms.unwrap(wrapped, user_id=USER, key_id="local-unknown")


async def test_a_previous_key_still_unwraps_after_a_rotation() -> None:
    old, new = os.urandom(32), os.urandom(32)
    dek = envelope.new_key()
    wrapped, old_id = await LocalKms(old).wrap(dek, user_id=USER)
    rotated = LocalKms(new, previous=old)
    assert rotated.active_key_id == local_key_id(new)
    assert await rotated.unwrap(wrapped, user_id=USER, key_id=old_id) == dek
    again, new_id = await rotated.wrap(dek, user_id=USER)
    assert new_id != old_id
    assert await rotated.unwrap(again, user_id=USER, key_id=new_id) == dek
    with pytest.raises(KmsError):  # without the old key, the old wrap is lost
        await LocalKms(new).unwrap(wrapped, user_id=USER, key_id=old_id)


def test_a_local_key_must_be_32_bytes() -> None:
    with pytest.raises(ValueError, match="32 bytes"):
        LocalKms(b"short")


def test_a_key_id_does_not_reveal_the_key() -> None:
    key = os.urandom(32)
    assert key.hex() not in local_key_id(key)
    assert local_key_id(key) == local_key_id(key)
    assert local_key_id(key) != local_key_id(os.urandom(32))
