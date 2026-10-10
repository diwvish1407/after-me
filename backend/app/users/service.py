"""Profile reads and updates for the signed-in user (API_SPEC §3)."""

from __future__ import annotations

from app.api.deps import CurrentUser
from app.audit import writer as audit
from app.auth.base import AuthServiceBase
from app.auth.models import User
from app.checkins.repository import CheckinConfigRepository
from app.checkins.service import restart_clock
from app.core.errors import IncidentOpen, NotFound, SessionRevoked
from app.users.models import UserProfile
from app.users.schemas import MeResponse, ProfileOut, ProfilePatchRequest


def _me(user: User, profile: UserProfile | None) -> MeResponse:
    return MeResponse(
        id=user.id,
        email=user.email,
        tier=user.tier,
        status=user.status,
        profile=(
            ProfileOut(
                display_name=profile.display_name,
                phone_e164=profile.phone_e164,
                country_code=profile.country_code,
                timezone=profile.timezone,
                locale=profile.locale,
            )
            if profile is not None
            else None
        ),
        created_at=user.created_at,
    )


class UserService(AuthServiceBase):
    async def get_me(self, current: CurrentUser) -> MeResponse:
        user = await self.users.get(current.user_id)
        if user is None:  # pragma: no cover - the session check already loaded this user
            raise SessionRevoked
        profile = await self.profiles.get(owner_id=current.user_id)
        await self.session.commit()
        return _me(user, profile)

    async def update_profile(self, current: CurrentUser, patch: ProfilePatchRequest) -> MeResponse:
        """Apply the fields present in ``patch``. Only real changes are audited; a timezone change
        is user-visible. A timezone change also restarts an active check-in schedule in the new
        zone (ESCALATION_ENGINE §3.4), and is refused while an incident is open."""
        now = await self._now()
        user = await self.users.get(current.user_id)
        changes = patch.changes()
        # Lock order (ESCALATION_ENGINE §6.2): the check-in configuration before anything else.
        config = (
            await CheckinConfigRepository(self.session).get(
                owner_id=current.user_id, for_update=True
            )
            if "timezone" in changes
            else None
        )
        profile = await self.profiles.get(owner_id=current.user_id, for_update=True)
        if user is None or profile is None:  # pragma: no cover - created at signup verification
            raise NotFound
        changed = sorted(name for name, value in changes.items() if getattr(profile, name) != value)
        if "timezone" in changed and config is not None:
            if config.status == "incident_open":
                raise IncidentOpen  # nothing has been modified yet
            config.version += 1  # the representation (its timezone) changed
            config.updated_at = now
            if config.status == "active":
                restart_clock(config, changes["timezone"], now)
                await self.services.audit.record(
                    self.session,
                    self._event(
                        audit.SCHEDULE_UPDATED,
                        now,
                        current.user_id,
                        resource_type="schedule",
                        resource_id=current.user_id,
                        fields="timezone",
                        active=True,
                    ),
                )
        if changed:
            for name in changed:
                setattr(profile, name, changes[name])
            profile.updated_at = now
            await self.services.audit.record(
                self.session,
                self._event(
                    audit.PROFILE_UPDATED,
                    now,
                    current.user_id,
                    resource_type="profile",
                    resource_id=current.user_id,
                    fields=".".join(changed),
                ),
            )
            if "timezone" in changed:
                await self.services.audit.record(
                    self.session,
                    self._event(
                        audit.PROFILE_TIMEZONE_CHANGED,
                        now,
                        current.user_id,
                        resource_type="profile",
                        resource_id=current.user_id,
                        user_visible=True,
                    ),
                )
        await self.session.commit()
        return _me(user, profile)
