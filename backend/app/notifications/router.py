"""``POST /webhooks/email/{provider}`` (API_SPEC §14). Machine to machine: no session, no cookie,
no CSRF; the provider's signature (or password) is the credential."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Path, Request, Response, status

from app.api.deps import DbSession, ServicesDep, ip_rate_limit
from app.notifications.webhooks import EmailEventService, WebhookMalformed, WebhookRejected
from app.security.rate_limit import WEBHOOK_PER_IP

router = APIRouter(tags=["webhooks"], include_in_schema=False)


@router.post("/webhooks/email/{provider}", dependencies=[Depends(ip_rate_limit(WEBHOOK_PER_IP))])
async def email_events(
    request: Request,
    session: DbSession,
    services: ServicesDep,
    provider: Annotated[str, Path(pattern=r"^[a-z]{3,16}$")],
) -> Response:
    service = EmailEventService(session=session, services=services)
    if not service.known(provider):
        # Not configured: indistinguishable from a path that does not exist.
        return Response(status_code=status.HTTP_404_NOT_FOUND)
    headers = {k.lower(): v for k, v in request.headers.items()}
    try:
        await service.handle(provider, headers, await request.body())
    except WebhookRejected:
        return Response(status_code=status.HTTP_401_UNAUTHORIZED)
    except WebhookMalformed:
        return Response(status_code=status.HTTP_400_BAD_REQUEST)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
