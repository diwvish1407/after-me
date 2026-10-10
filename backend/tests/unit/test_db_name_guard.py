from __future__ import annotations

import pytest

from tests.support import validate_test_db_name

pytestmark = pytest.mark.no_db


@pytest.mark.parametrize("name", ["afterme_test", "afterme_review_1", "afterme_test_ci"])
def test_dedicated_names_are_accepted(name: str) -> None:
    assert validate_test_db_name(name) == name


@pytest.mark.parametrize("name", ["afterme_dev", "postgres", "template1"])
def test_protected_databases_are_refused(name: str) -> None:
    with pytest.raises(RuntimeError, match="protected database"):
        validate_test_db_name(name)


def test_the_configured_dev_database_is_refused() -> None:
    with pytest.raises(RuntimeError, match="protected database"):
        validate_test_db_name("my_local_dev", dev_name="my_local_dev")
    assert validate_test_db_name("afterme_test", dev_name="my_local_dev") == "afterme_test"


@pytest.mark.parametrize("name", ["Afterme", "a;drop", "", "x" * 60])
def test_invalid_identifiers_are_refused(name: str) -> None:
    with pytest.raises(RuntimeError, match="plain lowercase identifier"):
        validate_test_db_name(name)
