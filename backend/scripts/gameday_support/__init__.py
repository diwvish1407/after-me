"""Support code for ``backend/scripts/gameday.py``, the local game-day rehearsal (OPS-01..03).

``report``   the narrative and the PASS/FAIL table (exit code 0 only if every check passes)
``checks``   pure functions the scenarios assert with (unit-tested without a database)
``procs``    ports, the real API and worker processes, the throwaway database
``world``    what a person and an operator do: HTTP calls, SQL observation, the test clock
``ops01`` ``ops02`` ``ops03``   the three scenarios
"""

from __future__ import annotations

import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[2]
if str(BACKEND_DIR) not in sys.path:  # `app` and `cli` are imported from backend/
    sys.path.insert(0, str(BACKEND_DIR))
