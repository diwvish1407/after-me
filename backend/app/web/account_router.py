"""``/a/login``, ``/a/checkin``, ``/a/safe``, ``/a/logout``: check in from a browser when the
phone is lost (PRD FR-CHK-07; API_SPEC §13.2).

Rules (ARCHITECTURE §6): GET never changes state; every POST carries a CSRF token; the session
cookie is ``__Host-`` prefixed, ``HttpOnly``, ``Secure`` and ``SameSite=Strict``. The pages call
the same services as the app, so the same rules apply: an I'M OK after contacts were told is
refused (``safe_required``), and I'M SAFE needs the password.
"""

from __future__ import annotations

import uuid
from typing import Any

from fastapi import APIRouter, Request, Response
from starlette.responses import HTMLResponse

from app.api.deps import ContextDep, CurrentUser, DbSession, ServicesDep
from app.checkins.service import CheckinService
from app.core.errors import (
    AppError,
    InvalidCredentials,
    InvalidState,
    NotFound,
    RateLimited,
    SafeRequired,
    SessionRevoked,
)
from app.home.service import HomeService
from app.incidents.service import IncidentService
from app.web import pages, security
from app.web.account_session import (
    WEB_COOKIE,
    WEB_SESSION_TTL,
    WebSessionService,
    format_local,
    new_form_key,
    valid_form_key,
)

router = APIRouter(prefix="/a", tags=["web"], include_in_schema=False)

_SOURCE = "web"


def _csrf(request: Request) -> tuple[str, bool]:
    """The CSRF value for this page and whether the cookie has to be (re)set."""
    existing = security.well_formed_csrf(request.cookies.get(security.CSRF_COOKIE))
    return (existing, False) if existing else (security.new_csrf_value(), True)


def _page(request: Request, template: str, *, status_code: int = 200, **ctx: Any) -> HTMLResponse:
    csrf, fresh = _csrf(request)
    response = pages.page(template, status_code=status_code, csrf=csrf, **ctx)
    if fresh:
        pages.set_csrf(response, csrf)
    return response


def _expired() -> HTMLResponse:
    return pages.message(
        "This page expired",
        "For your safety the request was not accepted. Go back and try again.",
        status_code=403,
    )


def _sign_in_page(request: Request, *, status_code: int = 200, message: str = "") -> HTMLResponse:
    """The sign-in form, served in place of a page that needs a session. (No redirect: a GET
    of ``/a/checkin`` with no session is still a page, and a POST that lost its session shows
    where to sign in rather than silently doing nothing.)"""
    return _page(request, "login.html.j2", status_code=status_code, message=message)


def _too_many(exc: RateLimited) -> HTMLResponse:
    return pages.message(
        "Too many attempts",
        "Please wait a while and try again.",
        status_code=429,
        extra_headers=exc.headers,
    )


def _cookie_service(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> tuple[WebSessionService, str | None]:
    return (
        WebSessionService(session=session, services=services, ctx=ctx),
        request.cookies.get(WEB_COOKIE),
    )


# --- sign in -----------------------------------------------------------------------------------


@router.get("/login")
async def login_form(request: Request) -> HTMLResponse:
    return _page(request, "login.html.j2", message="")


@router.post("/login")
async def login_submit(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    form = await pages.read_form(request)
    if not security.csrf_matches(request.cookies.get(security.CSRF_COOKIE), form.get("csrf")):
        return _expired()
    service = WebSessionService(session=session, services=services, ctx=ctx)
    try:
        token = await service.sign_in(form.get("email", ""), form.get("password", ""))
    except RateLimited as exc:
        return _too_many(exc)
    except InvalidCredentials:
        return _page(
            request,
            "login.html.j2",
            status_code=401,
            message="That email or password isn't right.",
        )
    response = pages.redirect("/a/checkin")
    response.set_cookie(
        WEB_COOKIE,
        token,
        max_age=int(WEB_SESSION_TTL.total_seconds()),
        secure=True,
        httponly=True,
        samesite="strict",
        path="/",
    )
    return response


@router.post("/logout")
async def logout(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    form = await pages.read_form(request)
    if not security.csrf_matches(request.cookies.get(security.CSRF_COOKIE), form.get("csrf")):
        return _expired()
    service, token = _cookie_service(request, session, services, ctx)
    current = await service.resolve(token)
    if current is not None:
        await service.logout(current)
    response = _sign_in_page(request, message="You are signed out.")
    response.delete_cookie(WEB_COOKIE, secure=True, httponly=True, samesite="strict", path="/")
    return response


# --- the state page ----------------------------------------------------------------------------


async def _state_page(
    request: Request,
    current: CurrentUser,
    session: DbSession,
    services: ServicesDep,
    ctx: ContextDep,
    *,
    message: str = "",
    status_code: int = 200,
) -> HTMLResponse:
    home = await HomeService(session=session, services=services, ctx=ctx).home(current)
    zone = home.user.timezone
    incident: dict[str, Any] | None = home.incident
    notified: list[str] = []
    mode = "ok"
    incident_id = ""
    if incident is not None:
        incident_id = str(incident["id"])
        mode = "safe" if incident.get("requires") == "safe" else "missed"
        for entry in incident.get("timeline", []):
            if entry.get("kind") == "execute_stage" and entry.get("status") == "executed":
                notified.extend(
                    c["display_name"]
                    for c in entry.get("contacts", [])
                    if c.get("result") == "messaged"
                )
    return _page(
        request,
        "checkin.html.j2",
        status_code=status_code,
        name=home.user.display_name,
        mode=mode,
        incident_id=incident_id,
        notified=sorted(set(notified)),
        next_due=format_local(home.checkin.next_due_at, zone),
        last_checkin=format_local(home.checkin.last_checkin_at, zone),
        schedule_on=home.checkin.status != "inactive",
        key=new_form_key(),
        message=message,
    )


@router.get("/checkin")
async def checkin_page(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    service, token = _cookie_service(request, session, services, ctx)
    current = await service.resolve(token)
    if current is None:
        return _sign_in_page(request)
    return await _state_page(request, current, session, services, ctx)


# --- I'M OK ------------------------------------------------------------------------------------


@router.post("/checkin")
async def checkin_submit(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    form = await pages.read_form(request)
    if not security.csrf_matches(request.cookies.get(security.CSRF_COOKIE), form.get("csrf")):
        return _expired()
    service, token = _cookie_service(request, session, services, ctx)
    current = await service.resolve(token)
    if current is None:
        return _sign_in_page(request, status_code=401, message="Sign in to continue.")
    key = form.get("key", "")
    if not valid_form_key(key):
        return await _state_page(request, current, session, services, ctx)
    checkins = CheckinService(session=session, services=services, ctx=ctx)
    try:
        body, _ = await checkins.record(current, key, None, source=_SOURCE)
    except SafeRequired:
        # Contacts have been told: an I'M OK is not enough, the page now asks for I'M SAFE.
        return pages.redirect("/a/checkin")
    except RateLimited as exc:
        return _too_many(exc)
    except SessionRevoked:
        return _sign_in_page(request, status_code=401, message="Sign in to continue.")
    except AppError:
        return pages.message(
            "We couldn't record that",
            "Nothing was changed. Please try again in a moment.",
            status_code=503,
        )
    home = await HomeService(session=session, services=services, ctx=ctx).home(current)
    return _page(
        request,
        "checkin_done.html.j2",
        next_due=format_local(
            body.get("next_due_at") and _parse(body["next_due_at"]), home.user.timezone
        ),
        resolved=bool(body.get("incident_resolved")),
    )


# --- I'M SAFE ----------------------------------------------------------------------------------


@router.post("/safe")
async def safe_submit(  # noqa: PLR0911 - an ordered list of refusals, each its own page
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    form = await pages.read_form(request)
    if not security.csrf_matches(request.cookies.get(security.CSRF_COOKIE), form.get("csrf")):
        return _expired()
    service, token = _cookie_service(request, session, services, ctx)
    current = await service.resolve(token)
    if current is None:
        return _sign_in_page(request, status_code=401, message="Sign in to continue.")
    key = form.get("key", "")
    try:
        incident_id = uuid.UUID(form.get("incident_id", ""))
    except ValueError:
        return await _state_page(request, current, session, services, ctx)
    if not valid_form_key(key):
        return await _state_page(request, current, session, services, ctx)
    try:
        confirmed = await service.confirm_password(current, form.get("password", ""))
    except RateLimited as exc:
        return _too_many(exc)
    if confirmed is None:
        return await _state_page(
            request,
            current,
            session,
            services,
            ctx,
            message="That password isn't right. Nobody has been told you are safe yet.",
            status_code=401,
        )
    try:
        body, _ = await IncidentService(session=session, services=services, ctx=ctx).safe(
            confirmed, incident_id, key, source=_SOURCE
        )
    except RateLimited as exc:
        return _too_many(exc)
    except (InvalidState, NotFound):
        return await _state_page(
            request,
            current,
            session,
            services,
            ctx,
            message="That incident is already closed.",
        )
    except AppError:
        return pages.message(
            "We couldn't do that",
            "Nothing was changed. Please try again in a moment.",
            status_code=409,
        )
    home = await HomeService(session=session, services=services, ctx=ctx).home(confirmed)
    targets = body.get("all_clear_sent_to")
    names = (
        [t["display_name"] for t in targets if isinstance(t, dict)]
        if isinstance(targets, list)
        else []
    )
    return _page(
        request,
        "safe_done.html.j2",
        names=names,
        next_due=format_local(_parse(body.get("next_due_at")), home.user.timezone),
    )


def _parse(value: Any) -> Any:
    from datetime import datetime  # noqa: PLC0415

    return datetime.fromisoformat(value) if isinstance(value, str) else None
