"""Support code for ``backend/scripts/perf.py``, the repeatable performance harness (TEST_PLAN §9).

``db``        the throwaway database ``afterme_perf`` (reuses the game-day database code)
``seed``      bulk SQL seeding at the TEST_PLAN scale
``stack``     the real API (uvicorn) and worker processes, and the JWTs for sampled users
``load``      the open-loop HTTP load generator
``phases``    PERF-01 .. PERF-04, the tick and the Hold evaluation
``plans``     EXPLAIN (ANALYZE, BUFFERS) of every statement on the hot paths
``report``    the machine, the JSON report and the human table
"""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parents[1]
BACKEND_DIR = SCRIPTS_DIR.parent
for _path in (SCRIPTS_DIR, BACKEND_DIR):  # `gameday_support` lives next to this package
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))
