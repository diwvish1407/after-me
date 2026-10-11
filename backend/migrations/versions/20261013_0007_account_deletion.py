"""Account deletion (DATABASE §4): what the API and the retention job may do.

No new tables. Grants only, applied to roles that exist:

* afterme_api may delete the user's wrapped key (``user_keys``): deleting an account destroys the
  key, so a ciphertext that survives in a backup can no longer be opened.
* afterme_maintenance hard-deletes accounts that have been ``pending_deletion`` for the retention
  period (the foreign keys cascade), scrubs the contacts and the name of an account whose
  all-clear has left, and records ``account.purged`` (INSERT only on ``audit_logs``). A trigger
  refuses it a DELETE of any user that is not ``pending_deletion``.

Guards (defence in depth for the account-deletion race): the API role cannot INSERT a contact,
an instruction or a wrapped key for an account that is not active, and a ``pending_deletion``
account always carries ``deletion_requested_at``.

Revision ID: 0007
Revises: 0006
Create Date: 2026-10-13 00:00:00 UTC
"""

from __future__ import annotations

from collections.abc import Sequence

from alembic import op

revision: str = "0007"
down_revision: str | None = "0006"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def _role_block(role: str, statements: str) -> str:
    return f"""
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}') THEN{statements}
  END IF;"""


_GRANT = f"""
DO $$
BEGIN{_role_block("afterme_api", "\n    GRANT DELETE ON user_keys TO afterme_api;")}{
    _role_block(
        "afterme_maintenance",
        '''
    GRANT SELECT (id, status, deletion_requested_at) ON users TO afterme_maintenance;
    GRANT DELETE ON users TO afterme_maintenance;
    GRANT SELECT (id, user_id, deleted_at) ON trusted_contacts TO afterme_maintenance;
    GRANT UPDATE (display_name, email, email_normalized, phone_e164, relationship_label,
                  is_active, deleted_at, updated_at) ON trusted_contacts TO afterme_maintenance;
    GRANT SELECT (user_id, contact_id, status) ON notifications TO afterme_maintenance;
    GRANT SELECT (user_id, display_name) ON user_profiles TO afterme_maintenance;
    GRANT UPDATE (display_name, updated_at) ON user_profiles TO afterme_maintenance;
    GRANT INSERT ON audit_logs TO afterme_maintenance;
    EXECUTE format('GRANT USAGE ON SEQUENCE %s TO afterme_maintenance',
                   pg_get_serial_sequence('public.audit_logs', 'id'));''',
    )
}
END
$$;
"""

_REVOKE = f"""
DO $$
BEGIN{_role_block("afterme_api", "\n    REVOKE DELETE ON user_keys FROM afterme_api;")}{
    _role_block(
        "afterme_maintenance",
        '''
    REVOKE ALL ON users FROM afterme_maintenance;
    REVOKE ALL ON trusted_contacts FROM afterme_maintenance;
    REVOKE SELECT (user_id, contact_id, status) ON notifications FROM afterme_maintenance;
    REVOKE ALL ON user_profiles FROM afterme_maintenance;
    REVOKE INSERT ON audit_logs FROM afterme_maintenance;
    EXECUTE format('REVOKE USAGE ON SEQUENCE %s FROM afterme_maintenance',
                   pg_get_serial_sequence('public.audit_logs', 'id'));''',
    )
}
END
$$;
"""


_GUARDS = """
CREATE OR REPLACE FUNCTION afterme_guard_active_owner() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  -- A request that was already running when the account was closed must not create anything
  -- for it: no contact to invite, no instruction, no new key.
  IF current_user = 'afterme_api'
     AND NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.user_id AND status = 'active') THEN
    RAISE EXCEPTION 'the account is not active' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$fn$;

CREATE TRIGGER afterme_guard_active_owner BEFORE INSERT ON trusted_contacts
  FOR EACH ROW EXECUTE FUNCTION afterme_guard_active_owner();
CREATE TRIGGER afterme_guard_active_owner BEFORE INSERT ON instructions
  FOR EACH ROW EXECUTE FUNCTION afterme_guard_active_owner();
CREATE TRIGGER afterme_guard_active_owner BEFORE INSERT ON user_keys
  FOR EACH ROW EXECUTE FUNCTION afterme_guard_active_owner();

CREATE OR REPLACE FUNCTION afterme_guard_user_purge() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF current_user = 'afterme_maintenance' AND OLD.status <> 'pending_deletion' THEN
    RAISE EXCEPTION 'only a closed account can be purged' USING ERRCODE = '42501';
  END IF;
  RETURN OLD;
END
$fn$;

CREATE TRIGGER afterme_guard_user_purge BEFORE DELETE ON users
  FOR EACH ROW EXECUTE FUNCTION afterme_guard_user_purge();
"""

_UNGUARD = """
DROP TRIGGER IF EXISTS afterme_guard_user_purge ON users;
DROP FUNCTION IF EXISTS afterme_guard_user_purge();
DROP TRIGGER IF EXISTS afterme_guard_active_owner ON user_keys;
DROP TRIGGER IF EXISTS afterme_guard_active_owner ON instructions;
DROP TRIGGER IF EXISTS afterme_guard_active_owner ON trusted_contacts;
DROP FUNCTION IF EXISTS afterme_guard_active_owner();
"""


def upgrade() -> None:
    op.create_check_constraint(
        op.f("ck_users_pending_has_request"),
        "users",
        "status <> 'pending_deletion' OR deletion_requested_at IS NOT NULL",
    )
    op.execute(_GUARDS)
    op.execute(_GRANT)


def downgrade() -> None:
    op.execute(_REVOKE)
    op.execute(_UNGUARD)
    op.execute("ALTER TABLE users DROP CONSTRAINT IF EXISTS ck_users_pending_has_request")
