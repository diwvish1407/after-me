"""Alembic environment. Migrations run as the afterme_owner role with a synchronous psycopg URL.

URL precedence: ``sqlalchemy.url`` set programmatically (tests) → ``AFTERME_MIGRATION_DATABASE_URL``
(backend/.env is read in dev only).
"""

from __future__ import annotations

from logging.config import fileConfig

from alembic import context
from sqlalchemy import create_engine, pool

from app.core.config import load_migration_database_url
from app.models import metadata

config = context.config

if config.config_file_name is not None and config.attributes.get("configure_logger", True):
    fileConfig(config.config_file_name, disable_existing_loggers=False)

target_metadata = metadata


def _database_url() -> str:
    return config.get_main_option("sqlalchemy.url") or load_migration_database_url()


def run_migrations_offline() -> None:
    context.configure(
        url=_database_url(),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    engine = create_engine(
        _database_url(),
        poolclass=pool.NullPool,
        hide_parameters=True,
        connect_args={"application_name": "afterme-migrate", "options": "-c lock_timeout=10000"},
    )
    with engine.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            compare_type=True,
            transaction_per_migration=True,
        )
        with context.begin_transaction():
            context.run_migrations()
    engine.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
