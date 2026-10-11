"""Helpers shared by the Phase 9 security tests (``test_sec_*.py``).

Two things recur in them: "the refused request changed nothing" (a snapshot of every table) and
"the page the server rendered is inert" (what a browser would parse out of it).
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from html.parser import HTMLParser
from typing import Any

import httpx
import psycopg

from app.models import ALL_TABLES

Db = psycopg.Connection[dict[str, Any]]
Snapshot = dict[str, list[str]]

# Counted on every request by design; not state anyone reads back.
_IGNORED_TABLES = frozenset({"rate_limit_counters"})
_NONCE_RE = re.compile(r"script-src 'nonce-([^']+)'")
CSRF_FIELD_RE = re.compile(r'name="csrf" value="([^"]+)"')


def snapshot(owner_db: Db, tables: Iterable[str] | None = None) -> Snapshot:
    """Every row of every table (or of ``tables``) as sorted JSON text.

    ``rate_limit_counters`` is left out (it moves on every request) and so is the
    ``last_used_at`` column of ``sessions`` (bookkeeping written on use, at most every five
    minutes); nothing else is excused.
    """
    wanted = [t for t in (tables if tables is not None else ALL_TABLES) if t not in _IGNORED_TABLES]
    result: Snapshot = {}
    for table in wanted:
        found = owner_db.execute(
            f"SELECT (to_jsonb(t) - 'last_used_at')::text AS row FROM {table} t"  # noqa: S608
        ).fetchall()
        result[table] = sorted(row["row"] for row in found)
    return result


def changed_tables(before: Snapshot, after: Snapshot) -> list[str]:
    """Names of the tables whose rows differ between two snapshots (with the row counts)."""
    return sorted(
        f"{table} ({len(before[table])} -> {len(after[table])} rows)"
        for table in before
        if before[table] != after[table]
    )


def assert_unchanged(before: Snapshot, after: Snapshot, what: str = "") -> None:
    changed = changed_tables(before, after)
    assert not changed, f"{what} changed state: {changed}"


# --- what a browser makes of a page -------------------------------------------------------------


class _Parsed(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.elements: list[tuple[str, dict[str, str | None]]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.elements.append((tag, dict(attrs)))

    handle_startendtag = handle_starttag  # type: ignore[assignment]


# Elements that only an injected payload would add to any page or email of this application.
INJECTED_TAGS = frozenset(
    {"img", "svg", "iframe", "object", "embed", "b", "i", "u", "style", "video", "audio", "math"}
)


def elements(markup: str) -> list[tuple[str, dict[str, str | None]]]:
    parser = _Parsed()
    parser.feed(markup)
    parser.close()
    return parser.elements


def assert_inert(
    markup: str,
    *,
    csp: str | None = None,
    allowed_tags: Iterable[str] | None = None,
    where: str = "page",
) -> None:
    """Fail if ``markup`` carries an element or attribute an attacker's text could have added.

    * no event-handler attribute (``on*``) anywhere, no ``javascript:`` URL;
    * none of the elements a payload uses (``img``, ``svg``, ``b`` ...);
    * every ``<script>`` carries the nonce the response's CSP allows (a page's own script, never
      one from a payload, which cannot know the nonce);
    * with ``allowed_tags``: nothing outside that list (the email twin has a known tag set).
    """
    nonce = None
    if csp is not None:
        found = _NONCE_RE.search(csp)
        nonce = found[1] if found else None
    allowed = set(allowed_tags) if allowed_tags is not None else None
    for tag, attrs in elements(markup):
        assert tag not in INJECTED_TAGS, f"{where}: <{tag}> element: {attrs}"
        if allowed is not None:
            assert tag in allowed, f"{where}: unexpected <{tag}> element"
        for name, value in attrs.items():
            assert not name.startswith("on"), f"{where}: <{tag} {name}=...>"
            if value is not None:
                assert not value.strip().lower().startswith("javascript:"), (where, tag, name)
        if tag == "script":
            assert csp is not None, f"{where}: a <script> in a response with no CSP to check"
            assert nonce, f"{where}: the CSP has no script nonce"
            assert attrs.get("nonce") == nonce, f"{where}: <script> without the nonce"


def csrf_of(page: httpx.Response) -> str:
    found = CSRF_FIELD_RE.search(page.text)
    assert found is not None, page.text[:200]
    return found[1]
