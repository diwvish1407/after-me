"""``/test/*``: only mounted when test support is enabled (never in production).

* ``GET /test/clock`` the server's time and the offset in force.
* ``POST /test/clock/advance`` ``{"seconds": n}`` moves time forward for the API and the worker.
* ``POST /test/clock/reset`` puts the clock back on the database clock (time moves *backwards*:
  use a fresh account afterwards).
* ``GET /test/mail?to=&template=&limit=`` the newest messages the console email provider wrote.
"""

from __future__ import annotations

import hmac
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import Annotated, Final

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, status
from pydantic import BaseModel, ConfigDict, Field

from app.api.deps import DbSession, ServicesDep
from app.testsupport import clock as test_clock

_TOKEN_HEADER: Final = "X-Test-Token"  # noqa: S105
_HEADER_RE: Final = re.compile(r"^(To|Subject|X-Template): (.*)$")


async def require_token(
    services: ServicesDep, token: Annotated[str | None, Header(alias=_TOKEN_HEADER)] = None
) -> None:
    """Fails closed: no configured token, no access (configuration refuses that state anyway)."""
    expected = services.settings.test_support_token
    if (
        expected is None
        or token is None
        or not hmac.compare_digest(token.encode(), expected.get_secret_value().encode())
    ):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "test token required")


# On the router itself, so that an endpoint added later cannot forget the guard.
router = APIRouter(
    prefix="/test",
    tags=["test-support"],
    include_in_schema=False,
    dependencies=[Depends(require_token)],
)


class ClockState(BaseModel):
    model_config = ConfigDict(extra="forbid")
    server_time: datetime
    offset_seconds: int


class AdvanceRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    seconds: int = Field(ge=1, le=test_clock.MAX_STEP_SECONDS)


class MailMessage(BaseModel):
    template: str
    to: str
    subject: str
    text: str
    written_at: datetime


class MailList(BaseModel):
    messages: list[MailMessage]


async def _state(session: DbSession, services: ServicesDep) -> ClockState:
    now = await services.clock.now(session)
    return ClockState(server_time=now, offset_seconds=await test_clock.offset_seconds(session))


@router.get("/clock")
async def get_clock(session: DbSession, services: ServicesDep) -> ClockState:
    state = await _state(session, services)
    await session.commit()
    return state


@router.post("/clock/advance")
async def advance_clock(
    body: AdvanceRequest, session: DbSession, services: ServicesDep
) -> ClockState:
    await test_clock.advance(session, body.seconds)
    await session.commit()
    state = await _state(session, services)
    await session.commit()
    return state


@router.post("/clock/reset")
async def reset_clock(session: DbSession, services: ServicesDep) -> ClockState:
    await test_clock.reset(session)
    await session.commit()
    state = await _state(session, services)
    await session.commit()
    return state


def _read(path: Path) -> MailMessage | None:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return None
    head, _, body = raw.partition("\n\n")
    fields = {}
    for line in head.splitlines():
        found = _HEADER_RE.match(line)
        if found:
            fields[found[1]] = found[2]
    return MailMessage(
        template=fields.get("X-Template", ""),
        to=fields.get("To", ""),
        subject=fields.get("Subject", ""),
        text=body,
        written_at=datetime.fromtimestamp(path.stat().st_mtime, UTC),
    )


@router.get("/mail")
async def read_mail(
    request: Request,
    services: ServicesDep,
    to: Annotated[str | None, Query(max_length=254)] = None,
    template: Annotated[str | None, Query(max_length=64, pattern=r"^[a-z_]+$")] = None,
    limit: Annotated[int, Query(ge=1, le=50)] = 10,
) -> MailList:
    if services.settings.email_provider != "console":
        raise HTTPException(
            status.HTTP_501_NOT_IMPLEMENTED, "mail is only kept by the console provider"
        )
    directory = services.settings.dev_mail_dir
    files = sorted(directory.glob("*.txt"), reverse=True) if directory.is_dir() else []
    wanted_to = to.strip().lower() if to else None
    found: list[MailMessage] = []
    for path in files:
        message = _read(path)
        if message is None:
            continue
        if wanted_to is not None and message.to.strip().lower() != wanted_to:
            continue
        if template is not None and message.template != template:
            continue
        found.append(message)
        if len(found) >= limit:
            break
    return MailList(messages=found)
