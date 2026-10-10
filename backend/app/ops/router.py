"""``POST /internal/probe`` (API_SPEC §14): the external uptime monitor's heartbeat.

The monitor calls it through the **public ingress** every minute, so a probe that arrives proves
the same path real users take is working. Each probe is a row in ``ingestion_probes``; the
engine starts a Hold when they stop (ESCALATION_ENGINE §7). Authenticated with a shared secret,
compared in constant time. Where no probe token is configured the route does not exist.
"""

from __future__ import annotations

import secrets
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Response, status
from sqlalchemy import text

from app.api.deps import ClockDep, ContextDep, DbSession, ServicesDep, ip_rate_limit
from app.core.errors import NotFound, Unauthenticated
from app.security.rate_limit import PROBE_PER_IP

router = APIRouter(tags=["internal"])

_SOURCE_MAX = 40


@router.post(
    "/internal/probe",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=[Depends(ip_rate_limit(PROBE_PER_IP))],
)
async def probe(
    session: DbSession,
    services: ServicesDep,
    clock: ClockDep,
    ctx: ContextDep,
    token: Annotated[str | None, Header(alias="X-Probe-Token")] = None,
    source: Annotated[str | None, Header(alias="X-Probe-Source", max_length=_SOURCE_MAX)] = None,
) -> Response:
    expected = services.settings.probe_token
    if expected is None:
        raise NotFound  # not configured: the route does not exist
    if token is None or not secrets.compare_digest(
        token.encode(), expected.get_secret_value().encode()
    ):
        raise Unauthenticated
    # A Core INSERT with no RETURNING: the API role may insert probes but not read them back.
    await session.execute(
        text("INSERT INTO ingestion_probes (received_at, source) VALUES (:at, :source)"),
        {"at": await clock.now(session), "source": (source or "monitor")[:_SOURCE_MAX]},
    )
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
