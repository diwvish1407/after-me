"""Access-token verification (TEST_PLAN SEC-08)."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from app.auth.tokens import (
    AccessTokenService,
    hash_refresh_token,
    looks_like_refresh_token,
    new_refresh_token,
)
from app.core.errors import TokenExpired, Unauthenticated
from tests.support import T0

pytestmark = pytest.mark.no_db

KEY = Ed25519PrivateKey.generate()
OTHER_KEY = Ed25519PrivateKey.generate()
USER = uuid.uuid4()
SESSION = uuid.uuid4()


def service(**overrides: Any) -> AccessTokenService:
    values: dict[str, Any] = {
        "signing_keys": {"k1": KEY},
        "active_kid": "k1",
        "issuer": "iss-test",
        "audience": "aud-test",
        "ttl_seconds": 900,
    }
    values.update(overrides)
    return AccessTokenService(**values)


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _claims(**overrides: Any) -> dict[str, Any]:
    iat = int(T0.timestamp())
    claims: dict[str, Any] = {
        "iss": "iss-test",
        "aud": "aud-test",
        "sub": str(USER),
        "sid": str(SESSION),
        "iat": iat,
        "exp": iat + 900,
        "jti": "j1",
    }
    claims.update(overrides)
    return {k: v for k, v in claims.items() if v is not None}


def _sign(claims: dict[str, Any], *, key: Ed25519PrivateKey = KEY, kid: str = "k1") -> str:
    return jwt.encode(claims, key, algorithm="EdDSA", headers={"kid": kid})


def test_issue_and_decode_round_trip() -> None:
    svc = service()
    issued = svc.issue(user_id=USER, session_id=SESSION, now=T0)
    assert issued.expires_at == T0 + timedelta(seconds=900)
    header = jwt.get_unverified_header(issued.token)
    assert header["alg"] == "EdDSA"
    assert header["kid"] == "k1"
    claims = svc.decode(issued.token, now=T0 + timedelta(seconds=899))
    assert (claims.user_id, claims.session_id) == (USER, SESSION)
    assert claims.expires_at - claims.issued_at == 900


def test_expiry_uses_the_supplied_clock_not_the_host_clock() -> None:
    svc = service()
    token = svc.issue(user_id=USER, session_id=SESSION, now=T0).token
    with pytest.raises(TokenExpired):
        svc.decode(token, now=T0 + timedelta(seconds=900))
    # The supplied clock decides, whatever the host's wall clock says.
    svc.decode(token, now=T0)


@pytest.mark.parametrize(
    "issued_at",
    [datetime(2001, 1, 1, 9, 0, tzinfo=UTC), datetime(2099, 1, 1, 9, 0, tzinfo=UTC)],
    ids=["far-past", "far-future"],
)
def test_validity_follows_the_supplied_clock_far_from_the_host_clock(issued_at: datetime) -> None:
    """A token issued in 2001 is long expired by the host clock, one issued in 2099 is not yet
    issued by it; both must behave identically under the injected clock. This fails if PyJWT's
    own exp or iat checks (which read the wall clock) are ever switched on."""
    svc = service()
    token = svc.issue(user_id=USER, session_id=SESSION, now=issued_at).token
    claims = svc.decode(token, now=issued_at + timedelta(seconds=899))
    assert claims.user_id == USER
    with pytest.raises(TokenExpired):
        svc.decode(token, now=issued_at + timedelta(seconds=900))


def test_rotation_accepts_old_kid_and_signs_with_active() -> None:
    old = service()
    token = old.issue(user_id=USER, session_id=SESSION, now=T0).token
    rotated = service(signing_keys={"k1": KEY, "k2": OTHER_KEY}, active_kid="k2")
    assert rotated.decode(token, now=T0).user_id == USER
    new_token = rotated.issue(user_id=USER, session_id=SESSION, now=T0).token
    assert jwt.get_unverified_header(new_token)["kid"] == "k2"
    with pytest.raises(Unauthenticated):
        old.decode(new_token, now=T0)


def test_active_kid_must_exist() -> None:
    with pytest.raises(ValueError, match="active kid"):
        service(active_kid="missing")


def test_alg_none_is_rejected() -> None:
    header = _b64(json.dumps({"alg": "none", "kid": "k1", "typ": "JWT"}).encode())
    payload = _b64(json.dumps(_claims()).encode())
    with pytest.raises(Unauthenticated):
        service().decode(f"{header}.{payload}.", now=T0)


def test_hs256_signed_with_public_key_is_rejected() -> None:
    public_pem = KEY.public_key().public_bytes(Encoding.PEM, PublicFormat.SubjectPublicKeyInfo)
    header = _b64(json.dumps({"alg": "HS256", "kid": "k1", "typ": "JWT"}).encode())
    payload = _b64(json.dumps(_claims()).encode())
    signature = hmac.new(public_pem, f"{header}.{payload}".encode(), hashlib.sha256).digest()
    with pytest.raises(Unauthenticated):
        service().decode(f"{header}.{payload}.{_b64(signature)}", now=T0)


def test_eddsa_header_with_hmac_signature_is_rejected() -> None:
    public_pem = KEY.public_key().public_bytes(Encoding.PEM, PublicFormat.SubjectPublicKeyInfo)
    header = _b64(json.dumps({"alg": "EdDSA", "kid": "k1"}).encode())
    payload = _b64(json.dumps(_claims()).encode())
    signature = hmac.new(public_pem, f"{header}.{payload}".encode(), hashlib.sha256).digest()
    with pytest.raises(Unauthenticated):
        service().decode(f"{header}.{payload}.{_b64(signature)}", now=T0)


@pytest.mark.parametrize(
    "token_factory",
    [
        lambda: _sign(_claims(), kid="unknown"),
        lambda: _sign(_claims(), key=OTHER_KEY),
        lambda: jwt.encode(_claims(), KEY, algorithm="EdDSA"),  # no kid
        lambda: _sign(_claims(iss="someone-else")),
        lambda: _sign(_claims(aud="another-app")),
        lambda: _sign(_claims(aud=["aud-test", "another-app"])),
        lambda: _sign(_claims(sub="not-a-uuid")),
        lambda: _sign(_claims(sid="not-a-uuid")),
        lambda: _sign(_claims(exp="soon")),
        lambda: _sign(_claims(iat=True)),
        lambda: _sign(_claims(iat=int(T0.timestamp()) + 3600)),  # issued in the future
        lambda: "not.a.jwt",
        lambda: "garbage",
    ],
)
def test_invalid_tokens_are_unauthenticated(token_factory: Any) -> None:
    with pytest.raises(Unauthenticated):
        service().decode(token_factory(), now=T0)


@pytest.mark.parametrize("missing", ["exp", "iat", "sub", "sid", "iss", "aud", "jti"])
def test_every_claim_is_required(missing: str) -> None:
    token = _sign(_claims(**{missing: None}))
    with pytest.raises(Unauthenticated):
        service().decode(token, now=T0)


def test_tampered_signature_or_payload_is_rejected() -> None:
    token = service().issue(user_id=USER, session_id=SESSION, now=T0).token
    header, payload, signature = token.split(".")
    flipped = signature[:-2] + ("A" if signature[-2] != "A" else "B") + signature[-1]
    with pytest.raises(Unauthenticated):
        service().decode(f"{header}.{payload}.{flipped}", now=T0)
    forged_payload = _b64(json.dumps(_claims(sub=str(uuid.uuid4()))).encode())
    with pytest.raises(Unauthenticated):
        service().decode(f"{header}.{forged_payload}.{signature}", now=T0)


def test_refresh_tokens() -> None:
    first, second = new_refresh_token(), new_refresh_token()
    assert first.startswith("rt_")
    assert first != second
    assert len(first) >= 40
    assert looks_like_refresh_token(first)
    assert not looks_like_refresh_token("xx_" + first)
    assert not looks_like_refresh_token("rt_" + "a" * 200)
    assert hash_refresh_token(first) == hashlib.sha256(first.encode()).digest()
