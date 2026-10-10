"""Invitation and opt-out tokens for trusted contacts (SECURITY §6.3, §12; API_SPEC §13.1).

* Invitation token ``ci_`` + 256 bits of CSPRNG output (URL-safe). Only its SHA-256 is stored
  (``contact_verifications.token_hash``); it is valid for 14 days and can be answered once.
* Opt-out token ``oo_<contact_id>.<mac>``: stateless and never expiring, so the *Don't want these
  emails?* link in an old message keeps working. ``mac`` is HMAC-SHA256(pepper, contact id and
  normalised address) under the ``contact_optout`` context, verified in constant time against the
  current and (during rotation) the previous pepper. It proves the link was issued by this server
  for that contact *and the address it then held*: when the account holder corrects the address
  (a typo that reached a stranger, say), the stranger's old link stops working instead of opting
  out, or globally suppressing, the contact's new, correct address.

Both travel in the URL *fragment* (``/c/open#ci_...``, ``/c/optout#oo_...``), so they never reach
a server, proxy or load-balancer log; they reach the application only in POST bodies.
"""

from __future__ import annotations

import base64
import re
import secrets
import uuid
from datetime import timedelta
from typing import Final

from app.security.hashing import Pepper, sha256

CONSENT_TEXT_VERSION: Final = "2026-10-v1"
INVITATION_TTL: Final = timedelta(days=14)

INVITATION_PREFIX: Final = "ci_"
OPTOUT_PREFIX: Final = "oo_"
_OPTOUT_CONTEXT: Final = "contact_optout"

# token_urlsafe(32) is 43 characters of [A-Za-z0-9_-].
_INVITATION_RE: Final = re.compile(r"^ci_[A-Za-z0-9_-]{43}$")
_OPTOUT_RE: Final = re.compile(
    r"^oo_(?P<id>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
    r"\.(?P<mac>[A-Za-z0-9_-]{43})$"
)


def new_invitation_token() -> str:
    return INVITATION_PREFIX + secrets.token_urlsafe(32)


def hash_invitation_token(token: str) -> bytes:
    return sha256(token)


def looks_like_invitation_token(token: str) -> bool:
    """Cheap shape check before touching the database; no secret comparison happens here."""
    return _INVITATION_RE.fullmatch(token) is not None


def invitation_link(public_base_url: str, token: str) -> str:
    return f"{public_base_url}/c/open#{token}"


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _unb64(text: str) -> bytes | None:
    try:
        return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    except ValueError:  # pragma: no cover - the regex already limits the alphabet
        return None


def new_optout_token(pepper: Pepper, contact_id: uuid.UUID, email_normalized: str) -> str:
    mac = pepper.hmac(_OPTOUT_CONTEXT, str(contact_id), email_normalized)
    return f"{OPTOUT_PREFIX}{contact_id}.{_b64(mac)}"


def optout_link(public_base_url: str, token: str) -> str:
    return f"{public_base_url}/c/optout#{token}"


def optout_token_contact_id(token: str) -> uuid.UUID | None:
    """The contact ID a well-formed opt-out token names. This is only a lookup key: nothing is
    authenticated until :func:`verify_optout_token` has checked the MAC against the address the
    contact holds now."""
    match = _OPTOUT_RE.fullmatch(token)
    return None if match is None else uuid.UUID(match["id"])


def verify_optout_token(pepper: Pepper, token: str, *, email_normalized: str) -> uuid.UUID | None:
    """The contact ID the token was issued for, or ``None`` for anything malformed, forged, issued
    for a different contact (the MAC covers the ID) or for an address the contact no longer
    holds (the MAC covers the address)."""
    match = _OPTOUT_RE.fullmatch(token)
    if match is None:
        return None
    presented = _unb64(match["mac"])
    # Only the canonical spelling of a MAC is accepted: the last base64 character carries unused
    # bits, so two spellings would decode to the same bytes.
    if presented is None or _b64(presented) != match["mac"]:
        return None
    contact_id = uuid.UUID(match["id"])
    if not pepper.verify(presented, _OPTOUT_CONTEXT, str(contact_id), email_normalized):
        return None
    return contact_id


def suppression_hash(pepper: Pepper, email_normalized: str) -> bytes:
    """What is stored in ``email_suppressions.email_hash`` (current pepper)."""
    return pepper.hmac("email_suppression", email_normalized)


def suppression_hash_candidates(pepper: Pepper, email_normalized: str) -> list[bytes]:
    """Hashes to look up: also the previous pepper's, so a rotation never un-suppresses."""
    return pepper.candidates("email_suppression", email_normalized)
