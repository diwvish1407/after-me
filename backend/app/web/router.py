"""``/a`` routes: pages for signed-out account owners (API_SPEC §13.2).

Rules (ARCHITECTURE §6): GET never changes state, every POST carries a CSRF token, the reset
token travels in the URL *fragment* and reaches the server only in a POST body.
"""

from __future__ import annotations

from functools import cache
from typing import Final

from fastapi import APIRouter, Request, Response
from starlette.responses import HTMLResponse

from app.api.deps import ContextDep, DbSession, ServicesDep
from app.auth.account_service import AccountService, ResetLinkInvalid
from app.core.errors import RateLimited
from app.core.net import rate_limit_subject
from app.security.passwords import PasswordPolicyError
from app.security.rate_limit import WEB_RESET_PER_IP
from app.web import pages, security

router = APIRouter(prefix="/a", tags=["web"], include_in_schema=False)

_HERE: Final = pages.HERE


@cache
def _stylesheet() -> str:
    return (_HERE / "static" / "web.css").read_text(encoding="utf-8")


@router.get("/assets/web.css")
async def stylesheet() -> Response:
    return Response(
        _stylesheet(),
        media_type="text/css",
        headers={"Cache-Control": "public, max-age=3600", "X-Content-Type-Options": "nosniff"},
    )


@router.get("/reset")
async def reset_form(request: Request) -> HTMLResponse:
    """The form only. No database access, no state change: the token is not even sent here,
    because it sits in the URL fragment, which the first-party script copies into the form."""
    csrf = security.well_formed_csrf(request.cookies.get(security.CSRF_COOKIE))
    csrf = csrf or security.new_csrf_value()
    response = pages.page("reset_form.html.j2", csrf=csrf, token="", message="")
    pages.set_csrf(response, csrf)
    return response


@router.post("/reset")
async def reset_submit(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    form = await pages.read_form(request)

    now = await services.clock.now(session)
    try:
        ctx.note_rate_limit(
            await services.limiter.enforce(
                [(WEB_RESET_PER_IP, rate_limit_subject(ctx.client_ip))], now=now
            )
        )
    except RateLimited as exc:
        return pages.message(
            "Too many attempts",
            "Please wait a while and try again.",
            status_code=429,
            extra_headers=exc.headers,
        )

    cookie = request.cookies.get(security.CSRF_COOKIE)
    if not security.csrf_matches(cookie, form.get("csrf")):
        return pages.message(
            "This page expired",
            "For your safety the request was not accepted. Open the link from your email again.",
            status_code=403,
        )

    token = form.get("token", "")
    service = AccountService(session=session, services=services, ctx=ctx)
    try:
        await service.reset_password(token=token, new_password=form.get("new_password", ""))
    except ResetLinkInvalid:
        return pages.page("reset_invalid.html.j2", status_code=400)
    except PasswordPolicyError as exc:
        # The link stays valid: show the form again with the reason.
        again = pages.page(
            "reset_form.html.j2",
            status_code=422,
            csrf=security.well_formed_csrf(cookie) or "",
            token=token,
            message=exc.message,
        )
        return again
    done = pages.page("reset_done.html.j2")
    pages.clear_csrf(done)
    return done
