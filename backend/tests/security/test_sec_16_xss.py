"""SEC-16: markup in a name, label, title or body is shown as text, everywhere (TEST_PLAN §5.2).

Names are free text that other people's pages and mailboxes render: the owner's display name
appears on the recipient portal and in every contact email; a contact's name appears on the
owner's web page and in the owner's emails; instruction text appears on the portal. The release
tests cover the instruction text on one page. This runs one account whose owner name, contact
names, relationship label, instruction title and body are all markup, through the whole
lifecycle, and checks every page and every email it produced:

* HTML pages: no element and no attribute a payload could have added, no script without the
  response's nonce, and the text there but escaped;
* emails: the HTML part has only the elements the template itself writes, the payload is escaped
  wherever the plain-text part carries it, the subject cannot break its header, and the text
  part is plain text (not escaped twice);
* the JSON API returns the same text as data, with a JSON content type and ``nosniff``.

(Names pass the validators on purpose: ``<``, ``>`` and quotes are not links, and refusing them
would break names like "O'Neil". Escaping on output is what makes them safe.)
"""

from __future__ import annotations

import re
from datetime import timedelta
from html import escape as html_escape

import httpx
from markupsafe import escape as jinja_escape

from tests.engine.test_release import STAGE_2, _link_token, _make, address
from tests.engine.test_web_checkin import _sign_in
from tests.security.sec_support import assert_inert, csrf_of, elements
from tests.security.test_sec_12_cross_incident_portal import Browser
from tests.support import PASSWORD
from tests.world import Person, World

OWNER = "<img src=x onerror=alert(1)>"
MOM = "<b>Mom</b>"
BROTHER = '"><script>alert(1)</script>'
LABEL = "' onfocus='alert(1)"
TITLE = "</title><svg/onload=alert(1)>"
BODY = '"><script>alert(2)</script><img src=x onerror=alert(3)>'
PAYLOADS = (OWNER, MOM, BROTHER, LABEL, TITLE, BODY)
# a link token in the URL, as a hostile page would put it, echoed into an attribute by one page
HOSTILE_TOKEN = '"><script>alert(4)</script>'

EMAIL_TAGS = {"html", "head", "meta", "body", "div", "p", "br", "ul", "li", "a"}
CSRF_FIELD = re.compile(r'name="key" value="([^"]+)"')
INCIDENT_FIELD = re.compile(r'name="incident_id" value="([^"]+)"')


async def _owner_with_markup_everywhere(world: World) -> Person:
    person = await world.person("owner@example.com", premium=True)
    await world.login(person)
    renamed = await world.h.client.patch(
        "/v1/me/profile", json={"display_name": OWNER}, headers=person.headers
    )
    assert renamed.status_code == 200, renamed.text
    for label, name, extra in (
        ("Mom", MOM, {}),
        ("Brother", BROTHER, {"relationship": "other", "relationship_label": LABEL}),
    ):
        email = address(person, label)
        made = await world.h.add_contact(person.tokens, email, name=name, **extra)
        assert made.status_code == 201, made.text
        person.contacts[label] = str(made.json()["id"])
        world.db.execute(
            "UPDATE trusted_contacts SET verification_status = 'verified', verified_at = now() "
            "WHERE id = %s",
            (person.contacts[label],),
        )
    # somebody who has been invited and has not answered: the invitation page names the owner
    waiting = await world.h.add_contact(person.tokens, address(person, "Sam"), name="Sam")
    assert waiting.status_code == 201, waiting.text
    await world.plan(person, [(180, ["Mom"]), (1440, ["Brother"])])
    await world.activate(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    await _make(world, person, "Brother", TITLE, BODY)
    return person


def _inspect(label: str, response: httpx.Response, *, expect_escaped: tuple[str, ...] = ()) -> None:
    csp = response.headers.get("content-security-policy")
    assert csp is not None, label
    assert_inert(response.text, csp=csp, where=label)
    for payload in PAYLOADS:
        assert payload not in response.text, (label, "raw", payload)
    for shown in expect_escaped:
        assert str(jinja_escape(shown)) in response.text, (label, "escaped text missing", shown)


async def test_markup_in_names_labels_and_instructions_is_inert_in_every_page_and_email(
    world: World,
) -> None:
    person = await _owner_with_markup_everywhere(world)
    pages: list[tuple[str, httpx.Response]] = []

    # the invitation page a contact opens, with the owner's name in it
    invited = Browser(world)
    try:
        token = world.h.invitation_token_for(address(person, "Sam"))
        landing = await invited.post("/c/session", token=token)
        assert landing.status_code == 200, landing.text
        _inspect("invitation page", landing, expect_escaped=(OWNER,))
        pages.append(("invitation page", landing))
    finally:
        await invited.close()

    await world.advance_to(STAGE_2 + timedelta(minutes=6))
    link = _link_token(world, person, "Brother")

    # the owner's own page (signed in on the web), with both contacts' names in it
    assert (await _sign_in(world, person)).status_code == 303
    state = await world.h.client.get("/a/checkin")
    _inspect("state page", state, expect_escaped=(OWNER, MOM, BROTHER))
    pages.append(("state page", state))

    # the contact's pages: link, code, content, and a link that is not one
    visitor = Browser(world)
    try:
        opened = await visitor.open(link)
        _inspect("portal: code offer", opened, expect_escaped=(OWNER,))
        sent = await visitor.code()
        _inspect("portal: code entry", sent)
        content = await visitor.verify(visitor.last_code(person, "Brother"))
        assert content.status_code == 200
        _inspect("portal: content", content, expect_escaped=(OWNER, TITLE, BODY))
        bad = await visitor.post("/c/release/session", token=HOSTILE_TOKEN)
        assert bad.status_code == 400
        _inspect("portal: bad link", bad, expect_escaped=(HOSTILE_TOKEN,))
        pages += [("portal: code offer", opened), ("portal: content", content), ("bad", bad)]

        # the owner tells everyone they are safe: the page names who was told
        csrf = csrf_of(state)
        key, incident = CSRF_FIELD.search(state.text), INCIDENT_FIELD.search(state.text)
        assert key is not None
        assert incident is not None
        safe = await world.h.client.post(
            "/a/safe",
            data={
                "key": key[1],
                "incident_id": incident[1],
                "password": PASSWORD,
                "csrf": csrf,
            },
        )
        assert safe.status_code == 200, safe.text
        _inspect("safe page", safe, expect_escaped=(MOM, BROTHER))
        pages.append(("safe page", safe))
        gone = await visitor.post("/c/release/view")  # taken back: names the owner
        assert "no longer available" in gone.text
        _inspect("portal: taken back", gone, expect_escaped=(OWNER,))
    finally:
        await visitor.close()

    await world.advance(minutes=10)  # the all-clears and the confirmations go out

    # --- the JSON API: data, not markup ------------------------------------------------------
    await world.login(person)
    for path in ("/v1/me", "/v1/contacts"):
        response = await world.h.client.get(path, headers=person.headers)
        assert response.headers["content-type"].startswith("application/json"), path
        assert response.headers["x-content-type-options"] == "nosniff"
    me = (await world.h.client.get("/v1/me", headers=person.headers)).json()
    assert me["profile"]["display_name"] == OWNER  # returned exactly as typed: data, not markup
    contacts = (await world.h.client.get("/v1/contacts", headers=person.headers)).json()["items"]
    by_name = {c["display_name"]: c for c in contacts}
    assert set(by_name) == {MOM, BROTHER, "Sam"}
    assert by_name[BROTHER]["relationship_label"] == LABEL

    # --- every email the lifecycle sent ------------------------------------------------------
    messages = world.mail.messages
    assert len(messages) >= 10
    carriers: dict[str, set[str]] = {p: set() for p in PAYLOADS}
    for message in messages:
        label = f"email {message.template}"
        assert message.html is not None, label
        assert_inert(message.html, allowed_tags=EMAIL_TAGS, where=label)
        for tag, attrs in elements(message.html):
            if tag == "a":
                assert (attrs.get("href") or "").startswith(("https://", "http://")), label
        assert "\r" not in message.subject
        assert "\n" not in message.subject
        for entity in ("&lt;", "&gt;", "&quot;", "&#"):
            assert entity not in message.text, (label, "the text part is escaped", entity)
        for payload in PAYLOADS:
            if payload in message.text or payload in message.subject:
                carriers[payload].add(message.template)
            # the HTML part never carries a payload raw, but carries it (escaped) when the
            # text part does
            assert payload not in message.html, (label, "raw", payload)
            if payload in message.text:
                assert html_escape(payload, quote=True) in message.html, (label, payload)

    # the names really did travel through the emails (so the checks above had work to do) ...
    assert carriers[OWNER], "the owner's name reached no email"
    assert carriers[MOM], "the first contact's name reached no email"
    assert carriers[BROTHER], "the second contact's name reached no email"
    # ... and what is never put in an email (SEC-20) stayed out
    assert carriers[TITLE] == set()
    assert carriers[BODY] == set()
    assert carriers[LABEL] == set()
    for message in messages:
        for payload in (TITLE, BODY):
            assert payload not in f"{message.subject}{message.text}{message.html}"
