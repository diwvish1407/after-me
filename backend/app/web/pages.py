"""Rendering and form helpers shared by the server-rendered routers (``/a`` and ``/c``)."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Final
from urllib.parse import parse_qsl

from fastapi import Request, Response
from jinja2 import Environment, FileSystemLoader, StrictUndefined, select_autoescape
from starlette.responses import HTMLResponse, RedirectResponse

from app.web import security

HERE: Final = Path(__file__).parent
FORM_TYPE: Final = "application/x-www-form-urlencoded"
MAX_FORM_FIELDS: Final = 10

_env = Environment(
    loader=FileSystemLoader(HERE / "templates"),
    autoescape=select_autoescape(["html", "htm", "j2"], default_for_string=True),
    undefined=StrictUndefined,
    keep_trailing_newline=True,
)


def page(
    template: str,
    *,
    status_code: int = 200,
    extra_headers: dict[str, str] | None = None,
    **ctx: Any,
) -> HTMLResponse:
    nonce = security.new_nonce()
    body = _env.get_template(template).render(nonce=nonce, **ctx)
    return HTMLResponse(
        body,
        status_code=status_code,
        headers={**security.page_headers(nonce), **(extra_headers or {})},
    )


def redirect(location: str) -> RedirectResponse:
    """A 303 that carries the same security headers as every page."""
    return RedirectResponse(
        location, status_code=303, headers=security.page_headers(security.new_nonce())
    )


def set_csrf(response: Response, value: str) -> None:
    response.set_cookie(
        security.CSRF_COOKIE, value, secure=True, httponly=True, samesite="strict", path="/"
    )


def clear_csrf(response: Response) -> None:
    response.delete_cookie(
        security.CSRF_COOKIE, secure=True, httponly=True, samesite="strict", path="/"
    )


def message(
    heading: str, text: str, *, status_code: int, extra_headers: dict[str, str] | None = None
) -> HTMLResponse:
    return page(
        "message.html.j2",
        status_code=status_code,
        extra_headers=extra_headers,
        heading=heading,
        text=text,
    )


async def read_form(request: Request) -> dict[str, str]:
    """A urlencoded body as a dict (first value wins). Anything else is an empty form, which
    then fails the CSRF check. No multipart parser is needed, so none is installed."""
    if not request.headers.get("content-type", "").lower().startswith(FORM_TYPE):
        return {}
    try:
        pairs = parse_qsl(
            (await request.body()).decode("utf-8"),
            keep_blank_values=True,
            max_num_fields=MAX_FORM_FIELDS,
        )
    except (UnicodeDecodeError, ValueError):
        return {}
    form: dict[str, str] = {}
    for key, value in pairs:
        form.setdefault(key, value)
    return form
