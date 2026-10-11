"""``/v1/instruction-categories`` and ``/v1/instructions`` routes (API_SPEC §10)."""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response, status

from app.api.deps import ContextDep, CurrentUserDep, DbSession, ReauthUserDep, ServicesDep
from app.instructions.schemas import (
    CategoryList,
    InstructionCreateRequest,
    InstructionList,
    InstructionOut,
    InstructionPatchRequest,
)
from app.instructions.service import InstructionService

router = APIRouter(prefix="/v1", tags=["instructions"])


def get_instruction_service(
    session: DbSession, services: ServicesDep, ctx: ContextDep
) -> InstructionService:
    return InstructionService(session=session, services=services, ctx=ctx)


InstructionServiceDep = Annotated[InstructionService, Depends(get_instruction_service)]


@router.get("/instruction-categories")
async def list_categories(current: CurrentUserDep, service: InstructionServiceDep) -> CategoryList:
    return await service.categories()


# Reading decrypts the content, so it asks for the password entered in the last five minutes, like
# every other thing that exposes or changes what contacts will receive. Without it the export's
# fresh-password rule would protect nothing: the same text is one GET per instruction away.
@router.get("/instructions")
async def list_instructions(
    current: ReauthUserDep,
    service: InstructionServiceDep,
    category: Annotated[str | None, Query(pattern=r"^[a-z_]{2,32}$")] = None,
) -> InstructionList:
    return await service.list_instructions(current, category)


@router.post("/instructions", status_code=status.HTTP_201_CREATED)
async def create_instruction(
    body: InstructionCreateRequest, current: CurrentUserDep, service: InstructionServiceDep
) -> InstructionOut:
    return await service.create(current, body)


@router.get("/instructions/{instruction_id}")
async def get_instruction(
    instruction_id: uuid.UUID, current: ReauthUserDep, service: InstructionServiceDep
) -> InstructionOut:
    return await service.get_instruction(current, instruction_id)


@router.patch("/instructions/{instruction_id}")
async def patch_instruction(
    instruction_id: uuid.UUID,
    body: InstructionPatchRequest,
    current: CurrentUserDep,
    service: InstructionServiceDep,
) -> InstructionOut:
    return await service.patch(current, instruction_id, body)


@router.delete(
    "/instructions/{instruction_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    response_class=Response,
)
async def delete_instruction(
    instruction_id: uuid.UUID, current: CurrentUserDep, service: InstructionServiceDep
) -> Response:
    await service.delete(current, instruction_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
