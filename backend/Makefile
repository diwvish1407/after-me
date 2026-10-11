# AfterMe backend developer commands. Run from backend/.
.DEFAULT_GOAL := help
SHELL := /bin/bash

UV ?= uv

.PHONY: help setup db migrate migrate-check run test lint fmt fmt-check typecheck audit check latest-mail contracts worker engine-gate admin maintenance

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

setup: ## Install dependencies, create DB roles/databases, create .env, migrate
	$(UV) sync
	./scripts/dev_db_setup.sh
	$(UV) run python scripts/write_dev_env.py
	$(UV) run alembic upgrade head

db: ## (Re)create DB roles and databases (idempotent)
	./scripts/dev_db_setup.sh

migrate: ## Apply migrations to the dev database
	$(UV) run alembic upgrade head

migrate-check: ## Migration round trip (upgrade, downgrade, upgrade) on a throwaway database
	./scripts/migrate_check.sh

run: ## Run the API with auto-reload on http://127.0.0.1:8000
	$(UV) run uvicorn app.main:app --reload --host 127.0.0.1 --port 8000 --no-access-log --no-proxy-headers

test: ## Run the test suite with the coverage gate (85%); use `uv run pytest <path>` for a subset
	$(UV) run pytest --cov=app --cov-report=term-missing:skip-covered

lint: ## Lint
	$(UV) run ruff check .

fmt: ## Format and apply safe lint fixes
	$(UV) run ruff format .
	$(UV) run ruff check --fix .

fmt-check: ## Check formatting
	$(UV) run ruff format --check .

typecheck: ## Type-check app/ (mypy strict)
	$(UV) run mypy app

audit: ## Audit dependencies for known vulnerabilities
	$(UV) run python scripts/audit_deps.py

latest-mail: ## Print the newest dev email (signup codes, reset links) from .dev_mail/
	@f=$$(ls -t .dev_mail/*.txt 2>/dev/null | head -n 1); \
	  if [ -z "$$f" ]; then echo "no mail yet in .dev_mail/ (is AFTERME_EMAIL_PROVIDER=console?)" >&2; exit 1; fi; \
	  echo "== $$f"; cat "$$f"

contracts: ## Regenerate docs/contracts/phase2 and phase3 (*.json) after an intentional API change
	AFTERME_UPDATE_CONTRACTS=1 $(UV) run pytest tests/contracts -q

worker: ## Run the escalation worker (engine tick + outbox dispatcher)
	$(UV) run python -m workers.engine

maintenance: ## Finish account deletions once (scrub contacts, purge accounts past retention)
	$(UV) run python -m workers.maintenance

admin: ## Operator commands, e.g. `make admin ARGS="status"` or `ARGS="hold enter --reason x"`
	$(UV) run python -m cli.admin $(ARGS)

engine-gate: ## Phase 5 exit gate: the T0-T8 lifecycle 100 times in a row, then every engine suite
	LIFECYCLE_REPEATS=100 $(UV) run pytest tests/engine tests/unit/test_engine_pure.py -q

check: fmt-check lint typecheck test audit ## Format, lint, types, tests, audit (CI also runs a migration round-trip: see migrate-check)
