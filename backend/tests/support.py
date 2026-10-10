"""Test helpers shared by every suite: database URLs, settings, the API harness."""

from __future__ import annotations

import json
import os
import re
import secrets
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx
import psycopg
import pytest
from alembic.config import Config
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat
from fastapi import FastAPI
from psycopg import sql
from psycopg.rows import dict_row

from app.core.clock import FrozenClock
from app.core.config import Settings
from app.notifications.email import RecordingEmailProvider

# --- database --------------------------------------------------------------------------------

PG_HOST = os.environ.get("AFTERME_TEST_PG_HOST", "localhost")
PG_PORT = int(os.environ.get("AFTERME_TEST_PG_PORT", "5432"))
TEST_DB = os.environ.get("AFTERME_TEST_DB_NAME", "afterme_test")
OWNER_PASSWORD = os.environ.get("AFTERME_OWNER_DB_PASSWORD", "afterme_owner_dev")
API_PASSWORD = os.environ.get("AFTERME_API_DB_PASSWORD", "afterme_api_dev")
WORKER_PASSWORD = os.environ.get("AFTERME_WORKER_DB_PASSWORD", "afterme_worker_dev")


def validate_test_db_name(name: str, dev_name: str | None = None) -> str:
    """Return ``name`` if it is safe to TRUNCATE and migrate; raise otherwise.

    The suite empties every Phase 1 table before each test, so it must never point at the
    development database (``afterme_dev`` or whatever ``AFTERME_DEV_DB_NAME`` names).
    """
    if not re.fullmatch(r"[a-z_][a-z0-9_]{0,50}", name):
        msg = "AFTERME_TEST_DB_NAME must be a plain lowercase identifier"
        raise RuntimeError(msg)
    protected = {"afterme_dev", "postgres", "template0", "template1"}
    if dev_name:
        protected.add(dev_name)
    if name in protected:
        msg = (
            f"AFTERME_TEST_DB_NAME={name!r} is a protected database: the tests TRUNCATE every "
            "table. Use a dedicated name such as afterme_test."
        )
        raise RuntimeError(msg)
    return name


validate_test_db_name(TEST_DB, os.environ.get("AFTERME_DEV_DB_NAME"))


def sqlalchemy_url(user: str, password: str, database: str = TEST_DB) -> str:
    return f"postgresql+psycopg://{user}:{password}@{PG_HOST}:{PG_PORT}/{database}"


def conninfo(user: str, password: str, database: str = TEST_DB) -> str:
    return psycopg.conninfo.make_conninfo(
        host=PG_HOST, port=PG_PORT, user=user, password=password, dbname=database
    )


OWNER_URL = sqlalchemy_url("afterme_owner", OWNER_PASSWORD)
API_URL = sqlalchemy_url("afterme_api", API_PASSWORD)
WORKER_URL = sqlalchemy_url("afterme_worker", WORKER_PASSWORD)


@contextmanager
def connect(
    user: str = "afterme_owner", password: str = OWNER_PASSWORD, database: str = TEST_DB
) -> Iterator[psycopg.Connection[dict[str, Any]]]:
    with psycopg.connect(
        conninfo(user, password, database), autocommit=True, row_factory=dict_row
    ) as conn:
        yield conn


BACKEND_DIR = Path(__file__).resolve().parents[1]


def alembic_config(url: str) -> Config:
    cfg = Config(str(BACKEND_DIR / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND_DIR / "migrations"))
    cfg.set_main_option("sqlalchemy.url", url)
    cfg.attributes["configure_logger"] = False
    return cfg


def ensure_database(name: str) -> None:
    """Create ``name`` as afterme_owner if missing, with the same hardening as dev_db_setup.sh."""
    try:
        with connect(database="postgres") as admin:
            exists = admin.execute(
                "SELECT 1 FROM pg_database WHERE datname = %s", (name,)
            ).fetchone()
            if exists is None:
                admin.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(name)))
    except psycopg.OperationalError as exc:  # pragma: no cover - environment problem
        pytest.exit(
            f"Cannot reach PostgreSQL as afterme_owner ({type(exc).__name__}). "
            "Run backend/scripts/dev_db_setup.sh first.",
            returncode=2,
        )
    with connect(database=name) as conn:
        db = sql.Identifier(name)
        conn.execute(sql.SQL("REVOKE TEMPORARY ON DATABASE {} FROM PUBLIC").format(db))
        conn.execute(
            sql.SQL("GRANT CONNECT ON DATABASE {} TO afterme_api, afterme_worker").format(db)
        )
        try:
            # Works when afterme_owner owns schema public (PostgreSQL 15+, or dev_db_setup.sh).
            conn.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
            conn.execute(
                "GRANT USAGE ON SCHEMA public TO afterme_api, afterme_worker, "
                "afterme_maintenance, afterme_readonly"
            )
        except psycopg.errors.InsufficientPrivilege:  # pragma: no cover - PG14 without setup
            pytest.exit(
                f"Database {name!r} was created by afterme_owner, which cannot lock down schema "
                "public on PostgreSQL 14 (the schema belongs to the bootstrap superuser). Create "
                f"it with: AFTERME_TEST_DB_NAME={name} backend/scripts/dev_db_setup.sh",
                returncode=2,
            )


# --- settings ---------------------------------------------------------------------------------

_JWT_KEY_PEM = (
    Ed25519PrivateKey.generate()
    .private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
    .decode()
)
TEST_KID = "test-kid-1"
TEST_PEPPER = secrets.token_urlsafe(48)
TEST_ISSUER = "afterme-test"
TEST_AUDIENCE = "afterme-app-test"
PUBLIC_BASE_URL = "https://afterme.test"


def make_settings(**overrides: Any) -> Settings:
    values: dict[str, Any] = {
        "app_env": "test",
        "database_url": API_URL,
        "worker_database_url": WORKER_URL,
        "migration_database_url": OWNER_URL,
        "db_pool_size": 5,
        "jwt_signing_keys": {TEST_KID: _JWT_KEY_PEM},
        "jwt_active_kid": TEST_KID,
        "jwt_issuer": TEST_ISSUER,
        "jwt_audience": TEST_AUDIENCE,
        "hmac_pepper": TEST_PEPPER,
        "email_provider": "recording",
        "argon2_time_cost": 1,
        "argon2_memory_cost_kib": 1024,
        "argon2_parallelism": 1,
        "public_base_url": PUBLIC_BASE_URL,
        "api_base_url": "https://api.afterme.test",
        "rate_limit_enabled": True,
    }
    values.update(overrides)
    return Settings(**values)


def jwt_private_key_pem() -> str:
    return _JWT_KEY_PEM


# --- API harness ------------------------------------------------------------------------------

T0 = datetime(2026, 10, 8, 9, 0, 0, tzinfo=UTC)
PASSWORD = "correct horse battery staple"
DEVICE: dict[str, str] = {
    "platform": "android",
    "app_version": "1.0.0+12",
    "os_version": "15",
    "locale": "en-IN",
}
CLIENT_IP = "203.0.113.10"
_CODE_RE = re.compile(r"\b(\d{6})\b")
_RESET_LINK_RE = re.compile(r"https://afterme\.test/a/reset#(pr_[A-Za-z0-9_-]+)")
NEW_PASSWORD = "a brand new passphrase 77"
_INVITE_LINK_RE = re.compile(r"https://afterme\.test/c/open#(ci_[A-Za-z0-9_-]+)")
_OPTOUT_LINK_RE = re.compile(r"https://afterme\.test/c/optout#(oo_[A-Za-z0-9_.-]+)")
_CSRF_FIELD_RE = re.compile(r'name="csrf" value="([^"]+)"')


@dataclass
class Harness:
    app: FastAPI
    client: httpx.AsyncClient
    mail: RecordingEmailProvider
    clock: FrozenClock
    settings: Settings
    created: list[dict[str, Any]] = field(default_factory=list)

    async def register(
        self, email: str, password: str = PASSWORD, display_name: str = "Test User", **extra: Any
    ) -> httpx.Response:
        body = {
            "email": email,
            "password": password,
            "display_name": display_name,
            "timezone": "Asia/Kolkata",
            "locale": "en",
            **extra,
        }
        return await self.client.post("/v1/auth/register/start", json=body)

    def code_for(self, email: str) -> str:
        messages = self.mail.to(email, "signup_code")
        assert messages, f"no signup code sent to {email}"
        match = _CODE_RE.search(messages[-1].text)
        assert match is not None
        return match[1]

    async def verify(
        self, email: str, code: str, password: str = PASSWORD, **extra: Any
    ) -> httpx.Response:
        body = {"email": email, "code": code, "password": password, "device": DEVICE, **extra}
        return await self.client.post("/v1/auth/register/verify", json=body)

    async def signup(self, email: str, password: str = PASSWORD) -> dict[str, Any]:
        response = await self.register(email, password)
        assert response.status_code == 202, response.text
        verified = await self.verify(email, self.code_for(email), password)
        assert verified.status_code == 201, verified.text
        tokens: dict[str, Any] = verified.json()
        self.created.append(tokens)
        return tokens

    async def login(
        self,
        email: str,
        password: str = PASSWORD,
        device_id: str | None = None,
        headers: dict[str, str] | None = None,
    ) -> httpx.Response:
        device = {**DEVICE, **({"id": device_id} if device_id else {})}
        return await self.client.post(
            "/v1/auth/login",
            json={"email": email, "password": password, "device": device},
            headers=headers,
        )

    async def relogin(self, email: str, password: str = PASSWORD) -> dict[str, Any]:
        """Fresh tokens after the test moved the clock past the access token's lifetime."""
        response = await self.login(email, password)
        assert response.status_code == 200, response.text
        tokens: dict[str, Any] = response.json()
        return tokens

    async def refresh(self, refresh_token: str) -> httpx.Response:
        return await self.client.post("/v1/auth/refresh", json={"refresh_token": refresh_token})

    async def forgot(self, email: str) -> httpx.Response:
        return await self.client.post("/v1/auth/password/forgot", json={"email": email})

    def reset_token_for(self, email: str, index: int = -1) -> str:
        """The token in the newest (or ``index``-th) password-reset email sent to ``email``."""
        messages = self.mail.to(email, "password_reset_link")
        assert messages, f"no reset link sent to {email}"
        match = _RESET_LINK_RE.search(messages[index].text)
        assert match is not None, "reset email carries no link"
        return match[1]

    async def web_form(self) -> str:
        """GET /a/reset (sets the CSRF cookie in the client's jar); returns the CSRF value."""
        response = await self.client.get("/a/reset")
        assert response.status_code == 200
        match = re.search(r'name="csrf" value="([^"]+)"', response.text)
        assert match is not None
        return match[1]

    async def web_reset(
        self, token: str, new_password: str, csrf: str | None = None
    ) -> httpx.Response:
        """Submit the reset form like a browser: fetch the form first unless ``csrf`` is given."""
        value = csrf if csrf is not None else await self.web_form()
        return await self.client.post(
            "/a/reset", data={"token": token, "new_password": new_password, "csrf": value}
        )

    # --- trusted contacts ---------------------------------------------------------------------

    async def add_contact(
        self, tokens: dict[str, Any] | str, email: str, name: str = "Mom", **extra: Any
    ) -> httpx.Response:
        body = {"display_name": name, "relationship": "mother", "email": email, **extra}
        return await self.client.post("/v1/contacts", json=body, headers=bearer(tokens))

    def invitation_token_for(self, email: str, index: int = -1) -> str:
        """The ``ci_`` token in the newest (or ``index``-th) invitation mailed to ``email``."""
        messages = self.mail.to(email, "contact_invitation")
        assert messages, f"no invitation sent to {email}"
        match = _INVITE_LINK_RE.search(messages[index].text)
        assert match is not None, "invitation carries no accept link"
        return match[1]

    def optout_token_for(self, email: str, index: int = -1) -> str:
        messages = self.mail.to(email, "contact_invitation")
        assert messages, f"no invitation sent to {email}"
        match = _OPTOUT_LINK_RE.search(messages[index].text)
        assert match is not None, "invitation carries no opt-out link"
        return match[1]

    async def portal_csrf(self, path: str = "/c/open") -> str:
        """GET a portal landing page (sets the CSRF cookie in the client's jar)."""
        response = await self.client.get(path)
        assert response.status_code == 200
        match = _CSRF_FIELD_RE.search(response.text)
        assert match is not None
        return match[1]

    async def portal_post(
        self, path: str, token: str, *, csrf: str | None = None, **fields: str
    ) -> httpx.Response:
        """POST a portal form like a browser would: fetch a landing page first for the CSRF
        cookie unless ``csrf`` is given."""
        value = csrf if csrf is not None else await self.portal_csrf()
        return await self.client.post(path, data={"token": token, "csrf": value, **fields})

    # --- escalation plan ----------------------------------------------------------------------

    async def plan_for_contacts(
        self,
        tokens: dict[str, Any] | str,
        *,
        grace: int = 180,
        later: tuple[tuple[int, list[str]], ...] = (),
    ) -> dict[str, Any]:
        """Save a plan whose first stage (at the end of ``grace``) notifies every contact that is
        switched on, plus optional ``later`` stages as ``(offset_minutes, contact_ids)``."""
        contacts = (await self.client.get("/v1/contacts", headers=bearer(tokens))).json()["items"]
        ids = [c["id"] for c in contacts if c["is_active"]]
        current = await self.client.get("/v1/plan", headers=bearer(tokens))
        assert current.status_code == 200, current.text
        existing = current.json()["stages"]
        stages: list[dict[str, Any]] = [
            {
                "id": existing[0]["id"] if existing else None,
                "offset_minutes": grace,
                "notify_contact_ids": ids,
            }
        ]
        for index, (offset, contact_ids) in enumerate(later, start=1):
            stages.append(
                {
                    "id": existing[index]["id"] if index < len(existing) else None,
                    "offset_minutes": offset,
                    "notify_contact_ids": contact_ids,
                }
            )
        response = await self.client.put(
            "/v1/plan",
            json={"grace_minutes": grace, "stages": stages},
            headers={**bearer(tokens), "If-Match": current.headers["etag"]},
        )
        assert response.status_code == 200, response.text
        saved: dict[str, Any] = response.json()
        return saved

    async def reauth(self, tokens: dict[str, Any], password: str = PASSWORD) -> httpx.Response:
        return await self.client.post(
            "/v1/auth/reauth", json={"password": password}, headers=bearer(tokens)
        )


def bearer(tokens: dict[str, Any] | str) -> dict[str, str]:
    token = tokens if isinstance(tokens, str) else tokens["access_token"]
    return {"Authorization": f"Bearer {token}"}


def problem(response: httpx.Response) -> dict[str, Any]:
    assert response.headers["content-type"].startswith("application/problem+json"), response.text
    body: dict[str, Any] = response.json()
    assert {"type", "title", "status", "code", "detail", "request_id"} <= body.keys()
    assert body["status"] == response.status_code
    assert body["type"] == f"{PUBLIC_BASE_URL}/problems/{body['code'].replace('_', '-')}"
    return body


async def asgi_post_events(
    h: Harness,
    monkeypatch: pytest.MonkeyPatch,
    path: str,
    body: dict[str, Any],
    headers: dict[str, str],
) -> list[str]:
    """Drive one POST through the raw ASGI interface and record when the mailer is invoked
    relative to the final response body chunk (httpx's transport would hide the order)."""
    events: list[str] = []
    mailer = h.app.state.services.mailer
    real_deliver = mailer.deliver

    async def deliver(messages: Any) -> None:
        events.append("deliver")
        await real_deliver(messages)

    monkeypatch.setattr(mailer, "deliver", deliver)
    payload = json.dumps(body).encode()
    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": "POST",
        "scheme": "https",
        "path": path,
        "raw_path": path.encode(),
        "query_string": b"",
        "root_path": "",
        "headers": [
            (b"host", b"api.afterme.test"),
            (b"content-type", b"application/json"),
            (b"content-length", str(len(payload)).encode()),
            *[(k.lower().encode(), v.encode()) for k, v in headers.items()],
        ],
        "client": ("203.0.113.10", 51000),
        "server": ("api.afterme.test", 443),
    }
    sent_request = False

    async def receive() -> dict[str, Any]:
        nonlocal sent_request
        if not sent_request:
            sent_request = True
            return {"type": "http.request", "body": payload, "more_body": False}
        return {"type": "http.disconnect"}

    async def send(message: dict[str, Any]) -> None:
        if message["type"] == "http.response.start":
            events.append(f"status_{message['status']}")
        if message["type"] == "http.response.body" and not message.get("more_body", False):
            events.append("response_end")

    await h.app(scope, receive, send)
    assert "status_202" in events, events
    assert "deliver" in events, events
    return events


def make_premium(owner_db: psycopg.Connection[dict[str, Any]], email: str) -> None:
    owner_db.execute("UPDATE users SET tier = 'premium' WHERE email_normalized = %s", (email,))


def seed_contacts(
    owner_db: psycopg.Connection[dict[str, Any]], user_id: str, count: int, prefix: str = "seed"
) -> None:
    """Insert ``count`` live contacts directly (bypassing the daily creation limits)."""
    for n in range(count):
        owner_db.execute(
            "INSERT INTO trusted_contacts (user_id, display_name, relationship, email, "
            "email_normalized, priority) VALUES (%s, %s, 'friend', %s, %s, %s)",
            (user_id, f"Seed {n}", f"{prefix}{n}@example.com", f"{prefix}{n}@example.com", n + 1),
        )


def rows(owner_db: psycopg.Connection[dict[str, Any]], query: str, *params: Any) -> list[Any]:
    return list(owner_db.execute(query, params).fetchall())  # type: ignore[arg-type]
