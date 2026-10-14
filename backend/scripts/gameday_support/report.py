"""The narrative and the PASS/FAIL table of a game-day run.

A check that fails is ``FAIL (defect)`` when it asserts something a design document promises
(it names the promise): the product does not do what its documents say. Any other failure is
plain ``FAIL``: the harness or the environment did not get to the state where the promise
applies, or a harness precondition did not hold.
"""

from __future__ import annotations

import textwrap
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Final

OK: Final = "PASS"
FAIL: Final = "FAIL"
DEFECT: Final = "FAIL (defect)"

_WIDTHS: Final = (12, 44, 30, 30, 14)
_HEADER: Final = ("ID", "Check", "Expected", "Actual", "Result")


@dataclass(frozen=True)
class Row:
    ident: str
    what: str
    expected: str
    actual: str
    status: str
    promise: str = ""


@dataclass
class Report:
    rows: list[Row] = field(default_factory=list)
    out: Callable[[str], None] = print

    def check(
        self,
        ident: str,
        what: str,
        ok: bool,
        *,
        expected: str,
        actual: str,
        promise: str = "",
    ) -> bool:
        """Record one check. ``promise`` names the document line the check enforces; a failure of
        such a check is a product defect."""
        status = OK if ok else (DEFECT if promise else FAIL)
        self.rows.append(Row(ident, what, expected, actual, status, promise))
        mark = "ok  " if ok else "FAIL"
        detail = "" if ok else f"  (expected {expected}; got {actual})"
        self.out(f"    [{mark}] {ident}  {what}{detail}")
        return ok

    def fail(self, ident: str, what: str, actual: str) -> None:
        """A harness or environment failure: not a verdict on the product."""
        self.rows.append(Row(ident, what, "completes", actual, FAIL))
        self.out(f"    [FAIL] {ident}  {what}  ({actual})")

    @property
    def passed(self) -> bool:
        return bool(self.rows) and all(r.status == OK for r in self.rows)

    def exit_code(self) -> int:
        return 0 if self.passed else 1

    def defects(self) -> list[Row]:
        return [r for r in self.rows if r.status == DEFECT]

    def counts(self) -> tuple[int, int, int]:
        return (
            sum(r.status == OK for r in self.rows),
            sum(r.status == FAIL for r in self.rows),
            sum(r.status == DEFECT for r in self.rows),
        )

    # ------------------------------------------------------------------ rendering

    def table(self) -> str:
        def line(cells: tuple[str, ...]) -> list[str]:
            wrapped = [
                textwrap.wrap(cell, width, break_long_words=True) or [""]
                for cell, width in zip(cells, _WIDTHS, strict=True)
            ]
            height = max(len(w) for w in wrapped)
            return [
                "  ".join(
                    (w[i] if i < len(w) else "").ljust(width)
                    for w, width in zip(wrapped, _WIDTHS, strict=True)
                ).rstrip()
                for i in range(height)
            ]

        rule = "-" * (sum(_WIDTHS) + 2 * (len(_WIDTHS) - 1))
        out = [*line(_HEADER), rule]
        for row in self.rows:
            out.extend(line((row.ident, row.what, row.expected, row.actual, row.status)))
        out.append(rule)
        passed, failed, defects = self.counts()
        out.append(f"{passed} PASS, {failed} FAIL, {defects} FAIL (defect)")
        return "\n".join(out)

    def defect_list(self) -> str:
        lines: list[str] = []
        for row in self.defects():
            lines.append(f"  {row.ident}  {row.what}")
            lines.append(f"      promise : {row.promise}")
            lines.append(f"      expected: {row.expected}")
            lines.append(f"      actual  : {row.actual}")
        return "\n".join(lines)
