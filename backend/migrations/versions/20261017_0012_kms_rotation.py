"""Key rotation (SECURITY §6.2; DEPLOYMENT §9): what ``cli.admin kms rewrap | rotate-user`` needs.

No new tables. One grant and one guard, applied to roles that exist:

* ``afterme_api`` may UPDATE ``wrapped_dek``, ``kek_id``, ``dek_version`` and ``rotated_at`` of
  ``user_keys``. The operator commands run as the API role (the only role that may read content
  and keys; the worker has nothing on ``user_keys``), so they need to rewrite a wrapped key
  (re-wrap) and to replace a user's key (per-user DEK rotation). ``user_id`` and ``created_at``
  stay unwritable. The role could already DELETE a key (account deletion) and INSERT one, so this
  adds no power over what the role can destroy; it adds the ability to replace.
* A guard refuses an UPDATE that would move ``dek_version`` backwards or by more than one:
  a ciphertext is bound to the version it was sealed under (``instruction_aad``), so a key that
  went "back" would make the instructions sealed in between unreadable, and a jump would skip
  the version the rotation has to re-encrypt.

Revision ID: 0012
Revises: 0011
Create Date: 2026-10-17 00:00:00 UTC
"""

from __future__ import annotations

from collections.abc import Sequence

from alembic import op

revision: str = "0012"
down_revision: str | None = "0011"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_GRANT = """
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_api') THEN
    GRANT UPDATE (wrapped_dek, kek_id, dek_version, rotated_at) ON user_keys TO afterme_api;
  END IF;
END
$$;
"""

_REVOKE = """
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_api') THEN
    REVOKE UPDATE (wrapped_dek, kek_id, dek_version, rotated_at) ON user_keys FROM afterme_api;
  END IF;
END
$$;
"""

_GUARD = """
CREATE OR REPLACE FUNCTION afterme_guard_dek_version() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF NEW.dek_version < OLD.dek_version OR NEW.dek_version > OLD.dek_version + 1 THEN
    RAISE EXCEPTION 'a key version moves forward by one' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$fn$;

CREATE TRIGGER afterme_guard_dek_version BEFORE UPDATE ON user_keys
  FOR EACH ROW EXECUTE FUNCTION afterme_guard_dek_version();
"""

_UNGUARD = """
DROP TRIGGER IF EXISTS afterme_guard_dek_version ON user_keys;
DROP FUNCTION IF EXISTS afterme_guard_dek_version();
"""


def upgrade() -> None:
    op.execute(_GUARD)
    op.execute(_GRANT)


def downgrade() -> None:
    op.execute(_REVOKE)
    op.execute(_UNGUARD)
