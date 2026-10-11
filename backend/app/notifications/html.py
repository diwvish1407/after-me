"""The HTML twin of a plain-text email.

Every message is written once, as text (USER_FLOWS §13). The HTML part is *derived* from it, so
the two can never say different things: paragraphs, line breaks, ``- `` bullets and ``https://``
links (shown as the address itself, so a reader always sees where a link goes). Nothing from the
text is trusted: it is escaped, and only ``https`` and ``http`` addresses become links.
"""

from __future__ import annotations

import re
from html import escape
from typing import Final

_URL: Final = re.compile(r"https?://[^\s<>\"']+")
_TRAILING: Final = ".,;:!?)"

_STYLE: Final = (
    "font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;"
    "font-size:16px;line-height:1.5;color:#1d2330;"
)


def _link(match: re.Match[str]) -> str:
    url = match.group(0)
    tail = ""
    while url and url[-1] in _TRAILING:
        tail = url[-1] + tail
        url = url[:-1]
    safe = escape(url, quote=True)
    return f'<a href="{safe}" style="color:#1f5fbf;">{safe}</a>{escape(tail)}'


def _inline(line: str) -> str:
    out: list[str] = []
    last = 0
    for found in _URL.finditer(line):
        out.append(escape(line[last : found.start()]))
        out.append(_link(found))
        last = found.end()
    out.append(escape(line[last:]))
    return "".join(out)


def text_to_html(text: str) -> str:
    blocks = [b for b in re.split(r"\n\s*\n", text.strip()) if b.strip()]
    parts: list[str] = []
    for block in blocks:
        lines = block.split("\n")
        if all(line.lstrip().startswith("- ") for line in lines):
            items = "".join(f"<li>{_inline(line.lstrip()[2:])}</li>" for line in lines)
            parts.append(f'<ul style="margin:0 0 16px 20px;padding:0;">{items}</ul>')
            continue
        body = "<br>".join(_inline(line) for line in lines)
        parts.append(f'<p style="margin:0 0 16px 0;">{body}</p>')
    return (
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1"></head>'
        f'<body style="margin:0;padding:24px;{_STYLE}">'
        f'<div style="max-width:560px;margin:0 auto;">{"".join(parts)}</div></body></html>'
    )
