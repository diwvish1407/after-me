"""Ownership convention (ARCHITECTURE §4.3): repositories for user-owned rows have no unscoped
lookups. Every public method takes a keyword-only ``owner_id``; exceptions are listed here with
the reason, so adding one is a reviewed decision."""

from __future__ import annotations

import importlib
import inspect
import pkgutil

import pytest

import app

pytestmark = pytest.mark.no_db

# (class, method) → why it may run without owner_id
EXEMPT: dict[tuple[str, str], str] = {
    ("UserRepository", "get"): "users rows are the owners themselves",
    ("UserRepository", "get_by_email"): "sign-in and signup find the account by email",
    ("UserRepository", "insert_if_absent"): "creates the owner row",
    ("UserRepository", "record_failed_login"): "login bookkeeping on the owner row",
    ("AuthTokenRepository", "find_link"): "lookup by SHA-256 of the presented link secret",
    ("RefreshTokenRepository", "find_owner"): "lookup by SHA-256 of the presented secret",
    ("RefreshTokenRepository", "lock_by_hash"): "secret hash within a session already resolved",
    ("RefreshTokenRepository", "lock_in_session"): "session_id resolved by an owner-scoped query",
    ("RefreshTokenRepository", "create"): "session_id resolved by an owner-scoped query",
    # Contact-facing lookups (Phase 3): the caller is a contact holding a secret link, not a
    # signed-in user, so the secret is the credential. ContactRepository has NO exemption.
    ("PortalRepository", "find_invitation"): "lookup by SHA-256 of the presented invitation token",
    ("PortalRepository", "get_contact"): "contact ID proven by an invitation hash or opt-out MAC",
    ("PortalRepository", "answer_invitation"): "UPDATE keyed by the SHA-256 of the presented token",
    ("PortalRepository", "invalidate_invitations"): "contact ID proven by a presented token",
    (
        "InstructionRepository",
        "categories",
    ): "reference data: the categories are the same for everyone",
    (
        "InstructionRepository",
        "category_exists",
    ): "reference data: the categories are the same for everyone",
    ("SuppressionRepository", "is_suppressed"): "the suppression list is global by design",
    ("SuppressionRepository", "add"): "the suppression list is global by design",
    ("SuppressionRepository", "lock_address"): "advisory lock keyed by an address hash, no rows",
    (
        "SuppressionRepository",
        "opt_out_all_contacts_with_email",
    ): "THE deliberate cross-user write: a person blocking their address everywhere; see "
    "tests/security/test_cross_user_write.py",
}


def _repository_classes() -> list[type]:
    classes: list[type] = []
    for module_info in pkgutil.walk_packages(app.__path__, prefix="app."):
        if not module_info.name.endswith(".repository"):
            continue
        module = importlib.import_module(module_info.name)
        for _, cls in inspect.getmembers(module, inspect.isclass):
            if cls.__module__ == module.__name__ and cls.__name__.endswith("Repository"):
                classes.append(cls)
    return classes


def test_repositories_are_discovered() -> None:
    names = {cls.__name__ for cls in _repository_classes()}
    assert {"SessionRepository", "DeviceRepository", "ProfileRepository"} <= names
    assert {"ContactRepository", "PortalRepository", "SuppressionRepository"} <= names


def test_contact_repository_has_no_exemption() -> None:
    """Another user's contact must be unreachable through the owner-facing repository."""
    assert not [key for key in EXEMPT if key[0] == "ContactRepository"]


def test_only_one_contact_repository_method_writes_across_users() -> None:
    cross_user = [
        key for key in EXEMPT if key[0] == "SuppressionRepository" and "opt_out" in key[1]
    ]
    assert cross_user == [("SuppressionRepository", "opt_out_all_contacts_with_email")]


@pytest.mark.parametrize("cls", _repository_classes(), ids=lambda c: c.__name__)
def test_every_owned_method_requires_owner_id(cls: type) -> None:
    for name, method in inspect.getmembers(cls, inspect.iscoroutinefunction):
        if name.startswith("_") or (cls.__name__, name) in EXEMPT:
            continue
        parameters = inspect.signature(method).parameters
        owner = parameters.get("owner_id")
        assert owner is not None, f"{cls.__name__}.{name} must take owner_id"
        assert owner.kind is inspect.Parameter.KEYWORD_ONLY, f"{cls.__name__}.{name}"
        assert owner.default is inspect.Parameter.empty, f"{cls.__name__}.{name}"


def test_exemptions_are_not_stale() -> None:
    methods = {
        (cls.__name__, name)
        for cls in _repository_classes()
        for name, _ in inspect.getmembers(cls, inspect.iscoroutinefunction)
    }
    assert set(EXEMPT) <= methods
