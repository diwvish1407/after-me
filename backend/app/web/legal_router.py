"""``/legal``, ``/legal/privacy``, ``/legal/terms`` and ``/support``: the public pages.

No session, no cookie, no database, no form: a GET that renders a template from the repository
with a few facts from the settings. They therefore keep working when everything else is down.
They carry the same security headers and Content-Security-Policy as every other page, except
that they may be cached for a few minutes by anyone (they hold nothing about any person).

The texts are converted from ``docs/legal/*_DRAFT.md``. While ``LEGAL_DOCUMENTS_FINAL`` is false
every legal page opens with a "draft, not yet reviewed by counsel" banner; counsel's review is
recorded by setting it to true, with no code change. Production refuses to start with it true
while the operator's name, contact address, postal address and the effective date are unset.
Every value from the settings is escaped by the template engine (autoescape).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from typing import Final

from fastapi import APIRouter, Request
from starlette.responses import HTMLResponse

from app.core.config import Settings
from app.web import pages

router = APIRouter(tags=["web"], include_in_schema=False)

PUBLIC_CACHE: Final = "public, max-age=300"
_YEAR_DAYS: Final = 365
_DEFAULT_OPERATOR: Final = "the operator of AfterMe"


@dataclass(frozen=True)
class LegalFacts:
    final: bool
    version: str
    effective_date: str | None
    operator: str
    site: str
    contact_email: str
    support_email: str
    postal_address: str | None
    audit_retention: str
    governing_law: str | None


def _date(value: date | None) -> str | None:
    return None if value is None else f"{value.day} {value:%B %Y}"


def _retention(days: int) -> str:
    return "1 year" if days == _YEAR_DAYS else f"{days} days"


def legal_facts(settings: Settings) -> LegalFacts:
    def clean(value: str | None) -> str | None:
        return value.strip() or None if value is not None else None

    return LegalFacts(
        final=settings.legal_documents_final,
        version=settings.legal_version,
        effective_date=_date(settings.legal_effective_date),
        operator=clean(settings.legal_operator_name) or _DEFAULT_OPERATOR,
        site=settings.public_base_url,
        contact_email=settings.legal_contact_email or settings.support_email,
        support_email=settings.support_email,
        postal_address=clean(settings.legal_postal_address),
        audit_retention=_retention(settings.audit_retention_days),
        governing_law=clean(settings.legal_governing_law),
    )


def _settings(request: Request) -> Settings:
    settings: Settings = request.app.state.services.settings
    return settings


def _render(request: Request, template: str) -> HTMLResponse:
    settings = _settings(request)
    return pages.page(
        template,
        extra_headers={"Cache-Control": PUBLIC_CACHE},
        legal=legal_facts(settings),
        support_email=settings.support_email,
        abuse_email=settings.abuse_email,
    )


@router.get("/legal")
async def legal_index(request: Request) -> HTMLResponse:
    return _render(request, "legal_index.html.j2")


@router.get("/legal/privacy")
async def privacy(request: Request) -> HTMLResponse:
    return _render(request, "legal_privacy.html.j2")


@router.get("/legal/terms")
async def terms(request: Request) -> HTMLResponse:
    return _render(request, "legal_terms.html.j2")


@router.get("/support")
async def support(request: Request) -> HTMLResponse:
    return _render(request, "support.html.j2")
