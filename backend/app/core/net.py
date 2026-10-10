"""Client IP extraction.

``X-Forwarded-For`` is trusted only through the configured number of proxy hops. Each trusted
proxy appends the address it received the connection from, so with ``N`` trusted hops the client
is the ``N``-th entry from the right. Anything further left was written by the client and is
ignored. With ``N = 0`` the header is ignored entirely and the socket peer is used.

Raw IPs are never stored: callers keep only ``Pepper.ip_hash(ip)``.
"""

from __future__ import annotations

import ipaddress

from starlette.types import Scope

UNKNOWN_IP = "0.0.0.0"  # noqa: S104 - a placeholder value, never bound


def _valid_ip(value: str) -> str | None:
    try:
        return str(ipaddress.ip_address(value.strip()))
    except ValueError:
        return None


def rate_limit_subject(ip: str) -> str:
    """Key per-IP limits on the network, not the address: an IPv6 client controls a whole /64,
    so a full-address key would let it dodge limits by rotating addresses."""
    try:
        address = ipaddress.ip_address(ip)
    except ValueError:
        return ip
    if isinstance(address, ipaddress.IPv6Address):
        return str(ipaddress.ip_network(f"{address}/64", strict=False))
    return ip


def client_ip(scope: Scope, trusted_proxy_hops: int) -> str:
    peer = scope.get("client")
    peer_ip = _valid_ip(peer[0]) if peer else None
    fallback = peer_ip or UNKNOWN_IP
    if trusted_proxy_hops <= 0:
        return fallback

    forwarded: list[str] = []
    for name, value in scope.get("headers", []):
        if name == b"x-forwarded-for":
            forwarded.extend(
                part.strip() for part in value.decode("latin-1").split(",") if part.strip()
            )
    if not forwarded:
        return fallback
    index = max(len(forwarded) - trusted_proxy_hops, 0)
    return _valid_ip(forwarded[index]) or fallback
