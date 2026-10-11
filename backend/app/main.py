"""Application factory.

``uvicorn app.main:app`` serves the module-level application, which is created on first access
(PEP 562) so that importing this module (e.g. in tests) does not read the process environment.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from starlette.middleware import Middleware

from app.api.container import build_services
from app.api.health import router as health_router
from app.api.v1 import include_v1_routers
from app.core.clock import Clock
from app.core.config import Settings, load_settings
from app.core.handlers import register_exception_handlers
from app.core.logging import configure_logging, get_logger
from app.core.middleware import (
    BodySizeLimitMiddleware,
    ClientVersionMiddleware,
    RequestContextMiddleware,
)
from app.notifications.email import EmailProvider
from app.notifications.router import router as webhooks_router
from app.ops.router import router as ops_router
from app.testsupport.router import router as test_support_router
from app.web.account_router import router as account_web_router
from app.web.contact_router import router as contact_web_router
from app.web.release_router import router as release_web_router
from app.web.router import router as web_router

API_VERSION = "0.1.0"
API_ROLE = "afterme_api"


def create_app(
    settings: Settings | None = None,
    *,
    clock: Clock | None = None,
    email_provider: EmailProvider | None = None,
) -> FastAPI:
    settings = settings or load_settings()
    configure_logging(settings)
    services = build_services(settings, clock=clock, email_provider=email_provider)

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        log = get_logger("afterme.app")
        if settings.is_production_like:
            # The database's own limits (column grants, the one-way triggers) are keyed on the
            # role names of DATABASE §6: a process under another name would run without them.
            role = await services.db.current_role()
            if role != API_ROLE:
                msg = f"the API must connect as {API_ROLE}, not {role}"
                raise RuntimeError(msg)
        if "kms_local_key" not in settings.model_fields_set:
            log.warning("kms.development_key_in_use")
        log.info("app.started", env=settings.app_env.value)
        yield
        await services.db.dispose()

    docs = settings.docs_enabled
    app = FastAPI(
        title="AfterMe API",
        version=API_VERSION,
        debug=settings.debug,
        openapi_url="/v1/openapi.json" if docs else None,
        docs_url="/v1/docs" if docs else None,
        redoc_url=None,
        swagger_ui_oauth2_redirect_url="/v1/docs/oauth2-redirect" if docs else None,
        lifespan=lifespan,
        # FastAPI's native OpenTelemetry can record validation failures with their inputs and
        # exception messages; it stays off until tracing is designed with redaction (Phase 9).
        telemetry={
            "tracing": False,
            "metrics": False,
            "logs": False,
            "operation_spans": False,
            "auto_configure": False,
        },
        middleware=[
            Middleware(RequestContextMiddleware, settings=settings),
            Middleware(BodySizeLimitMiddleware, settings=settings),
            Middleware(ClientVersionMiddleware, settings=settings),
        ],
    )
    app.state.services = services
    register_exception_handlers(app, settings)
    app.include_router(health_router)
    include_v1_routers(app)
    app.include_router(ops_router)
    app.include_router(webhooks_router)
    app.include_router(web_router)
    app.include_router(account_web_router)
    app.include_router(release_web_router)  # before /c: its paths are more specific
    app.include_router(contact_web_router)
    if settings.test_support_enabled:  # refused by configuration in production
        if settings.is_production_like:  # a second lock: Settings validation is the first
            msg = "test support must never be mounted in a production-like environment"
            raise RuntimeError(msg)
        app.include_router(test_support_router)
    return app


_app: FastAPI | None = None


def __getattr__(name: str) -> FastAPI:
    global _app  # noqa: PLW0603 - lazily created module-level ASGI app
    if name == "app":
        if _app is None:
            _app = create_app()
        return _app
    msg = f"module {__name__!r} has no attribute {name!r}"
    raise AttributeError(msg)
