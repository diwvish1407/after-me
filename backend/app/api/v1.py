"""The ``/v1`` JSON API: every module router is registered here.

Each module router carries its full ``/v1/...`` prefix, so a matched route's ``path`` is the full
template (used by the access log) without depending on how routers are nested.
"""

from __future__ import annotations

from fastapi import APIRouter, FastAPI

from app.activity.router import router as activity_router
from app.auth.router import router as auth_router
from app.checkins.router import router as checkins_router
from app.contacts.router import router as contacts_router
from app.devices.router import router as devices_router
from app.home.router import router as home_router
from app.incidents.router import router as incidents_router
from app.instructions.router import router as instructions_router
from app.plans.router import router as plan_router
from app.users.router import router as users_router

V1_ROUTERS: tuple[APIRouter, ...] = (
    auth_router,
    users_router,
    contacts_router,
    checkins_router,
    home_router,
    plan_router,
    incidents_router,
    instructions_router,
    activity_router,
    devices_router,
)


def include_v1_routers(app: FastAPI) -> None:
    for router in V1_ROUTERS:
        app.include_router(router)
