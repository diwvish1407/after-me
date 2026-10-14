"""Expand/contract (docs/DEPLOYMENT.md §5): a migration must keep the PREVIOUS release working.

The readiness check lets the previous image serve a schema that is ahead of it (a rollback, or
an old revision scaling out while a deploy rolls), which is only safe if migrations are
additive. A column or table that the previous release reads must not disappear, or change its
name, in the same release that stops using it: the drop (or rename) is a separate "contract"
step, one release later, and its file says so with a ``# contract-step: <why it is safe>``
comment, which a reviewer reads.

This scans what ``upgrade()`` can run: the whole migration file except ``downgrade()``, its
docstrings and its comments.
"""

from __future__ import annotations

import ast
import io
import re
import tokenize
from pathlib import Path

import pytest

from app.core.config import BACKEND_DIR

pytestmark = pytest.mark.no_db

VERSIONS = BACKEND_DIR / "migrations" / "versions"

# Contract steps that predate the rule, by revision id. The scan found none when the rule was
# introduced (0001-0012 are additive); a revision may be added here only with a reason.
HISTORICAL_CONTRACT_STEPS: frozenset[str] = frozenset()

_CONTRACT = re.compile(
    r"(?i)\bdrop\s+column\b|\bdrop\s+table\b|\brename\b"
    r"|\bop\.drop_column\b|\bop\.drop_table\b|\bop\.rename_table\b|\bnew_column_name\s*="
)
_JUSTIFIED = re.compile(r"#\s*contract-step:\s*\S")


def _revision(tree: ast.Module) -> str:
    for node in tree.body:
        target = None
        if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            target, value = node.target.id, node.value
        elif isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
            target, value = node.targets[0].id, node.value
        if target == "revision" and isinstance(value, ast.Constant):
            return str(value.value)
    raise AssertionError("migration without a revision id")


def contract_statements(source: str) -> list[str]:
    """The lines outside ``downgrade()`` (code only: no comment, no docstring) that drop or
    rename a column or a table."""
    tree = ast.parse(source)
    skipped: set[int] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == "downgrade":
            skipped.update(range(node.lineno, (node.end_lineno or node.lineno) + 1))
        body = getattr(node, "body", None)
        if (
            isinstance(node, ast.Module | ast.FunctionDef | ast.AsyncFunctionDef | ast.ClassDef)
            and body
            and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)
        ):
            doc = body[0]
            skipped.update(range(doc.lineno, (doc.end_lineno or doc.lineno) + 1))
    # The code of each line, tokens joined (``op . drop_column`` reads as ``op.drop_column``).
    code: dict[int, list[str]] = {}
    for token in tokenize.generate_tokens(io.StringIO(source).readline):
        if token.type in (tokenize.COMMENT, tokenize.NL, tokenize.NEWLINE):
            continue
        if token.start[0] in skipped:
            continue
        code.setdefault(token.start[0], []).append(token.string)
    found: list[str] = []
    for line, parts in sorted(code.items()):
        text = "".join(parts)
        if _CONTRACT.search(text):
            found.append(f"line {line}: {text.strip()[:80]}")
    return found


def is_justified(source: str) -> bool:
    return _JUSTIFIED.search(source) is not None


def test_every_migration_is_additive_unless_it_says_why() -> None:
    offenders = []
    for path in sorted(VERSIONS.glob("*.py")):
        source = path.read_text()
        revision = _revision(ast.parse(source))
        found = contract_statements(source)
        if found and not is_justified(source) and revision not in HISTORICAL_CONTRACT_STEPS:
            offenders.append(f"{path.name} ({revision}): {found}")
    assert offenders == [], (
        "a migration drops or renames a column or table without a '# contract-step:' "
        "justification (docs/DEPLOYMENT.md §5, expand/contract)"
    )


def test_the_scan_sees_drops_and_renames_in_upgrade_and_not_in_downgrade() -> None:
    expand = '''"""Docstring may say DROP TABLE without counting."""
revision: str = "9001"


def upgrade() -> None:
    # a comment may say DROP COLUMN too
    op.add_column("t", sa.Column("c", sa.Text()))


def downgrade() -> None:
    op.execute("ALTER TABLE t DROP COLUMN c")
    op.drop_table("u")
'''
    assert contract_statements(expand) == []

    for statement in (
        'op.execute("ALTER TABLE t DROP COLUMN c")',
        'op.execute("DROP TABLE t")',
        'op.execute("ALTER TABLE t RENAME TO u")',
        'op.drop_column("t", "c")',
        'op.drop_table("t")',
        'op.rename_table("t", "u")',
        'op.alter_column("t", "c", new_column_name="d")',
    ):
        contract = f'revision: str = "9002"\n\n\ndef upgrade() -> None:\n    {statement}\n'
        assert contract_statements(contract), statement
        assert not is_justified(contract)
        assert is_justified("# contract-step: release N-1 stopped reading t.c\n" + contract)


def test_the_migrations_directory_is_the_one_alembic_uses() -> None:
    assert len(list(Path(VERSIONS).glob("*.py"))) >= 12
