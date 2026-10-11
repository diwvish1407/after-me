"""A primary email provider with a fallback (FR-NOT-06; OPS-03).

The fallback takes over only when the *provider* cannot be used (credentials refused, the
account suspended, an outage: :class:`ProviderUnavailableError`, a timeout, a ``5xx``), never
because one message was refused: a recipient that does not exist is no better at another
provider. A provider that has just failed is skipped for a short while, so a down provider costs
one timeout, not one per message.

Delivery stays at-least-once: if the primary accepted a message and the answer was lost, the
fallback sends it again. For an alert, a duplicate is the right mistake.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import Final

from app.core.logging import get_logger
from app.notifications.email import EmailMessage, EmailProvider, ProviderResult
from app.notifications.errors import PermanentDeliveryError, TransientProviderError

_log = get_logger("afterme.email")

COOL_DOWN_SECONDS: Final = 60.0
FAILURES_BEFORE_SKIP: Final = 2


class FallbackEmailProvider:
    def __init__(
        self,
        primary: EmailProvider,
        fallback: EmailProvider,
        *,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._providers = (primary, fallback)
        self._failures = [0, 0]
        self._skip_until = [0.0, 0.0]
        self._clock = clock
        self.name = primary.name

    def _order(self) -> list[int]:
        now = self._clock()
        available = [i for i in (0, 1) if self._skip_until[i] <= now]
        # Everything is cooling down: try them all rather than send nothing.
        return available or [0, 1]

    async def send(self, msg: EmailMessage, *, idempotency_key: str) -> ProviderResult:
        last: Exception | None = None
        refused: PermanentDeliveryError | None = None
        for index in self._order():
            provider = self._providers[index]
            try:
                result = await provider.send(msg, idempotency_key=idempotency_key)
            except PermanentDeliveryError as exc:
                # One provider's "this recipient will never work" is its own list (a bounce of
                # other mail, a manual deactivation, an address it cannot encode). The other
                # provider may deliver: only when every provider refused is it final.
                refused = refused or exc
                _log.warning("email.recipient_refused", provider=provider.name, code=exc.code)
                continue
            except Exception as exc:
                last = exc
                self._failures[index] += 1
                if self._failures[index] >= FAILURES_BEFORE_SKIP:
                    self._skip_until[index] = self._clock() + COOL_DOWN_SECONDS
                _log.warning(
                    "email.provider_failed",
                    provider=provider.name,
                    error_class=type(exc).__name__,
                    code=getattr(exc, "code", ""),
                )
                continue
            self._failures[index] = 0
            self._skip_until[index] = 0.0
            if index != 0:
                _log.warning("email.fallback_used", provider=provider.name)
            return result
        if refused is not None and last is None:
            raise refused  # every provider that was asked refused this recipient
        if isinstance(last, TransientProviderError):
            raise last
        raise TransientProviderError("all_providers_failed") from last

    @property
    def degraded(self) -> bool:
        """The primary is being skipped (the page "email provider degraded")."""
        return self._skip_until[0] > self._clock()
