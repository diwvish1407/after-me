"""Shared machinery of the golden contract tests (``docs/contracts/phaseN``).

A scenario drives the API through the :class:`Recorder`, which keeps scrubbed copies of every
request and response body (random IDs, tokens, codes and request IDs become fixed placeholders).
The scenario's test compares the result with the committed files, so the API and the mobile app
(which parses the same files) cannot drift apart unnoticed.
"""

from __future__ import annotations

import base64
import json
import re
from dataclasses import dataclass, field
from typing import Any

import httpx

from tests.support import Harness, bearer

_UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def _b64(value: dict[str, Any]) -> str:
    raw = json.dumps(value, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _fake_access_token(n: int) -> str:
    header = _b64({"alg": "EdDSA", "typ": "JWT", "kid": "example-key"})
    claims = _b64({"sub": "example-user", "sid": f"example-session-{n}"})
    signature = base64.urlsafe_b64encode(f"example-signature-{n}".encode()).rstrip(b"=").decode()
    return f"{header}.{claims}.{signature}"


@dataclass
class Recorder:
    """Calls the API and keeps scrubbed copies of what went over the wire."""

    h: Harness
    contract: str = "afterme-phase2"
    notes: tuple[str, ...] = ()
    files: dict[str, str] = field(default_factory=dict)
    endpoints: list[dict[str, Any]] = field(default_factory=list)
    problems: list[dict[str, Any]] = field(default_factory=list)
    _uuids: dict[str, str] = field(default_factory=dict)
    _literals: dict[str, str] = field(default_factory=dict)
    _tokens: dict[str, str] = field(default_factory=dict)

    # --- scrubbing --------------------------------------------------------------------------

    def literal(self, real: str, placeholder: str) -> None:
        self._literals[real] = placeholder

    def _token(self, kind: str, value: str) -> str:
        key = f"{kind}:{value}"
        if key not in self._tokens:
            n = sum(1 for k in self._tokens if k.startswith(f"{kind}:")) + 1
            self._tokens[key] = (
                _fake_access_token(n) if kind == "access" else f"rt_example-refresh-token-{n:02d}"
            )
        return self._tokens[key]

    def _uuid(self, match: re.Match[str]) -> str:
        real = match.group(0)
        if real not in self._uuids:
            self._uuids[real] = f"00000000-0000-4000-8000-{len(self._uuids) + 1:012d}"
        return self._uuids[real]

    def _scrub_string(self, value: str, key: str | None) -> str:
        fixed = {
            "request_id": "req_0123456789abcdef0123456789abcdef",
            "next_cursor": "cursor_example_0001",
        }
        if key == "access_token":
            return self._token("access", value)
        if key == "refresh_token":
            return self._token("refresh", value)
        if key in fixed:
            return fixed[key]
        if value in self._literals:
            return self._literals[value]
        return _UUID_RE.sub(self._uuid, value)

    def scrub(self, value: Any, key: str | None = None) -> Any:
        if isinstance(value, dict):
            return {k: self.scrub(v, k) for k, v in value.items()}
        if isinstance(value, list):
            return [self.scrub(v) for v in value]
        if isinstance(value, str):
            return self._scrub_string(value, key)
        return value

    @staticmethod
    def _dump(value: Any) -> str:
        return json.dumps(value, indent=2, ensure_ascii=False) + "\n"

    # --- calls ------------------------------------------------------------------------------

    async def call(
        self,
        name: str,
        method: str,
        path: str,
        *,
        status: int,
        json_body: Any = None,
        tokens: dict[str, Any] | str | None = None,
        auth: str = "public",
        template: str | None = None,
        problem: bool = False,
        headers: dict[str, str] | None = None,
        record_headers: tuple[str, ...] = ("ETag",),
    ) -> httpx.Response:
        """``headers`` are extra request headers (``If-Match``, ``Idempotency-Key``); they and the
        response headers named in ``record_headers`` are written to the index so the mobile app
        can assert them. The Authorization header is never recorded."""
        assert (tokens is None) == (auth == "public"), f"{name}: auth label disagrees with request"
        sent = {**(bearer(tokens) if tokens is not None else {}), **(headers or {})}
        response = await self.h.client.request(method, path, json=json_body, headers=sent or None)
        assert response.status_code == status, f"{name}: {response.status_code} {response.text}"

        request_file = response_file = None
        if json_body is not None:
            request_file = f"{name}.request.json"
            self.files[request_file] = self._dump(self.scrub(json_body))
        if response.content:
            response_file = f"{name}.response.json"
            self.files[response_file] = self._dump(self.scrub(response.json()))
        entry = {
            "name": name,
            "method": method,
            "path": template or path,
            "auth": auth,
            "status": status,
            "request": request_file,
            "response": response_file,
        }
        if headers:
            entry["request_headers"] = {k: self.scrub(v) for k, v in headers.items()}
        seen = {h: response.headers[h] for h in record_headers if h in response.headers}
        if seen:
            entry["response_headers"] = {k: self.scrub(v) for k, v in seen.items()}
        (self.problems if problem else self.endpoints).append(entry)
        return response

    def index(self) -> str:
        return self._dump(
            {
                "contract": self.contract,
                "base_path": "/v1",
                "notes": list(self.notes),
                "endpoints": self.endpoints,
                "problems": self.problems,
            }
        )
