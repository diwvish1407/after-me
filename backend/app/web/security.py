"""Headers, nonces and CSRF for the server-rendered pages (SECURITY §12; API_SPEC §13).

* Every page carries a strict Content-Security-Policy with a fresh nonce per response, no
  referrer, no caching, no indexing and no framing.
* CSRF uses the double-submit pattern: a random value in a ``__Host-`` cookie (Secure, HttpOnly,
  SameSite=Strict, Path=/) and the same value in a hidden form field. A cross-site page can
  neither read nor set the cookie, so it cannot produce a matching pair.
"""

from __future__ import annotations

import hmac
import re
import secrets
from typing import Final

CSRF_COOKIE: Final = "__Host-afterme_csrf"
_CSRF_RE: Final = re.compile(r"^[A-Za-z0-9_-]{32,128}$")


def new_nonce() -> str:
    return secrets.token_urlsafe(16)


def new_csrf_value() -> str:
    return secrets.token_urlsafe(32)


def well_formed_csrf(value: str | None) -> str | None:
    """``value`` when it has the shape this server issues, else ``None``."""
    return value if value is not None and _CSRF_RE.fullmatch(value) else None


def csrf_matches(cookie: str | None, field: str | None) -> bool:
    """Constant-time comparison of the cookie and the form field; both must be present."""
    expected = well_formed_csrf(cookie)
    if expected is None or not field:
        return False
    return hmac.compare_digest(expected.encode(), field.encode())


def content_security_policy(nonce: str) -> str:
    return (
        "default-src 'none'; "
        f"script-src 'nonce-{nonce}'; "
        "style-src 'self'; "
        "img-src 'self'; "
        "form-action 'self'; "
        "frame-ancestors 'none'; "
        "base-uri 'none'"
    )


def page_headers(nonce: str) -> dict[str, str]:
    """Headers for every HTML page; ``nonce`` is the one used in the page's script tag."""
    return {
        "Content-Security-Policy": content_security_policy(nonce),
        "Referrer-Policy": "no-referrer",
        "Cache-Control": "no-store",
        "X-Robots-Tag": "noindex, nofollow",
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
        "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
    }
