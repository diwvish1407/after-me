"""The provider adapters against a mocked HTTP transport (TEST_PLAN NOT-01…15).

No network: ``httpx.MockTransport`` plays the provider. What matters here is the *kind* of
failure each answer becomes, because the dispatcher decides by kind alone.
"""

from __future__ import annotations

import json
import smtplib
from collections.abc import Callable
from typing import Any, ClassVar

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from app.notifications.email import EmailMessage
from app.notifications.errors import (
    InvalidPushTokenError,
    PermanentDeliveryError,
    ProviderUnavailableError,
    TransientProviderError,
)
from app.notifications.providers.fcm import (
    FcmPushProvider,
    MetadataServerTokens,
    ServiceAccountTokens,
    fcm_payload,
    load_service_account,
)
from app.notifications.providers.postmark import PostmarkEmailProvider
from app.notifications.providers.resend import ResendEmailProvider
from app.notifications.providers.smtp import SmtpEmailProvider
from app.notifications.push import PushMessage

pytestmark = pytest.mark.no_db

Handler = Callable[[httpx.Request], httpx.Response]


def client(handler: Handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


MESSAGE = EmailMessage(
    to="mom@example.com",
    subject="Diwakar hasn't checked in",
    text="Hi Mom,\n\nHe has not.",
    template="contact_alert",
    sender="AfterMe <no-reply@mail.afterme.example>",
    html="<p>Hi Mom,</p>",
)
PUSH = PushMessage(
    token="t" * 40,
    type="incident_missed",
    title="You missed your check-in",
    body="Tap I'M OK to stop the reminders.",
    incident_id="11111111-1111-4111-8111-111111111111",
    channel="reminders",
    ttl_seconds=3600,
)


# --- FCM --------------------------------------------------------------------------------------


class _StaticToken:
    def __init__(self) -> None:
        self.forced = 0

    async def token(self, *, force: bool = False) -> str:
        self.forced += int(force)
        return "access-token-forced" if force else "access-token"


def _fcm_error(status: int, code: str, message: str = "") -> httpx.Response:
    return httpx.Response(
        status,
        json={
            "error": {
                "code": status,
                "status": code,
                "message": message,
                "details": [
                    {
                        "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
                        "errorCode": code,
                    }
                ],
            }
        },
    )


async def test_fcm_sends_the_v1_request_with_a_private_generic_payload() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"name": "projects/afterme-dev/messages/0:1700000000%abc"})

    provider = FcmPushProvider(
        project_id="afterme-dev", tokens=_StaticToken(), client=client(handler)
    )
    result = await provider.send(PUSH, idempotency_key="n-1")
    assert result.provider == "fcm"
    assert result.message_id == "0:1700000000%abc"
    [request] = seen
    assert str(request.url) == "https://fcm.googleapis.com/v1/projects/afterme-dev/messages:send"
    assert request.headers["authorization"] == "Bearer access-token"
    message = json.loads(request.content)["message"]
    assert message["token"] == PUSH.token
    assert message["data"] == {
        "type": "incident_missed",
        "v": "1",
        "incident_id": "11111111-1111-4111-8111-111111111111",
    }
    android = message["android"]
    assert android["priority"] == "HIGH"
    assert android["ttl"] == "3600s"
    assert android["notification"]["channel_id"] == "reminders"
    assert android["notification"]["visibility"] == "PRIVATE"
    assert message["notification"] == {"title": PUSH.title, "body": PUSH.body}
    assert fcm_payload(PUSH)["data"]["type"] == "incident_missed"


@pytest.mark.parametrize(
    ("answer", "expected"),
    [
        (lambda: _fcm_error(404, "UNREGISTERED"), InvalidPushTokenError),
        # a wrong project id (404 NOT_FOUND) or a sender mismatch is OUR configuration: no token
        # may be forgotten because of it
        (lambda: _fcm_error(404, "NOT_FOUND"), ProviderUnavailableError),
        (
            lambda: httpx.Response(404, json={"error": {"status": "NOT_FOUND"}}),
            ProviderUnavailableError,
        ),
        (lambda: httpx.Response(404, text="<html>not found</html>"), ProviderUnavailableError),
        (lambda: _fcm_error(403, "SENDER_ID_MISMATCH"), ProviderUnavailableError),
        (
            lambda: _fcm_error(
                400, "INVALID_ARGUMENT", "The registration token is not a valid FCM token"
            ),
            InvalidPushTokenError,
        ),
        (
            lambda: _fcm_error(400, "INVALID_ARGUMENT", "Invalid JSON payload"),
            PermanentDeliveryError,
        ),
        (lambda: _fcm_error(429, "QUOTA_EXCEEDED"), TransientProviderError),
        (lambda: _fcm_error(503, "UNAVAILABLE"), TransientProviderError),
        (lambda: _fcm_error(500, "INTERNAL"), TransientProviderError),
        (lambda: _fcm_error(403, "PERMISSION_DENIED"), ProviderUnavailableError),
    ],
)
async def test_fcm_answers_become_the_right_kind_of_failure(
    answer: Callable[[], httpx.Response], expected: type[Exception]
) -> None:
    provider = FcmPushProvider(
        project_id="p", tokens=_StaticToken(), client=client(lambda _: answer())
    )
    with pytest.raises(expected):
        await provider.send(PUSH, idempotency_key="n")


async def test_fcm_honours_retry_after_and_refreshes_a_rejected_access_token_once() -> None:
    def limited(_: httpx.Request) -> httpx.Response:
        response = _fcm_error(429, "QUOTA_EXCEEDED")
        response.headers["Retry-After"] = "120"
        return response

    provider = FcmPushProvider(project_id="p", tokens=_StaticToken(), client=client(limited))
    with pytest.raises(TransientProviderError) as excinfo:
        await provider.send(PUSH, idempotency_key="n")
    assert excinfo.value.retry_after == 120

    tokens = _StaticToken()
    calls: list[str] = []

    def unauthenticated(request: httpx.Request) -> httpx.Response:
        calls.append(request.headers["authorization"])
        if len(calls) == 1:
            return _fcm_error(401, "UNAUTHENTICATED")
        return httpx.Response(200, json={"name": "projects/p/messages/1"})

    provider = FcmPushProvider(project_id="p", tokens=tokens, client=client(unauthenticated))
    assert (await provider.send(PUSH, idempotency_key="n")).message_id == "1"
    assert calls == ["Bearer access-token", "Bearer access-token-forced"]

    always = FcmPushProvider(
        project_id="p",
        tokens=_StaticToken(),
        client=client(lambda _: _fcm_error(401, "UNAUTHENTICATED")),
    )
    with pytest.raises(ProviderUnavailableError):
        await always.send(PUSH, idempotency_key="n")


async def test_fcm_network_failures_are_transient_and_leak_nothing() -> None:
    def broken(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("boom " + str(request.url))

    provider = FcmPushProvider(project_id="p", tokens=_StaticToken(), client=client(broken))
    with pytest.raises(TransientProviderError) as excinfo:
        await provider.send(PUSH, idempotency_key="n")
    assert "boom" not in str(excinfo.value)
    assert str(PUSH.token) not in str(excinfo.value)


async def test_the_service_account_flow_signs_a_jwt_and_caches_the_access_token() -> None:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    info = {"client_email": "svc@afterme-dev.iam.gserviceaccount.com", "private_key": pem}
    fetches: list[dict[str, str]] = []
    now = [1_700_000_000.0]

    def handler(request: httpx.Request) -> httpx.Response:
        form = dict(item.split("=", 1) for item in request.content.decode().split("&"))
        fetches.append(form)
        return httpx.Response(200, json={"access_token": f"tok-{len(fetches)}", "expires_in": 3600})

    tokens = ServiceAccountTokens(info, client(handler), clock=lambda: now[0])
    assert await tokens.token() == "tok-1"
    assert await tokens.token() == "tok-1"  # cached
    assert len(fetches) == 1
    claims = jwt.decode(
        fetches[0]["assertion"],
        key.public_key(),
        algorithms=["RS256"],
        audience="https://oauth2.googleapis.com/token",
        options={"verify_exp": False, "verify_iat": False},  # a fixed test clock
    )
    assert claims["iss"] == info["client_email"]
    assert claims["scope"] == "https://www.googleapis.com/auth/firebase.messaging"
    now[0] += 3400  # inside the refresh margin of the 3600 s lifetime
    assert await tokens.token() == "tok-2"
    assert await tokens.token(force=True) == "tok-3"


async def test_a_refused_token_exchange_makes_the_provider_unavailable_not_the_message_bad() -> (
    None
):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    tokens = ServiceAccountTokens(
        {"client_email": "a@b", "private_key": pem},
        client(lambda _: httpx.Response(400, json={"error": "invalid_grant"})),
    )
    with pytest.raises(ProviderUnavailableError):
        await tokens.token()
    with pytest.raises(ValueError, match="private_key"):
        ServiceAccountTokens({"client_email": "a@b"}, client(lambda _: httpx.Response(200)))
    with pytest.raises(ValueError, match="not valid JSON"):
        load_service_account("{not json")


async def test_the_metadata_server_is_asked_with_its_header() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"access_token": "meta", "expires_in": 3000})

    tokens = MetadataServerTokens(client(handler))
    assert await tokens.token() == "meta"
    assert seen[0].headers["metadata-flavor"] == "Google"

    def down(_: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("no metadata server")

    with pytest.raises(ProviderUnavailableError):
        await MetadataServerTokens(client(down)).token()


# --- Resend -----------------------------------------------------------------------------------


async def test_resend_sends_with_the_notification_id_as_its_idempotency_key() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"id": "re_123"})

    provider = ResendEmailProvider(api_key="re_key", client=client(handler))
    result = await provider.send(MESSAGE, idempotency_key="notification-1")
    assert (result.provider, result.message_id) == ("resend", "re_123")
    [request] = seen
    assert request.headers["authorization"] == "Bearer re_key"
    # the notification id, then a digest of the body: the same message is the same key, a message
    # whose body changed (a fresh portal link) is not refused by Resend as a conflict
    assert request.headers["idempotency-key"].startswith("notification-1-")
    assert len(request.headers["idempotency-key"]) == len("notification-1-") + 16
    body = json.loads(request.content)
    assert body["to"] == ["mom@example.com"]
    assert body["from"] == MESSAGE.sender
    assert body["html"] == "<p>Hi Mom,</p>"
    assert body["headers"]["Auto-Submitted"] == "auto-generated"
    assert {"name": "notification_id", "value": "notification-1"} in body["tags"]


@pytest.mark.parametrize(
    ("status", "body", "expected"),
    [
        (422, {"name": "invalid_to_address"}, PermanentDeliveryError),
        # about us (a bad sender, a malformed request): never a verdict on the contact
        (422, {"name": "validation_error"}, ProviderUnavailableError),
        (400, {"name": "invalid_parameter"}, ProviderUnavailableError),
        (422, {"name": "invalid_from_address"}, ProviderUnavailableError),
        (401, {"name": "missing_api_key"}, ProviderUnavailableError),
        (403, {"name": "restricted_api_key"}, ProviderUnavailableError),
        (409, {"name": "concurrent_idempotent_requests"}, TransientProviderError),
        (429, {"name": "rate_limit_exceeded"}, TransientProviderError),
        (500, {}, TransientProviderError),
        (503, {}, TransientProviderError),
    ],
)
async def test_resend_answers_become_the_right_kind_of_failure(
    status: int, body: dict[str, Any], expected: type[Exception]
) -> None:
    provider = ResendEmailProvider(
        api_key="k", client=client(lambda _: httpx.Response(status, json=body))
    )
    with pytest.raises(expected):
        await provider.send(MESSAGE, idempotency_key="n")


# --- Postmark ---------------------------------------------------------------------------------


async def test_postmark_sends_on_a_transactional_stream_without_tracking() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"ErrorCode": 0, "MessageID": "pm-1"})

    provider = PostmarkEmailProvider(
        api_key="pm", message_stream="outbound", client=client(handler)
    )
    result = await provider.send(MESSAGE, idempotency_key="n-9")
    assert (result.provider, result.message_id) == ("postmark", "pm-1")
    request = seen[0]
    assert request.headers["x-postmark-server-token"] == "pm"
    body = json.loads(request.content)
    assert body["MessageStream"] == "outbound"
    assert body["TrackOpens"] is False
    assert body["TrackLinks"] == "None"
    assert body["Metadata"] == {"notification_id": "n-9"}
    assert body["Tag"] == "contact_alert"


@pytest.mark.parametrize(
    ("status", "error_code", "expected"),
    [
        (422, 406, PermanentDeliveryError),  # inactive recipient: the only verdict on a contact
        (422, 300, ProviderUnavailableError),  # invalid request: ours
        (401, 10, ProviderUnavailableError),  # bad server token
        (422, 400, ProviderUnavailableError),  # sender signature not found: ours
        (422, 401, ProviderUnavailableError),  # sender signature not confirmed: ours
        (422, 405, ProviderUnavailableError),  # not allowed to send
        (422, 412, ProviderUnavailableError),  # account blocked
        (429, 0, TransientProviderError),
        (500, 0, TransientProviderError),
    ],
)
async def test_postmark_answers_become_the_right_kind_of_failure(
    status: int, error_code: int, expected: type[Exception]
) -> None:
    provider = PostmarkEmailProvider(
        api_key="k",
        client=client(lambda _: httpx.Response(status, json={"ErrorCode": error_code})),
    )
    with pytest.raises(expected):
        await provider.send(MESSAGE, idempotency_key="n")


# --- SMTP -------------------------------------------------------------------------------------


class _FakeSmtp:
    sent: ClassVar[list[Any]] = []
    behaviour: ClassVar[Exception | None] = None
    log: ClassVar[list[str]] = []

    def __init__(self, host: str, port: int, timeout: float = 0, **_: object) -> None:
        self.log.append(f"connect {host}:{port}")

    def __enter__(self) -> _FakeSmtp:
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def starttls(self, **_: object) -> None:
        self.log.append("starttls")

    def login(self, user: str, password: str) -> None:
        self.log.append(f"login {user}")

    def send_message(self, message: Any) -> None:
        if self.behaviour is not None:
            raise self.behaviour
        self.sent.append(message)


@pytest.fixture
def fake_smtp(monkeypatch: pytest.MonkeyPatch) -> type[_FakeSmtp]:
    _FakeSmtp.sent = []
    _FakeSmtp.log = []
    _FakeSmtp.behaviour = None
    monkeypatch.setattr(smtplib, "SMTP", _FakeSmtp)
    return _FakeSmtp


async def test_smtp_builds_a_multipart_message_over_starttls(fake_smtp: type[_FakeSmtp]) -> None:
    provider = SmtpEmailProvider(host="smtp.example", port=587, username="u", password="p")
    result = await provider.send(MESSAGE, idempotency_key="n-5")
    assert result.provider == "smtp"
    assert result.message_id.startswith("<")
    assert fake_smtp.log == ["connect smtp.example:587", "starttls", "login u"]
    [mime] = fake_smtp.sent
    assert mime["To"] == "mom@example.com"
    assert mime["Auto-Submitted"] == "auto-generated"
    assert mime["X-Entity-Ref-ID"] == "n-5"
    assert mime.get_body(("plain",)).get_content().startswith("Hi Mom")
    assert "<p>Hi Mom,</p>" in mime.get_body(("html",)).get_content()


@pytest.mark.parametrize(
    ("raised", "expected"),
    [
        (smtplib.SMTPAuthenticationError(535, b"bad"), ProviderUnavailableError),
        (
            smtplib.SMTPRecipientsRefused({"mom@example.com": (550, b"no such user")}),
            PermanentDeliveryError,
        ),
        (
            smtplib.SMTPRecipientsRefused({"mom@example.com": (451, b"try later")}),
            TransientProviderError,
        ),
        (smtplib.SMTPResponseException(554, b"rejected"), ProviderUnavailableError),
        (smtplib.SMTPResponseException(550, b"relay denied"), ProviderUnavailableError),
        (smtplib.SMTPResponseException(421, b"busy"), TransientProviderError),
        (smtplib.SMTPServerDisconnected("gone"), TransientProviderError),
        (TimeoutError(), TransientProviderError),
    ],
)
async def test_smtp_failures_become_the_right_kind(
    fake_smtp: type[_FakeSmtp], raised: Exception, expected: type[Exception]
) -> None:
    fake_smtp.behaviour = raised
    provider = SmtpEmailProvider(host="h", port=25, username=None, password=None)
    with pytest.raises(expected):
        await provider.send(MESSAGE, idempotency_key="n")
