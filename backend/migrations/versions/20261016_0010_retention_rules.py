"""Retention of login material, devices and the audit log (DATABASE §5; PRIVACY policy).

No new tables. Grants only, applied to roles that exist: ``afterme_maintenance`` may delete

* ``sessions``, ``refresh_tokens`` and ``auth_tokens`` 30 days after they expired or were
  revoked or used (a session carries an IP hash and a user agent; a one-time token a payload
  with a new address);
* ``devices`` 90 days after they were last seen when no live session runs on them;

and, for ``audit_logs`` (it already has DELETE and ``SELECT (id, occurred_at)`` since 0001),
may additionally read ``subject_user_id``, ``resource_type`` and ``resource_id``: the purge
leaves the trail of an incident that is still open, and anything about an account that is being
deleted. It still cannot read ``metadata``.

Only the columns each rule filters on are readable: the ids, the instants, and the owner of a row
(to tell whether the account is being deleted, or has an open incident). Nothing else about a
session, a token or a device can be read by this role, and it can update none of them.

Foreign keys need nothing more: ``refresh_tokens`` cascade from their session, and the optional
references to a session or a device (``checkin_events``, ``notifications``, ``sessions``) are
``ON DELETE SET NULL``, which PostgreSQL performs with the owner's privileges.

Revision ID: 0010
Revises: 0009
Create Date: 2026-10-16 00:00:00 UTC
"""

from __future__ import annotations

from collections.abc import Sequence

from alembic import op

revision: str = "0010"
down_revision: str | None = "0009"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def _role_block(role: str, statements: str) -> str:
    return f"""
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}') THEN{statements}
  END IF;"""


_GRANT = f"""
DO $$
BEGIN{
    _role_block(
        "afterme_maintenance",
        '''
    GRANT DELETE ON sessions, refresh_tokens, auth_tokens, devices TO afterme_maintenance;
    GRANT SELECT (id, user_id, device_id, revoked_at, idle_expires_at, absolute_expires_at)
      ON sessions TO afterme_maintenance;
    GRANT SELECT (id, session_id, expires_at, used_at) ON refresh_tokens TO afterme_maintenance;
    GRANT SELECT (id, user_id, expires_at, used_at) ON auth_tokens TO afterme_maintenance;
    GRANT SELECT (id, user_id, last_seen_at) ON devices TO afterme_maintenance;
    GRANT SELECT (user_id) ON escalation_incidents TO afterme_maintenance;
    GRANT SELECT (subject_user_id, resource_type, resource_id) ON audit_logs
      TO afterme_maintenance;''',
    )
}
END
$$;
"""

_REVOKE = f"""
DO $$
BEGIN{
    _role_block(
        "afterme_maintenance",
        '''
    REVOKE ALL ON sessions, refresh_tokens, auth_tokens, devices FROM afterme_maintenance;
    REVOKE SELECT (id, user_id, device_id, revoked_at, idle_expires_at, absolute_expires_at)
      ON sessions FROM afterme_maintenance;
    REVOKE SELECT (id, session_id, expires_at, used_at) ON refresh_tokens
      FROM afterme_maintenance;
    REVOKE SELECT (id, user_id, expires_at, used_at) ON auth_tokens FROM afterme_maintenance;
    REVOKE SELECT (id, user_id, last_seen_at) ON devices FROM afterme_maintenance;
    REVOKE SELECT (user_id) ON escalation_incidents FROM afterme_maintenance;
    REVOKE SELECT (subject_user_id, resource_type, resource_id) ON audit_logs
      FROM afterme_maintenance;''',
    )
}
END
$$;
"""


def upgrade() -> None:
    op.execute(_GRANT)


def downgrade() -> None:
    op.execute(_REVOKE)
