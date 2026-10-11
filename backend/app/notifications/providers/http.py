"""Shared HTTP plumbing for the provider adapters."""

from __future__ import annotations

from typing import Final

import httpx

from app.notifications.errors import ProviderError, TransientProviderError

# A provider that does not answer within this long is treated as down for this message. The
# dispatcher calls providers outside any transaction, so a slow one never holds a lock.
CONNECT_TIMEOUT: Final = 5.0
TOTAL_TIMEOUT: Final = 15.0
MAX_RETRY_AFTER: Final = 3_600.0


def new_client(transport: httpx.AsyncBaseTransport | None = None) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        timeout=httpx.Timeout(TOTAL_TIMEOUT, connect=CONNECT_TIMEOUT),
        transport=transport,
        follow_redirects=False,
    )


def retry_after(response: httpx.Response) -> float | None:
    """``Retry-After`` in seconds (the delta form only), capped; ``None`` when absent."""
    raw = response.headers.get("retry-after")
    if raw is None:
        return None
    try:
        return min(max(float(raw), 0.0), MAX_RETRY_AFTER)
    except ValueError:
        return None


async def post(client: httpx.AsyncClient, url: str, **kwargs: object) -> httpx.Response:
    """POST, with every transport failure turned into a transient provider error. The URL is
    never put in the error (it can carry an address or a key)."""
    try:
        return await client.post(url, **kwargs)  # type: ignore[arg-type]
    except httpx.TimeoutException:
        raise TransientProviderError("timeout") from None
    except httpx.HTTPError as exc:
        raise TransientProviderError(f"network_{type(exc).__name__}"[:48]) from None


def server_error(response: httpx.Response, code: str) -> ProviderError:
    return TransientProviderError(code, retry_after=retry_after(response))
