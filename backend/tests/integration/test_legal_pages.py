"""``/legal``, ``/legal/privacy``, ``/legal/terms`` and ``/support`` (Phase 12).

Public pages: no session, no cookie, no form. The privacy policy and the terms are converted
from the counsel drafts in ``docs/legal``: every fact the drafts left in [brackets] comes from
the settings, counsel's notes and the open-points lists are not on the page, and a banner says
"draft" until ``LEGAL_DOCUMENTS_FINAL`` is switched on.
"""

from __future__ import annotations

import html
import re

import httpx
import pytest

from tests.support import Harness
from tests.world import World

PAGES = ["/legal", "/legal/privacy", "/legal/terms", "/support"]
DRAFT = "DRAFT — not yet reviewed by counsel"
FACTS = {
    "legal_operator_name": "Example Labs Pvt Ltd",
    "legal_contact_email": "privacy@afterme.example",
    "legal_postal_address": "1 Example Road, Mumbai 400001",
    "legal_effective_date": "2026-11-01",
    "legal_version": "1.0",
    "support_email": "help@afterme.example",
    "abuse_email": "abuse@afterme.example",
}


def _visible(page: str) -> str:
    """The words a reader sees."""
    page = re.sub(r"<(script|style).*?</\1>", "", page, flags=re.DOTALL | re.IGNORECASE)
    return html.unescape(re.sub(r"<[^>]+>", " ", page))


@pytest.mark.parametrize("path", PAGES)
async def test_the_pages_are_public_html_with_the_page_security_headers(
    h: Harness, path: str
) -> None:
    response = await h.client.get(path)
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    headers = response.headers
    csp = headers["content-security-policy"]
    assert "default-src 'none'" in csp
    assert "frame-ancestors 'none'" in csp
    assert re.search(r"script-src 'nonce-[A-Za-z0-9_-]{16,}'", csp)
    assert headers["referrer-policy"] == "no-referrer"
    assert headers["x-content-type-options"] == "nosniff"
    assert headers["x-frame-options"] == "DENY"
    assert headers["permissions-policy"].startswith("camera=()")
    # no per-person content: a short public cache is fine (everything else is no-store)
    assert headers["cache-control"] == "public, max-age=300"
    assert "<title>" in response.text
    assert "<script" not in response.text  # nothing inline to run


@pytest.mark.parametrize("path", PAGES)
async def test_the_pages_set_no_cookie_and_need_no_session(h: Harness, path: str) -> None:
    for _ in range(2):
        response = await h.client.get(path)
        assert "set-cookie" not in response.headers
    assert len(h.client.cookies.jar) == 0
    # a stranger's cookies and credentials make no difference to what is shown
    other = await h.client.get(
        path, headers={"Authorization": "Bearer nonsense", "Cookie": "__Host-afterme_csrf=x"}
    )
    assert other.status_code == 200
    assert "set-cookie" not in other.headers


@pytest.mark.parametrize("path", PAGES)
async def test_the_pages_are_get_only(h: Harness, path: str) -> None:
    assert (await h.client.post(path, data={"x": "y"})).status_code == 405
    assert (await h.client.put(path)).status_code == 405
    assert (await h.client.delete(path)).status_code == 405


async def test_every_response_has_its_own_nonce(h: Harness) -> None:
    nonces = {
        re.search(
            r"'nonce-([^']+)'",
            (await h.client.get("/legal/privacy")).headers["content-security-policy"],
        )[1]  # type: ignore[index]
        for _ in range(3)
    }
    assert len(nonces) == 3


# --- the texts ---------------------------------------------------------------------------------


@pytest.mark.parametrize("path", ["/legal/privacy", "/legal/terms"])
async def test_no_placeholder_counsel_note_or_open_point_is_on_the_page(
    h: Harness, path: str
) -> None:
    text = _visible((await h.client.get(path)).text)
    assert not re.search(r"\[[^\]]*\]", text), re.findall(r"\[[^\]]*\]", text)
    for forbidden in ("Counsel", "counsel:", "Open points", "open points", "remove before", "TODO"):
        assert forbidden not in text.replace(DRAFT, ""), forbidden
    assert "{{" not in text
    assert "None" not in text


async def test_the_privacy_policy_says_what_the_draft_says(h: Harness) -> None:
    text = " ".join(_visible((await h.client.get("/legal/privacy")).text).split())
    for sentence in (
        "Privacy policy",
        "Who we are",
        "Information we process",
        "not end-to-end encrypted",
        "We do not sell personal data",
        "only strictly necessary cookies",
        "Deleted accounts",
        "AfterMe is for people 18 and over",
        "We do not collect your location",
    ):
        assert sentence in text, sentence
    assert "400 days" in text
    assert "1 year" in text  # the audit retention, from AFTERME_AUDIT_RETENTION_DAYS
    assert "/a/delete" in text


async def test_the_terms_say_what_the_draft_says(h: Harness) -> None:
    text = " ".join(_visible((await h.client.get("/legal/terms")).text).split())
    for sentence in (
        "Terms of service",
        "AfterMe is not an emergency service",
        "do not guarantee",
        "Not a will or a legal instrument",
        "Acceptable use",
        "18 or older",
        "Suspension and ending",
    ):
        assert sentence in text, sentence


@pytest.mark.settings(audit_retention_days=730)
async def test_the_audit_retention_follows_the_setting(h: Harness) -> None:
    assert "730 days" in _visible((await h.client.get("/legal/privacy")).text)


async def test_the_index_and_the_footer_link_the_documents(h: Harness) -> None:
    for path in ("/legal", "/legal/privacy", "/legal/terms"):
        page = (await h.client.get(path)).text
        for target in ("/legal/privacy", "/legal/terms", "/support"):
            assert f'href="{target}"' in page, (path, target)


# --- the draft banner --------------------------------------------------------------------------


@pytest.mark.parametrize("path", ["/legal", "/legal/privacy", "/legal/terms"])
async def test_a_visible_draft_banner_until_the_documents_are_final(h: Harness, path: str) -> None:
    page = (await h.client.get(path)).text
    assert DRAFT in html.unescape(page)
    assert 'class="notice"' in page
    assert html.unescape(page).index(DRAFT) < page.index("<h2>") if "<h2>" in page else True
    assert "Not yet in force" in page


@pytest.mark.parametrize("path", ["/legal", "/legal/privacy", "/legal/terms"])
@pytest.mark.settings(legal_documents_final=True, **FACTS)
async def test_final_documents_have_no_banner_and_show_version_and_date(
    h: Harness, path: str
) -> None:
    page = html.unescape((await h.client.get(path)).text)
    assert DRAFT not in page
    assert "draft" not in _visible(page).lower()
    assert "Version 1.0" in page
    assert "Effective 1 November 2026" in page
    assert "Not yet in force" not in page


async def test_the_support_page_has_no_banner(h: Harness) -> None:
    assert DRAFT not in html.unescape((await h.client.get("/support")).text)


# --- the facts ---------------------------------------------------------------------------------


@pytest.mark.settings(**FACTS)
async def test_the_operators_facts_come_from_the_settings(h: Harness) -> None:
    privacy = _visible((await h.client.get("/legal/privacy")).text)
    assert "Example Labs Pvt Ltd" in privacy
    assert "privacy@afterme.example" in privacy
    assert "1 Example Road, Mumbai 400001" in privacy
    assert "https://afterme.test/a/delete" in privacy
    raw = (await h.client.get("/legal/privacy")).text
    assert 'href="mailto:privacy@afterme.example"' in raw
    terms = _visible((await h.client.get("/legal/terms")).text)
    assert "Example Labs Pvt Ltd" in terms
    assert "help@afterme.example" in terms
    assert "1 Example Road, Mumbai 400001" in terms
    assert "Effective 1 November 2026" in privacy  # shown as given, final or not


async def test_unset_facts_leave_no_hole_and_no_placeholder(h: Harness) -> None:
    privacy = _visible((await h.client.get("/legal/privacy")).text)
    assert "the operator of AfterMe" in privacy
    assert "support@afterme.invalid" in privacy  # the contact falls back to the support address
    assert "Postal address" not in privacy


@pytest.mark.settings(legal_governing_law="These terms are governed by the laws of India.")
async def test_the_governing_law_section_appears_only_when_it_is_given(h: Harness) -> None:
    given = _visible((await h.client.get("/legal/terms")).text)
    assert "13. Governing law and disputes" in given
    assert "governed by the laws of India" in given
    assert "14. Contact" in given


async def test_without_a_governing_law_the_section_is_absent_and_numbering_closes(
    h: Harness,
) -> None:
    text = _visible((await h.client.get("/legal/terms")).text)
    assert "Governing law" not in text
    assert "13. Contact" in text


# --- escaping ----------------------------------------------------------------------------------


@pytest.mark.settings(
    legal_operator_name="<script>alert('op')</script>",
    legal_postal_address='"><img src=x onerror=alert(1)>',
    legal_governing_law="<b onmouseover=alert(2)>law</b> & more",
    legal_version="<i>9</i>",
    legal_documents_final=True,
    legal_contact_email="privacy@afterme.example",
)
async def test_values_from_the_settings_are_escaped(h: Harness) -> None:
    for path in ("/legal", "/legal/privacy", "/legal/terms"):
        page = (await h.client.get(path)).text
        for raw in (
            "<script>alert",
            "<img src=x",
            "<b onmouseover",
            "<i>9</i>",
            "onerror=alert(1)>",
        ):
            assert raw not in page, (path, raw)
    privacy = (await h.client.get("/legal/privacy")).text
    assert "&lt;script&gt;alert(&#39;op&#39;)&lt;/script&gt;" in privacy
    assert "&#34;&gt;&lt;img src=x onerror=alert(1)&gt;" in privacy
    terms = (await h.client.get("/legal/terms")).text
    assert "&lt;b onmouseover=alert(2)&gt;law&lt;/b&gt; &amp; more" in terms


async def test_the_addresses_in_html_are_plain_addresses_only() -> None:
    from pydantic import ValidationError

    from tests.support import make_settings

    with pytest.raises(ValidationError):
        make_settings(support_email='x"><script>@a.example')


# --- /support ----------------------------------------------------------------------------------


@pytest.mark.settings(**FACTS)
async def test_support_shows_the_addresses_the_lost_phone_page_and_how_to_report(
    h: Harness,
) -> None:
    page = (await h.client.get("/support")).text
    text = " ".join(_visible(page).split())
    assert 'href="mailto:help@afterme.example"' in page
    assert 'href="mailto:abuse@afterme.example"' in page
    assert 'href="/a/login"' in page  # the web check-in: the lost-phone page
    assert 'href="/a/delete"' in page
    for sentence in (
        "I received a message from AfterMe that I didn't expect",
        "stop emails like it",
        "Forward the message to us",
        "I lost my phone",
        "AfterMe is not an emergency service",
    ):
        assert sentence in text, sentence


async def test_the_pages_work_without_a_database(h: Harness) -> None:
    """They hold nothing about a person: they keep answering when everything else is down."""
    await h.app.state.services.db.dispose()
    for path in PAGES:
        assert (await h.client.get(path)).status_code == 200


async def test_a_crawler_style_request_for_a_missing_page_is_still_a_404(
    h: Harness,
) -> None:
    response: httpx.Response = await h.client.get("/legal/cookies")
    assert response.status_code == 404


# --- the abuse line in the emails ---------------------------------------------------------


@pytest.mark.settings(abuse_email="abuse@afterme.example", support_email="help@afterme.example")
async def test_every_message_to_a_contact_says_where_to_report_it(world: World) -> None:
    from datetime import timedelta

    from tests.engine.test_release import STAGE_2, Portal, _setup, address

    person = await _setup(world)
    invitation = world.mail.to(address(person, "Brother"), "contact_invitation")
    await world.advance_to(STAGE_2 + timedelta(minutes=6))
    await Portal(world).reach_content(person)
    incident = world.open_incident(person)
    assert incident is not None
    await world.safe(person, str(incident["id"]))
    await world.tick()

    brother = address(person, "Brother")
    sent = [
        *invitation,
        *world.mail.to(brother, "contact_alert_with_release"),
        *world.mail.to(brother, "portal_code"),
        *world.mail.to(brother, "contact_all_clear"),
    ]
    assert {m.template for m in sent} == {
        "contact_invitation",
        "contact_alert_with_release",
        "portal_code",
        "contact_all_clear",
    }
    for message in sent:
        assert "abuse@afterme.example" in message.text, message.template
        assert "https://afterme.test/support" in message.text or message.template in (
            "contact_invitation",
        ), message.template
        assert "afterme.invalid" not in message.text, message.template
    assert "https://afterme.test/support" in invitation[0].text
