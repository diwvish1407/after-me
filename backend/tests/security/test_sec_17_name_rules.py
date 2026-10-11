"""SEC-17: the display-name rules hold at every door that takes a name (TEST_PLAN §5.2; T26).

A name is what an email says the message is "from" and who it is "about": it is the phishing
surface (SECURITY T26). ``test_validation.py`` proves the rules on the registration model. This
proves them where a stored name is changed by an API call: the profile, and the contacts'
``display_name`` and ``relationship_label``, on create and on update, and that a refusal stores
nothing and sends nothing.

Known look-alike bypasses (an IDN top-level domain, fullwidth dots, accented brand letters) are
tracked separately and are not asserted here.
"""

from __future__ import annotations

from typing import Any

import psycopg
import pytest

from tests.security.sec_support import assert_unchanged, snapshot
from tests.support import Harness, bearer, make_premium, problem

Db = psycopg.Connection[dict[str, Any]]

# Spelled as code points so that no invisible character sits in this file.
RLO, LRI, ZWSP = chr(0x202E), chr(0x2066), chr(0x200B)

# (name, the code the 422 must carry)
BAD_NAMES: list[tuple[str, str]] = [
    ("Visit https://evil.example", "display_name_link"),
    ("www.evil", "display_name_link"),
    ("support.afterme.com", "display_name_link"),
    ("someone@example.com", "display_name_link"),
    ("evil.com", "display_name_link"),
    ("AfterMe Security", "display_name_reserved"),
    ("After Me Team", "display_name_reserved"),
    ("AFT3R-ME", "display_name_reserved"),
    (chr(0x410) + "fter" + chr(0x41C) + "e", "display_name_reserved"),  # Cyrillic A, M
    ("Mallory" + RLO, "invalid_characters"),  # right-to-left override
    ("Bad\x00Name", "invalid_characters"),
    ("Zero" + ZWSP + "Width", "invalid_characters"),
    ("Isolate" + LRI + "Name", "invalid_characters"),
    ("x" * 81, "too_long"),
    ("   ", "too_short"),
]
GOOD_NAMES = ["José Ñúñez", "李小龍", "Mary-Kate O'Neil", "Dr. Who"]

# The label is free text too ("Godmother"): the same character and link rules, 40 characters.
BAD_LABELS: list[tuple[str, str]] = [
    ("see https://evil.example", "contains_link"),
    ("www.evil", "contains_link"),
    ("write to a@b.co", "contains_link"),
    ("evil.com", "contains_link"),
    ("Mallory" + RLO, "invalid_characters"),
    ("Bad\x00Label", "invalid_characters"),
    ("Zero" + ZWSP + "Width", "invalid_characters"),
    ("x" * 41, "too_long"),
    ("   ", "too_short"),
]
GOOD_LABELS = ["Godmother", "Family friend", "Neighbour upstairs"]

EMAIL = "namer@example.com"


async def _contact(h: Harness, tokens: dict[str, Any]) -> str:
    made = await h.add_contact(
        tokens,
        "pat@example.com",
        name="Pat",
        relationship="other",
        relationship_label="Godmother",
    )
    assert made.status_code == 201, made.text
    return str(made.json()["id"])


def _refusal(response: Any, field: str, code: str, sent: str) -> None:
    assert response.status_code == 422, (sent, response.status_code, response.text)
    body = problem(response)
    assert body["code"] == "validation_failed"
    assert (field, code) in {(e["field"], e["code"]) for e in body["errors"]}, (
        sent,
        body["errors"],
    )
    visible = sent.strip()
    if visible:
        assert visible not in response.text  # the refused text is not echoed back


@pytest.mark.no_rate_limit
async def test_the_profile_name_rules_apply_to_a_patch(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(EMAIL)
    path, headers = "/v1/me/profile", bearer(tokens)
    before = snapshot(owner_db)
    mail = len(h.mail.messages)
    for name, code in BAD_NAMES:
        response = await h.client.patch(path, json={"display_name": name}, headers=headers)
        _refusal(response, "display_name", code, name)
    assert_unchanged(before, snapshot(owner_db), "a refused profile name")
    assert len(h.mail.messages) == mail
    me = (await h.client.get("/v1/me", headers=headers)).json()
    assert me["profile"]["display_name"] == "Test User"  # the stored name did not move

    for name in GOOD_NAMES:  # the control: the same route takes a real name
        response = await h.client.patch(path, json={"display_name": name}, headers=headers)
        assert response.status_code == 200, (name, response.text)
        assert response.json()["profile"]["display_name"] == name


@pytest.mark.no_rate_limit
async def test_the_contact_name_rules_apply_to_a_create_and_to_a_patch(
    h: Harness, owner_db: Db
) -> None:
    tokens = await h.signup(EMAIL)
    make_premium(owner_db, EMAIL)  # the free plan has room for one contact
    contact = await _contact(h, tokens)
    headers = bearer(tokens)
    before = snapshot(owner_db)
    mail = len(h.mail.messages)
    for index, (name, code) in enumerate(BAD_NAMES):
        created = await h.client.post(
            "/v1/contacts",
            json={
                "display_name": name,
                "relationship": "friend",
                "email": f"new{index}@example.com",
            },
            headers=headers,
        )
        _refusal(created, "display_name", code, name)
        patched = await h.client.patch(
            f"/v1/contacts/{contact}", json={"display_name": name}, headers=headers
        )
        _refusal(patched, "display_name", code, name)
    assert_unchanged(before, snapshot(owner_db), "a refused contact name")
    assert len(h.mail.messages) == mail  # no invitation went to anyone

    for index, name in enumerate(GOOD_NAMES):  # the control
        created = await h.client.post(
            "/v1/contacts",
            json={
                "display_name": name,
                "relationship": "friend",
                "email": f"good{index}@example.com",
            },
            headers=headers,
        )
        assert created.status_code == 201, (name, created.text)
        assert created.json()["display_name"] == name
    patched = await h.client.patch(
        f"/v1/contacts/{contact}", json={"display_name": GOOD_NAMES[0]}, headers=headers
    )
    assert patched.status_code == 200


@pytest.mark.no_rate_limit
async def test_the_relationship_label_rules_apply_to_a_create_and_to_a_patch(
    h: Harness, owner_db: Db
) -> None:
    tokens = await h.signup(EMAIL)
    make_premium(owner_db, EMAIL)  # the free plan has room for one contact
    contact = await _contact(h, tokens)
    headers = bearer(tokens)
    before = snapshot(owner_db)
    mail = len(h.mail.messages)
    for index, (label, code) in enumerate(BAD_LABELS):
        created = await h.client.post(
            "/v1/contacts",
            json={
                "display_name": "Someone",
                "relationship": "other",
                "relationship_label": label,
                "email": f"label{index}@example.com",
            },
            headers=headers,
        )
        _refusal(created, "relationship_label", code, label)
        patched = await h.client.patch(
            f"/v1/contacts/{contact}", json={"relationship_label": label}, headers=headers
        )
        _refusal(patched, "relationship_label", code, label)
    assert_unchanged(before, snapshot(owner_db), "a refused relationship label")
    assert len(h.mail.messages) == mail
    stored = (await h.client.get(f"/v1/contacts/{contact}", headers=headers)).json()
    assert stored["relationship_label"] == "Godmother"

    for index, label in enumerate(GOOD_LABELS):  # the control
        created = await h.client.post(
            "/v1/contacts",
            json={
                "display_name": "Someone",
                "relationship": "other",
                "relationship_label": label,
                "email": f"fine{index}@example.com",
            },
            headers=headers,
        )
        assert created.status_code == 201, (label, created.text)
        assert created.json()["relationship_label"] == label
    patched = await h.client.patch(
        f"/v1/contacts/{contact}", json={"relationship_label": GOOD_LABELS[0]}, headers=headers
    )
    assert patched.status_code == 200


@pytest.mark.no_rate_limit
async def test_registration_refuses_the_same_names_and_creates_nothing(
    h: Harness, owner_db: Db
) -> None:
    before = snapshot(owner_db)
    for index, (name, code) in enumerate(BAD_NAMES):
        response = await h.register(f"newcomer{index}@example.com", display_name=name)
        _refusal(response, "display_name", code, name)
    assert_unchanged(before, snapshot(owner_db), "a refused registration")
    assert h.mail.messages == []
    ok = await h.register("newcomer@example.com", display_name=GOOD_NAMES[0])
    assert ok.status_code == 202
