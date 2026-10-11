"""What can go wrong when a message is handed to a provider (ESCALATION_ENGINE §8.3).

The dispatcher decides by the *kind* of failure, never by parsing a message:

* :class:`TransientProviderError`: try again later (a timeout, ``429``, ``5xx``). Retried with
  backoff; the message is given up on after 24 hours.
* :class:`ProviderUnavailableError`: the provider as a whole cannot be used right now (bad
  credentials, a suspended account, the sending domain not verified). A transient failure for
  the message, and the reason a fallback provider takes over.
* :class:`PermanentDeliveryError`: *this* message cannot be delivered by anyone (an address that
  does not exist, an inactive recipient). Never retried.
* :class:`InvalidPushTokenError`: the phone's registration is gone (app uninstalled). The token is
  removed and the message dropped; the same reminder still goes out by email.

``code`` is a short provider code, safe to log and to store: never an address, a token or text.
"""

from __future__ import annotations


class ProviderError(Exception):
    def __init__(self, code: str, *, retry_after: float | None = None) -> None:
        super().__init__(code)
        self.code = code
        self.retry_after = retry_after


class TransientProviderError(ProviderError):
    """Try again later."""


class ProviderUnavailableError(TransientProviderError):
    """The provider cannot be used at all right now: a fallback may take over."""


class PermanentDeliveryError(ProviderError):
    """This message will never be delivered; do not retry."""


class InvalidPushTokenError(PermanentDeliveryError):
    """The registration token is no longer valid."""
