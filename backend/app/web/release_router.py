"""``/c/release`` routes: the recipient portal for released instructions (API_SPEC §13.1).

Same rules as the invitation pages: GET never changes state; every POST carries the double-submit
CSRF pair; the link token travels in the URL *fragment* and is exchanged by POST. Beyond that
there is a portal session cookie (``__Host-afterme_portal``, HttpOnly, stored hashed) and a
one-time code sent to the contact's verified address before any content is shown. Every page
that shows content is the *response to a POST* (viewing is recorded, and a GET must not record
anything), so content is never in a cache, a history entry, a log line or a URL.
"""

from __future__ import annotations

from types import SimpleNamespace
from typing import Final

from fastapi import APIRouter, Request, Response
from starlette.responses import HTMLResponse

from app.api.deps import ContextDep, DbSession, ServicesDep
from app.core.errors import RateLimited
from app.core.net import rate_limit_subject
from app.releases.portal_service import (
    SESSION_COOKIE,
    SESSION_TTL,
    CodeResult,
    PortalInvalidError,
    PortalWithdrawnError,
    ReleasePortalService,
    ViewState,
)
from app.security.rate_limit import WEB_PORTAL_PER_IP
from app.web import pages, security

router = APIRouter(prefix="/c/release", tags=["web"], include_in_schema=False)

_FORM_TOKEN_MAX: Final = 80


def _service(session: DbSession, services: ServicesDep, ctx: ContextDep) -> ReleasePortalService:
    return ReleasePortalService(session=session, services=services, ctx=ctx)


def _set_session_cookie(response: Response, value: str) -> None:
    response.set_cookie(
        SESSION_COOKIE,
        value,
        max_age=int(SESSION_TTL.total_seconds()),
        secure=True,
        httponly=True,
        samesite="strict",
        path="/",
    )


def _clear_session_cookie(response: Response) -> None:
    response.delete_cookie(SESSION_COOKIE, secure=True, httponly=True, samesite="strict", path="/")


def _expired(token: str, csrf: str) -> HTMLResponse:
    """One page for every link that cannot be used. It offers a fresh link; whether one is sent
    is decided server-side and answered identically."""
    value = csrf or security.new_csrf_value()
    response = pages.page(
        "release_invalid.html.j2",
        status_code=400,
        token=token if len(token) <= _FORM_TOKEN_MAX else "",
        csrf=value,
    )
    pages.set_csrf(response, value)
    return response


async def _guard(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> tuple[dict[str, str], str, HTMLResponse | None]:
    form = await pages.read_form(request)
    now = await services.clock.now(session)
    try:
        ctx.note_rate_limit(
            await services.limiter.enforce(
                [(WEB_PORTAL_PER_IP, rate_limit_subject(ctx.client_ip))], now=now
            )
        )
    except RateLimited as exc:
        return (
            form,
            "",
            pages.message(
                "Too many attempts",
                "Please wait a while and try again.",
                status_code=429,
                extra_headers=exc.headers,
            ),
        )
    cookie = request.cookies.get(security.CSRF_COOKIE)
    if not security.csrf_matches(cookie, form.get("csrf")):
        return (
            form,
            "",
            pages.message(
                "This page expired",
                "For your safety the request was not accepted. Open the link from your email "
                "again.",
                status_code=403,
            ),
        )
    return form, security.well_formed_csrf(cookie) or "", None


def _withdrawn(owner_name: str) -> HTMLResponse:
    return pages.page(
        "release_unavailable.html.j2",
        state=ViewState.CHECKED_IN.value,
        view=SimpleNamespace(owner_name=owner_name),
    )


def _too_many(exc: RateLimited) -> HTMLResponse:
    return pages.message(
        "Too many attempts",
        "Please wait a while and try again.",
        status_code=429,
        extra_headers=exc.headers,
    )


@router.get("")
async def open_page(request: Request) -> Response:
    """The page a release link opens. No database access and no state change: the token sits in
    the fragment, which the browser never sends."""
    csrf = security.well_formed_csrf(request.cookies.get(security.CSRF_COOKIE))
    csrf = csrf or security.new_csrf_value()
    response = pages.page(
        "contact_landing.html.j2",
        heading="Opening what was shared with you",
        intro="One moment. If nothing happens, press Continue.",
        action="/c/release/session",
        prefix="rt_",
        csrf=csrf,
    )
    pages.set_csrf(response, csrf)
    return response


@router.post("/session")
async def open_session(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    form, csrf, refused = await _guard(request, session, services, ctx)
    if refused is not None:
        return refused
    token = form.get("token", "")
    try:
        opened = await _service(session, services, ctx).open_session(token)
    except PortalWithdrawnError as exc:
        await session.rollback()
        return _withdrawn(exc.owner_name)
    except PortalInvalidError:
        await session.rollback()
        return _expired(token, csrf)
    response = pages.page(
        "release_send_code.html.j2",
        csrf=csrf,
        owner_name=opened.owner_name,
        masked_email=opened.masked_email,
    )
    _set_session_cookie(response, opened.cookie)
    return response


@router.post("/code")
async def send_code(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    _form, csrf, refused = await _guard(request, session, services, ctx)
    if refused is not None:
        return refused
    try:
        sent = await _service(session, services, ctx).send_code(request.cookies.get(SESSION_COOKIE))
    except PortalWithdrawnError as exc:
        await session.rollback()
        return _withdrawn(exc.owner_name)
    except PortalInvalidError:
        await session.rollback()
        return _expired("", csrf)
    except RateLimited as exc:
        await session.rollback()
        return _too_many(exc)
    return pages.page(
        "release_enter_code.html.j2",
        csrf=csrf,
        owner_name=sent.owner_name,
        masked_email=sent.masked_email,
        problem=None,
    )


@router.post("/verify")
async def verify_code(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    form, csrf, refused = await _guard(request, session, services, ctx)
    if refused is not None:
        return refused
    cookie = request.cookies.get(SESSION_COOKIE)
    service = _service(session, services, ctx)
    try:
        result = await service.verify_code(cookie, form.get("code", "").strip())
        if result is CodeResult.OK:
            return await _content(service, cookie, csrf)
        prompt = await service.code_prompt(cookie)
    except PortalWithdrawnError as exc:
        await session.rollback()
        return _withdrawn(exc.owner_name)
    except PortalInvalidError:
        await session.rollback()
        return _expired("", csrf)
    except RateLimited as exc:
        await session.rollback()
        return _too_many(exc)
    problem = {
        CodeResult.WRONG: "That code isn't right. Check it and try again.",
        CodeResult.EXPIRED: "That code has expired. Ask for a new one.",
        CodeResult.LOCKED: "Too many wrong codes. Ask for a new one.",
    }[result]
    return pages.page(
        "release_enter_code.html.j2",
        status_code=400,
        csrf=csrf,
        owner_name=prompt.owner_name,
        masked_email=prompt.masked_email,
        problem=problem,
    )


@router.post("/view")
async def view(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    _form, csrf, refused = await _guard(request, session, services, ctx)
    if refused is not None:
        return refused
    service = _service(session, services, ctx)
    try:
        return await _content(service, request.cookies.get(SESSION_COOKIE), csrf, ask_code=True)
    except PortalWithdrawnError as exc:
        await session.rollback()
        return _withdrawn(exc.owner_name)
    except PortalInvalidError:
        await session.rollback()
        return _expired("", csrf)


async def _content(
    service: ReleasePortalService, cookie: str | None, csrf: str, *, ask_code: bool = False
) -> Response:
    shown = await service.view(cookie)
    if shown is None:  # the code step lapsed: ask again
        prompt = await service.code_prompt(cookie)
        return pages.page(
            "release_send_code.html.j2",
            csrf=csrf,
            owner_name=prompt.owner_name,
            masked_email=prompt.masked_email,
        )
    if shown.state is ViewState.READY:
        return pages.page("release_view.html.j2", csrf=csrf, view=shown)
    status = 503 if shown.state is ViewState.ERROR else 200
    return pages.page(
        "release_unavailable.html.j2", status_code=status, state=shown.state.value, view=shown
    )


@router.post("/new-link")
async def new_link(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    form, _csrf, refused = await _guard(request, session, services, ctx)
    if refused is not None:
        return refused
    try:
        await _service(session, services, ctx).request_new_link(form.get("token", ""))
    except RateLimited:
        await session.rollback()  # said exactly like a sent link: nothing to learn here
    return pages.page("release_link_sent.html.j2")


@router.post("/end")
async def end(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    _form, _csrf, refused = await _guard(request, session, services, ctx)
    if refused is not None:
        return refused
    await _service(session, services, ctx).end_session(request.cookies.get(SESSION_COOKIE))
    done = pages.message(
        "You're done",
        "This page is closed. You can close the window too. Nothing was saved on this device.",
        status_code=200,
    )
    _clear_session_cookie(done)
    pages.clear_csrf(done)
    return done
