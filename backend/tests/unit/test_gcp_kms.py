"""The Cloud KMS adapter against a fake Cloud KMS that really encrypts (SECURITY §6.2).

Contract tests (request and response shapes of the real REST API, the additional authenticated
data), the failure behaviour (retries, the hard ceiling, the error codes, the breaker) and the
rule that nothing secret reaches an exception or a log line.
"""

from __future__ import annotations

import base64
import io
import json
import logging
import os
import uuid
from collections.abc import Iterator
from typing import Any

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat

from app.api.container import build_kms
from app.core.logging import build_formatter, configure_logging
from app.security import envelope
from app.security.gcp_kms import SCOPE, GcpKms, build_gcp_kms, crc32c
from app.security.kms import KmsError
from tests.fake_cloud_kms import (
    KEY_NAME,
    OTHER_KEY_NAME,
    TOKEN,
    FakeCloudKms,
    StaticToken,
    error,
    slow,
)
from tests.support import make_settings

pytestmark = pytest.mark.no_db

USER = uuid.UUID("11111111-1111-4111-8111-111111111111")
OTHER_USER = uuid.UUID("22222222-2222-4222-8222-222222222222")
KEY_ID = "gcp:" + KEY_NAME


class Sleeps:
    def __init__(self) -> None:
        self.delays: list[float] = []

    async def __call__(self, seconds: float) -> None:
        self.delays.append(seconds)


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def make(
    fake: FakeCloudKms | None = None, **kwargs: Any
) -> tuple[GcpKms, FakeCloudKms, StaticToken, Sleeps, Clock]:
    fake = fake or FakeCloudKms()
    tokens = StaticToken()
    sleeps = Sleeps()
    clock = Clock()
    kms = GcpKms(
        KEY_NAME,
        tokens,
        client=fake.client(),
        sleep=sleeps,
        monotonic=clock,
        **kwargs,
    )
    return kms, fake, tokens, sleeps, clock


def dek() -> bytes:
    return envelope.new_key()


# --- the checksum ------------------------------------------------------------------------------


def test_crc32c_matches_the_standard_check_value() -> None:
    assert crc32c(b"123456789") == 0xE3069283  # the CRC-32C "check" value
    assert crc32c(b"") == 0


# --- the contract: what is sent, what is stored ------------------------------------------------


async def test_wrap_and_unwrap_round_trip_with_the_documented_request_shapes() -> None:
    kms, fake, _, _, _ = make()
    secret = dek()
    wrapped, key_id = await kms.wrap(secret, user_id=USER)

    assert key_id == KEY_ID == kms.active_key_id
    assert wrapped != secret
    assert secret not in wrapped
    (call,) = fake.calls
    assert call.operation == "encrypt"
    assert call.key_name == KEY_NAME  # the CryptoKey, never a version
    assert call.authorization == f"Bearer {TOKEN}"
    assert set(call.body) == {
        "plaintext",
        "additionalAuthenticatedData",
        "plaintextCrc32c",
        "additionalAuthenticatedDataCrc32c",
    }
    assert base64.b64decode(call.body["plaintext"]) == secret
    aad = base64.b64decode(call.body["additionalAuthenticatedData"])
    assert aad == envelope.dek_aad(USER, KEY_ID) == f"afterme/dek/v1|{USER}|{KEY_ID}".encode()
    assert call.body["plaintextCrc32c"] == str(crc32c(secret))  # int64 as a string, as in proto3
    assert call.body["additionalAuthenticatedDataCrc32c"] == str(crc32c(aad))

    assert await kms.unwrap(wrapped, user_id=USER, key_id=key_id) == secret
    decrypt = fake.calls[1]
    assert decrypt.operation == "decrypt"
    assert base64.b64decode(decrypt.body["ciphertext"]) == wrapped
    assert base64.b64decode(decrypt.body["additionalAuthenticatedData"]) == aad
    assert decrypt.body["ciphertextCrc32c"] == str(crc32c(wrapped))


async def test_the_key_id_names_the_cryptokey_and_not_a_version() -> None:
    kms, fake, _, _, _ = make()
    _, before = await kms.wrap(dek(), user_id=USER)
    fake.rotate()
    _, after = await kms.wrap(dek(), user_id=USER)
    assert before == after == KEY_ID  # a new primary version does not change what is stored
    assert "cryptoKeyVersions" not in KEY_ID


async def test_a_wrapped_key_cannot_move_to_another_user_or_key_id() -> None:
    kms, fake, _, _, _ = make()
    wrapped, key_id = await kms.wrap(dek(), user_id=USER)

    with pytest.raises(KmsError) as wrong_user:
        await kms.unwrap(wrapped, user_id=OTHER_USER, key_id=key_id)
    assert wrong_user.value.code == "invalid_argument"  # the (fake) KMS refused: AAD mismatch

    calls = fake.count()
    with pytest.raises(KmsError) as wrong_key:
        await kms.unwrap(wrapped, user_id=USER, key_id="gcp:" + OTHER_KEY_NAME)
    assert wrong_key.value.code == "unknown_key"
    with pytest.raises(KmsError):
        await kms.unwrap(wrapped, user_id=USER, key_id="local-abcdef123456")
    assert fake.count() == calls  # a key id the database made up is never sent anywhere

    with pytest.raises(KmsError):
        await kms.unwrap(wrapped[:-1] + bytes([wrapped[-1] ^ 1]), user_id=USER, key_id=key_id)


async def test_old_versions_still_decrypt_and_are_reported_as_not_current() -> None:
    kms, fake, _, _, _ = make()
    secret = dek()
    old, key_id = await kms.wrap(secret, user_id=USER)
    assert (await kms.unwrap_status(old, user_id=USER, key_id=key_id)).current is True
    fake.rotate()
    status = await kms.unwrap_status(old, user_id=USER, key_id=key_id)
    assert status.dek == secret
    assert status.current is False  # decrypts, but the re-wrap job should rewrite it
    new, _ = await kms.wrap(secret, user_id=USER)
    assert (await kms.unwrap_status(new, user_id=USER, key_id=key_id)).current is True


def test_the_key_name_must_be_a_cryptokey_not_a_version() -> None:
    with pytest.raises(ValueError, match="CryptoKey"):
        GcpKms(KEY_NAME + "/cryptoKeyVersions/1", StaticToken())
    with pytest.raises(ValueError, match="CryptoKey"):
        GcpKms("instruction-kek", StaticToken())


# --- integrity ---------------------------------------------------------------------------------


async def test_an_answer_with_a_bad_checksum_is_refused() -> None:
    kms, fake, _, _, _ = make()
    wrapped, key_id = await kms.wrap(dek(), user_id=USER)

    async def bad_plaintext() -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "plaintext": base64.b64encode(os.urandom(32)).decode(),
                "plaintextCrc32c": "12345",
                "usedPrimary": True,
            },
        )

    fake.script.append(bad_plaintext)
    with pytest.raises(KmsError) as bad:
        await kms.unwrap(wrapped, user_id=USER, key_id=key_id)
    assert bad.value.code == "integrity"

    async def unverified() -> httpx.Response:
        blob = b"\x01" + os.urandom(60)
        return httpx.Response(
            200,
            json={
                "name": KEY_NAME + "/cryptoKeyVersions/1",
                "ciphertext": base64.b64encode(blob).decode(),
                "ciphertextCrc32c": str(crc32c(blob)),
                "verifiedPlaintextCrc32c": False,
                "verifiedAdditionalAuthenticatedDataCrc32c": True,
            },
        )

    fake.script.append(unverified)
    with pytest.raises(KmsError) as unchecked:
        await kms.wrap(dek(), user_id=USER)
    assert unchecked.value.code == "integrity"  # the KMS did not see the bytes we sent


async def test_a_key_of_the_wrong_size_or_a_foreign_version_name_is_refused() -> None:
    kms, fake, _, _, _ = make()
    wrapped, key_id = await kms.wrap(dek(), user_id=USER)

    async def short_key() -> httpx.Response:
        short = b"too short"
        return httpx.Response(
            200,
            json={
                "plaintext": base64.b64encode(short).decode(),
                "plaintextCrc32c": str(crc32c(short)),
            },
        )

    fake.script.append(short_key)
    with pytest.raises(KmsError) as size:
        await kms.unwrap(wrapped, user_id=USER, key_id=key_id)
    assert size.value.code == "integrity"

    async def other_key() -> httpx.Response:
        blob = os.urandom(60)
        return httpx.Response(
            200,
            json={
                "name": OTHER_KEY_NAME + "/cryptoKeyVersions/1",
                "ciphertext": base64.b64encode(blob).decode(),
                "ciphertextCrc32c": str(crc32c(blob)),
            },
        )

    fake.script.append(other_key)
    with pytest.raises(KmsError) as foreign:
        await kms.wrap(dek(), user_id=USER)
    assert foreign.value.code == "key_mismatch"


# --- errors: what is retried and what is not ---------------------------------------------------


@pytest.mark.parametrize(
    ("status", "code"),
    [
        (400, "invalid_argument"),
        (401, "unauthenticated"),
        (403, "permission_denied"),
        (404, "not_found"),
        (409, "http_409"),
    ],
)
async def test_client_errors_are_not_retried_and_map_to_a_short_code(
    status: int, code: str
) -> None:
    kms, fake, tokens, sleeps, _ = make()
    fake.outage(status)
    with pytest.raises(KmsError) as failed:
        await kms.wrap(dek(), user_id=USER)
    assert failed.value.code == code
    assert str(failed.value) == code
    assert sleeps.delays == []
    # 401 asks for a fresh token once (the cached one may have expired) and then gives up
    assert fake.count() == (2 if status == 401 else 1)
    assert tokens.forced == (1 if status == 401 else 0)


@pytest.mark.parametrize(
    ("status", "code"), [(429, "rate_limited"), (500, "unavailable"), (503, "unavailable")]
)
async def test_throttling_and_server_errors_are_retried_twice_then_fail(
    status: int, code: str
) -> None:
    kms, fake, _, sleeps, _ = make()
    fake.outage(status)
    with pytest.raises(KmsError) as failed:
        await kms.wrap(dek(), user_id=USER)
    assert failed.value.code == code
    assert fake.count() == 3  # the first try and at most two retries
    assert len(sleeps.delays) == 2
    assert all(0 < d <= 1.0 for d in sleeps.delays)


async def test_a_blip_is_ridden_out() -> None:
    kms, fake, _, _, _ = make()
    fake.script.extend([503, 429])
    wrapped, key_id = await kms.wrap(dek(), user_id=USER)
    assert fake.count() == 3
    fake.script.extend([httpx.ConnectError("boom")])
    assert await kms.unwrap(wrapped, user_id=USER, key_id=key_id)


async def test_retry_after_is_honoured_but_capped() -> None:
    kms, fake, _, sleeps, _ = make()

    async def slow_down() -> httpx.Response:
        return httpx.Response(429, headers={"Retry-After": "3600"}, json={})

    fake.script.extend([slow_down, slow_down, slow_down])
    with pytest.raises(KmsError):
        await kms.wrap(dek(), user_id=USER)
    assert sleeps.delays == [1.0, 1.0]  # never an hour: a request is waiting


async def test_network_failures_and_unreadable_answers_map_to_codes() -> None:
    kms, fake, _, _, _ = make()
    fake.outage(httpx.ConnectError("no route to host kms.internal 10.0.0.5"))
    with pytest.raises(KmsError) as network:
        await kms.wrap(dek(), user_id=USER)
    assert network.value.code == "network"
    assert "10.0.0.5" not in str(network.value)
    assert fake.count() == 3

    kms, fake, _, _, _ = make()

    async def html() -> httpx.Response:
        return httpx.Response(200, content=b"<html>proxy page</html>")

    fake.script.append(html)
    with pytest.raises(KmsError) as unreadable:
        await kms.wrap(dek(), user_id=USER)
    assert unreadable.value.code == "bad_response"
    assert fake.count() == 1  # a 200 that is not JSON is not a blip


async def test_a_call_is_cut_off_at_the_ceiling_and_retried_at_most_twice() -> None:
    kms, fake, _, _, _ = make(timeout=0.05)
    fake.outage(httpx.ReadTimeout("slow"))
    with pytest.raises(KmsError) as failed:
        await kms.wrap(dek(), user_id=USER)
    assert failed.value.code == "timeout"
    assert fake.count() == 3

    kms, fake, _, _, _ = make(timeout=0.05)
    fake.script.extend([lambda: slow(5), lambda: slow(5), lambda: slow(5)])  # hangs, not errors
    with pytest.raises(KmsError) as hung:
        await kms.wrap(dek(), user_id=USER)
    assert hung.value.code == "timeout"
    assert fake.count() == 3


async def test_the_default_ceiling_is_three_seconds_and_two_retries() -> None:
    from app.security import gcp_kms

    assert gcp_kms.CALL_TIMEOUT_SECONDS == 3.0
    assert gcp_kms.MAX_RETRIES == 2


async def test_a_token_that_cannot_be_fetched_is_a_kms_error_not_an_exception() -> None:
    from app.notifications.errors import ProviderUnavailableError

    kms, fake, tokens, _, _ = make()
    tokens.fail = ProviderUnavailableError("fcm_metadata_unreachable")
    with pytest.raises(KmsError) as failed:
        await kms.wrap(dek(), user_id=USER)
    assert failed.value.code == "token_unavailable"
    assert fake.count() == 0


async def test_after_an_outage_calls_fail_fast_until_the_pause_is_over() -> None:
    kms, fake, _, _, clock = make(breaker_seconds=10.0)
    fake.outage(503)
    with pytest.raises(KmsError):
        await kms.wrap(dek(), user_id=USER)
    assert fake.count() == 3

    for _ in range(5):  # a pile of requests does not become a pile of 3-second waits
        with pytest.raises(KmsError) as quick:
            await kms.wrap(dek(), user_id=USER)
        assert quick.value.code == "recently_unavailable"
    assert fake.count() == 3

    fake.recover()
    clock.now += 11
    wrapped, key_id = await kms.wrap(dek(), user_id=USER)  # tries again by itself
    assert await kms.unwrap(wrapped, user_id=USER, key_id=key_id)


async def test_a_refusal_does_not_open_the_pause() -> None:
    kms, fake, _, _, _ = make()
    fake.outage(403)
    for _ in range(3):
        with pytest.raises(KmsError) as failed:
            await kms.wrap(dek(), user_id=USER)
        assert failed.value.code == "permission_denied"  # fixed at once, no waiting out a pause
    fake.recover()
    await kms.wrap(dek(), user_id=USER)


# --- nothing secret leaves ---------------------------------------------------------------------


@pytest.fixture
def captured() -> Iterator[io.StringIO]:
    configure_logging(make_settings(log_level="INFO"))
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(build_formatter(json=True))
    handler.setLevel(logging.DEBUG)
    root = logging.getLogger()
    previous = root.level
    root.addHandler(handler)
    root.setLevel(logging.DEBUG)
    try:
        yield stream
    finally:
        root.removeHandler(handler)
        root.setLevel(previous)
        configure_logging(make_settings())


async def test_no_key_name_body_dek_or_wrapped_value_reaches_a_message_or_a_log(
    captured: io.StringIO,
) -> None:
    kms, fake, _, _, _ = make()
    secret = dek()
    wrapped, key_id = await kms.wrap(secret, user_id=USER)
    secret_body = "super-secret-detail-from-the-response-body-xyz"

    async def leaky() -> httpx.Response:
        return httpx.Response(
            403,
            json={"error": {"code": 403, "status": "PERMISSION_DENIED", "message": secret_body}},
        )

    seen: list[str] = []
    for scripted in (
        [leaky],
        [503, 503, 503],
        [httpx.ConnectError("connect to https://cloudkms.googleapis.com")] * 3,
    ):
        fake.script.extend(scripted)  # type: ignore[arg-type]
        with pytest.raises(KmsError) as failed:
            await kms.unwrap(wrapped, user_id=USER, key_id=key_id)
        error_ = failed.value
        seen += [
            str(error_),
            repr(error_),
            repr(error_.args),
            str(error_.__cause__),
            str(error_.__context__),
        ]
        # the cause chain is cut: no httpx error (with its URL) hangs off the exception
        assert error_.__cause__ is None
    fake.recover()
    seen.append(captured.getvalue())

    forbidden = [
        secret_body,
        KEY_NAME,
        "afterme-test",
        "cryptoKeys",
        secret.hex(),
        base64.b64encode(secret).decode(),
        base64.b64encode(wrapped).decode(),
        wrapped.hex(),
        TOKEN,
        str(USER),
    ]
    blob = "\n".join(seen)
    for value in forbidden:
        assert value not in blob, value
    assert "kms.call_failed" in captured.getvalue()  # the failures are logged ...
    assert "permission_denied" in captured.getvalue()  # ... by code


# --- building it from settings -----------------------------------------------------------------


def _router(fake: FakeCloudKms, seen: list[httpx.Request]) -> httpx.AsyncClient:
    """One client that answers the metadata server, Google's OAuth endpoint and Cloud KMS."""

    async def handle(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        host = request.url.host
        if host == "metadata.google.internal":
            assert request.headers["metadata-flavor"] == "Google"
            return httpx.Response(200, json={"access_token": TOKEN, "expires_in": 3000})
        if host == "oauth2.googleapis.com":
            return httpx.Response(200, json={"access_token": TOKEN, "expires_in": 3000})
        return await fake.handle(request)

    return httpx.AsyncClient(transport=httpx.MockTransport(handle), timeout=3.0)


async def test_the_metadata_server_is_the_default_identity() -> None:
    fake, seen = FakeCloudKms(), []
    settings = make_settings(kms_provider="gcp_kms", kms_key_name=KEY_NAME)
    kms = build_gcp_kms(settings, client=_router(fake, seen))
    wrapped, key_id = await kms.wrap(dek(), user_id=USER)
    assert await kms.unwrap(wrapped, user_id=USER, key_id=key_id)
    hosts = [r.url.host for r in seen]
    assert hosts[0] == "metadata.google.internal"  # one token fetch, then cached
    assert hosts.count("metadata.google.internal") == 1
    assert "oauth2.googleapis.com" not in hosts


async def test_a_service_account_key_is_the_dev_and_ci_identity_with_the_cloud_platform_scope() -> (
    None
):
    pem = (
        rsa.generate_private_key(public_exponent=65537, key_size=2048)
        .private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
        .decode()
    )
    info = {"client_email": "kms-dev@afterme-test.iam.gserviceaccount.com", "private_key": pem}
    fake, seen = FakeCloudKms(), []
    settings = make_settings(
        kms_provider="gcp_kms", kms_key_name=KEY_NAME, kms_credentials_json=json.dumps(info)
    )
    kms = build_gcp_kms(settings, client=_router(fake, seen))
    await kms.wrap(dek(), user_id=USER)
    exchange = next(r for r in seen if r.url.host == "oauth2.googleapis.com")
    form = dict(pair.split("=", 1) for pair in exchange.content.decode().split("&"))
    claims = jwt.decode(
        form["assertion"].replace("%2E", "."),
        options={"verify_signature": False},
        algorithms=["RS256"],
    )
    assert claims["scope"] == SCOPE == "https://www.googleapis.com/auth/cloud-platform"
    assert claims["iss"] == info["client_email"]
    assert all(r.url.host != "metadata.google.internal" for r in seen)


def test_the_container_builds_the_adapter_for_gcp_kms_and_the_local_one_for_dev() -> None:
    from app.security.kms import LocalKms

    assert isinstance(build_kms(make_settings()), LocalKms)
    assert isinstance(
        build_kms(make_settings(kms_provider="gcp_kms", kms_key_name=KEY_NAME)), GcpKms
    )


def test_error_envelope_helper_matches_googles_shape() -> None:
    body = json.loads(error(403, "PERMISSION_DENIED", "denied").content)
    assert body == {"error": {"code": 403, "message": "denied", "status": "PERMISSION_DENIED"}}


# --- K-2: every failure is one kms.call_failed line, with its code ------------------------------


def _failures(stream: io.StringIO) -> list[dict[str, Any]]:
    found = []
    for line in stream.getvalue().splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get("event") == "kms.call_failed":
            found.append(record)
    return found


def _answer(payload: dict[str, Any]) -> Any:
    async def respond() -> httpx.Response:
        return httpx.Response(200, json=payload)

    return respond


async def test_every_failure_path_logs_exactly_one_call_failed_event(
    captured: io.StringIO,
) -> None:
    kms, fake, _, _, clock = make(breaker_seconds=10.0)
    wrapped, key_id = await kms.wrap(dek(), user_id=USER)
    short = b"too short"
    foreign = os.urandom(60)
    cases: list[tuple[str, str, Any]] = [
        ("unknown_key", "decrypt", None),
        ("integrity", "decrypt", _answer({"plaintext": base64.b64encode(short).decode()})),
        ("bad_response", "decrypt", _answer({"plaintext": 12})),
        (
            "key_mismatch",
            "encrypt",
            _answer(
                {
                    "name": OTHER_KEY_NAME + "/cryptoKeyVersions/1",
                    "ciphertext": base64.b64encode(foreign).decode(),
                }
            ),
        ),
        ("permission_denied", "encrypt", 403),
    ]
    for code, operation, scripted in cases:
        before = len(_failures(captured))
        if scripted is not None:
            fake.script.append(scripted)
        if operation == "encrypt":
            call = kms.wrap(dek(), user_id=USER)
        else:
            unknown = "gcp:" + OTHER_KEY_NAME if code == "unknown_key" else key_id
            call = kms.unwrap(wrapped, user_id=USER, key_id=unknown)  # type: ignore[assignment]
        with pytest.raises(KmsError) as failed:
            await call
        assert failed.value.code == code
        logged = _failures(captured)[before:]
        assert [(r["operation"], r["failure"]) for r in logged] == [(operation, code)], code

    # an outage: three attempts, ONE line; then the breaker's fast failures, one line each, so a
    # quiet beta still reaches the alert threshold
    fake.outage(503)
    before = len(_failures(captured))
    with pytest.raises(KmsError):
        await kms.wrap(dek(), user_id=USER)
    for _ in range(3):
        with pytest.raises(KmsError):
            await kms.unwrap(wrapped, user_id=USER, key_id=key_id)
    logged = _failures(captured)[before:]
    assert [r["failure"] for r in logged] == ["unavailable"] + ["recently_unavailable"] * 3
    clock.now += 11
    fake.recover()
    blob = "\n".join(str(r) for r in _failures(captured))
    for secret in (KEY_NAME, OTHER_KEY_NAME, TOKEN, str(USER), base64.b64encode(wrapped).decode()):
        assert secret not in blob
