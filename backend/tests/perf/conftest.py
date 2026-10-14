"""The performance harness lives in ``scripts/perf_support`` (not a package of the app); the
plan tests use its seed and its statement recorder, so there is one definition of both."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))
