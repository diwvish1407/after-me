"""``/c`` routes: pages for trusted contacts who received an invitation (API_SPEC §13.1).

Phase 3 has no contact session cookie. Rules (ARCHITECTURE §6): GET never changes state, every
POST carries a CSRF token (double submit), and the secret link tokens travel in the URL
*fragment*. A first-party script copies the fragment into a hidden form field, clears it with
``history.replaceState`` and submits it to a POST route; every page that needs the token is the
response to such a POST, which puts the token back into its own forms.

Unusable tokens (malformed, unknown, expired, answered, forged, contact gone) all render the same
generic page with the same status, so nothing reveals whether a contact or invitation exists.
"""

from __future__ import annotations

from typing import Final

from fastapi import APIRouter, Request, Response
from starlette.responses import HTMLResponse

from app.api.deps import ContextDep, DbSession, ServicesDep
from app.contacts.portal_service import ContactPortalService, LinkInvalid
from app.core.errors import RateLimited
from app.core.net import rate_limit_subject
from app.security.rate_limit import WEB_CONTACT_PER_IP
from app.web import pages, security

router = APIRouter(prefix="/c", tags=["web"], include_in_schema=False)

_TRUTHY: Final = frozenset({"1", "true", "on", "yes"})


def _landing(request: Request, *, heading: str, intro: str, action: str, prefix: str) -> Response:
    """The page a link opens. No database access, no state change: the token is not even sent,
    because it sits in the URL fragment."""
    csrf = security.well_formed_csrf(request.cookies.get(security.CSRF_COOKIE))
    csrf = csrf or security.new_csrf_value()
    response = pages.page(
        "contact_landing.html.j2",
        heading=heading,
        intro=intro,
        action=action,
        prefix=prefix,
        csrf=csrf,
    )
    pages.set_csrf(response, csrf)
    return response


@router.get("/open")
async def open_invitation_page(request: Request) -> Response:
    return _landing(
        request,
        heading="Opening your invitation",
        intro="One moment. If nothing happens, press Continue.",
        action="/c/session",
        prefix="ci_",
    )


@router.get("/optout")
async def optout_page(request: Request) -> Response:
    return _landing(
        request,
        heading="Stop emails from AfterMe",
        intro="One moment. If nothing happens, press Continue.",
        action="/c/optout/confirm",
        prefix="oo_",
    )


def _invalid() -> HTMLResponse:
    return pages.page("contact_invalid.html.j2", status_code=400)


async def _guard(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> tuple[dict[str, str], str, HTMLResponse | None]:
    """Read the form, count the request against the per-IP limit, check CSRF. Returns the form,
    the CSRF value to put in follow-up forms, and an error page when the request is refused."""
    form = await pages.read_form(request)
    now = await services.clock.now(session)
    try:
        ctx.note_rate_limit(
            await services.limiter.enforce(
                [(WEB_CONTACT_PER_IP, rate_limit_subject(ctx.client_ip))], now=now
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


def _service(session: DbSession, services: ServicesDep, ctx: ContextDep) -> ContactPortalService:
    return ContactPortalService(session=session, services=services, ctx=ctx)


@router.post("/session")
async def session_open(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    """Exchange the invitation token for the invitation page. Changes nothing."""
    form, csrf, refused = await _guard(request, session, services, ctx)
    if refused is not None:
        return refused
    token = form.get("token", "")
    try:
        view = await _service(session, services, ctx).open_invitation(token)
    except LinkInvalid:
        return _invalid()
    return pages.page(
        "contact_invitation.html.j2",
        csrf=csrf,
        token=token,
        inviter_name=view.inviter_name,
        inviter_email=view.inviter_email,
    )


@router.post("/invite/accept")
async def invite_accept(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    form, _csrf, refused = await _guard(request, session, services, ctx)
    if refused is not None:
        return refused
    try:
        view = await _service(session, services, ctx).accept(form.get("token", ""))
    except LinkInvalid:
        return _invalid()
    done = pages.page("contact_accepted.html.j2", inviter_name=view.inviter_name)
    pages.clear_csrf(done)
    return done


@router.post("/invite/decline")
async def invite_decline(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    form, _csrf, refused = await _guard(request, session, services, ctx)
    if refused is not None:
        return refused
    never_contact = form.get("never_contact", "").lower() in _TRUTHY
    try:
        view = await _service(session, services, ctx).decline(
            form.get("token", ""), never_contact=never_contact
        )
    except LinkInvalid:
        return _invalid()
    done = pages.page(
        "contact_declined.html.j2", inviter_name=view.inviter_name, never_contact=never_contact
    )
    pages.clear_csrf(done)
    return done


@router.post("/optout/confirm")
async def optout_confirm(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    """Show the two choices for a valid opt-out token. Changes nothing."""
    form, csrf, refused = await _guard(request, session, services, ctx)
    if refused is not None:
        return refused
    token = form.get("token", "")
    try:
        view = await _service(session, services, ctx).optout_preview(token)
    except LinkInvalid:
        return _invalid()
    return pages.page(
        "contact_optout_choice.html.j2", csrf=csrf, token=token, inviter_name=view.inviter_name
    )


@router.post("/optout")
async def optout_submit(
    request: Request, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> Response:
    form, _csrf, refused = await _guard(request, session, services, ctx)
    if refused is not None:
        return refused
    try:
        result = await _service(session, services, ctx).opt_out(
            form.get("token", ""), form.get("scope", "")
        )
    except LinkInvalid:
        return _invalid()
    done = pages.page(
        "contact_optout_done.html.j2", scope=result.scope, inviter_name=result.inviter_name
    )
    pages.clear_csrf(done)
    return done
