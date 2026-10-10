"""``/v1/contacts`` routes (API_SPEC §7). HTTP only: parse, authenticate, call the service."""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, BackgroundTasks, Depends, Response, status

from app.api.deps import ContextDep, CurrentUserDep, DbSession, ServicesDep
from app.contacts.schemas import (
    ContactCreateRequest,
    ContactList,
    ContactOut,
    ContactPatchRequest,
    InvitationQueued,
)
from app.contacts.service import ContactService

router = APIRouter(prefix="/v1/contacts", tags=["contacts"])


def get_contact_service(
    session: DbSession, services: ServicesDep, ctx: ContextDep
) -> ContactService:
    return ContactService(session=session, services=services, ctx=ctx)


ContactServiceDep = Annotated[ContactService, Depends(get_contact_service)]


@router.get("")
async def list_contacts(current: CurrentUserDep, service: ContactServiceDep) -> ContactList:
    return await service.list_contacts(current)


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_contact(
    body: ContactCreateRequest,
    current: CurrentUserDep,
    service: ContactServiceDep,
    services: ServicesDep,
    background: BackgroundTasks,
) -> ContactOut:
    contact, outbox = await service.create(current, body)
    # Sent after the response in every branch, so delivery time cannot reveal suppression.
    background.add_task(services.mailer.deliver, outbox)
    return contact


@router.get("/{contact_id}")
async def get_contact(
    contact_id: uuid.UUID, current: CurrentUserDep, service: ContactServiceDep
) -> ContactOut:
    return await service.get_contact(current, contact_id)


@router.patch("/{contact_id}")
async def update_contact(
    contact_id: uuid.UUID,
    body: ContactPatchRequest,
    current: CurrentUserDep,
    service: ContactServiceDep,
    services: ServicesDep,
    background: BackgroundTasks,
) -> ContactOut:
    contact, outbox = await service.update(current, contact_id, body)
    background.add_task(services.mailer.deliver, outbox)
    return contact


@router.delete("/{contact_id}", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def delete_contact(
    contact_id: uuid.UUID, current: CurrentUserDep, service: ContactServiceDep
) -> Response:
    await service.delete(current, contact_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{contact_id}/invitation", status_code=status.HTTP_202_ACCEPTED)
async def resend_invitation(
    contact_id: uuid.UUID,
    current: CurrentUserDep,
    service: ContactServiceDep,
    services: ServicesDep,
    background: BackgroundTasks,
) -> InvitationQueued:
    outbox = await service.resend_invitation(current, contact_id)
    background.add_task(services.mailer.deliver, outbox)
    return InvitationQueued()
