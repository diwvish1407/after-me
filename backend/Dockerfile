# AfterMe backend image: one image, three processes, chosen by the command.
#
#   API          (default)   uvicorn app.main:app ...     listens on 0.0.0.0:${PORT:-8080}
#   worker                   python -m workers.engine
#   maintenance              python -m workers.maintenance --every 900
#   operator CLI             python -m cli.admin status
#   migration job            alembic upgrade head          (as afterme_owner; see DEPLOYMENT)
#
#   docker build --build-arg PYTHON_VERSION="$(cat .python-version)" -t afterme-backend backend
#   docker run --rm afterme-backend python -m workers.engine
#
# * Built from uv.lock with `uv sync --frozen --no-dev`: the image has exactly the locked
#   production dependencies and no test or lint tooling. Nothing is resolved at build time.
# * The Python version is backend/.python-version. A Dockerfile cannot read a file in FROM, so
#   it arrives as the PYTHON_VERSION build argument (CI passes `cat .python-version`); the build
#   stops if the two disagree, so the image can never run a different interpreter than the one
#   the lock file and the tests were made for.
# * No secrets: no ARG or ENV here carries one, and .dockerignore keeps .env files and keys out
#   of the build context. All configuration (database URLs, JWT keys, pepper, providers) is
#   AFTERME_* environment supplied by the platform at run time (README "Configuration").
# * Not root: the processes run as uid 10001, and the code is owned by root and read-only to
#   them. No shell is needed except `sh -c` in the API command, which expands ${PORT}.
# * No health check is declared: the platform probes GET /health/live and /health/ready.
#
# This file could not be built on the machine it was written on (no Docker); the `docker` job
# of .github/workflows/backend.yml builds it on every backend change.

ARG PYTHON_VERSION=3.13
ARG UV_VERSION=0.9.26

# The uv binary, taken from the official image of the same version CI uses.
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# --- builder: the locked production environment ------------------------------------------
FROM python:${PYTHON_VERSION}-slim-bookworm AS builder
ARG PYTHON_VERSION

COPY --from=uv /uv /usr/local/bin/uv

# The venv lives outside the source tree so the runtime stage can copy just it. Bytecode is
# compiled now (a faster cold start, and nothing for a read-only file system to write later).
# The interpreter must be the image's own: never download one.
ENV UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_DOWNLOADS=never \
    UV_PYTHON_PREFERENCE=only-system \
    UV_NO_PROGRESS=1

WORKDIR /build
# pyproject.toml names README.md as the readme: it must exist, although nothing is packaged
# (`package = false`: the backend is an application, run from its source directory).
COPY pyproject.toml uv.lock .python-version README.md ./

RUN test "$(cat .python-version)" = "${PYTHON_VERSION}" \
    || { echo "PYTHON_VERSION=${PYTHON_VERSION} does not match .python-version: $(cat .python-version)" >&2; exit 1; }

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

# --- runtime ------------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONFAULTHANDLER=1 \
    PATH="/opt/venv/bin:${PATH}" \
    PORT=8080

RUN groupadd --system --gid 10001 afterme \
    && useradd --system --uid 10001 --gid 10001 --no-create-home \
        --home-dir /nonexistent --shell /usr/sbin/nologin afterme

# The same base image as the builder, so the venv's interpreter symlink resolves.
COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY app ./app
COPY workers ./workers
COPY cli ./cli
COPY migrations ./migrations
COPY alembic.ini ./
# PYTHONDONTWRITEBYTECODE stops *importing* from writing .pyc; compile the code once here.
RUN python -m compileall -q app workers cli

USER 10001:10001
EXPOSE 8080

# The API. uvicorn must not rewrite the client address from X-Forwarded-For / Forwarded: the
# app works out the client IP itself from AFTERME_TRUSTED_PROXY_HOPS (app/core/net.py), and
# with proxy headers on, a client could choose its own address (docs/SECURITY_REVIEW.md F10;
# README "Client IPs and proxies"). No access log (the app writes its own, without query
# strings) and no Server header. Worker processes per container: set WEB_CONCURRENCY, which
# uvicorn reads.
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port \"${PORT:-8080}\" --no-proxy-headers --no-access-log --no-server-header"]
