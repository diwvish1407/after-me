"""Dependency audit gate (TEST_PLAN §10).

Runs pip-audit on the project environment and lists every known advisory. The exit status is
non-zero only for advisories that have a fixed version available: an advisory with no fix yet is
reported but does not block the build (there is nothing to upgrade to).

    uv run python scripts/audit_deps.py
"""

from __future__ import annotations

import json
import subprocess
import sys


def main() -> int:
    proc = subprocess.run(  # fixed argument list, no user input
        [sys.executable, "-m", "pip_audit", "--format", "json", "--progress-spinner", "off"],
        capture_output=True,
        text=True,
        check=False,
    )
    try:
        report = json.loads(proc.stdout)
    except json.JSONDecodeError:
        print(proc.stderr or proc.stdout, file=sys.stderr)
        return proc.returncode or 2

    dependencies = report.get("dependencies", [])
    fixable: list[str] = []
    unfixed: list[str] = []
    for dep in dependencies:
        for vuln in dep.get("vulns", []):
            line = f"{dep['name']} {dep['version']}: {vuln['id']}"
            if vuln.get("fix_versions"):
                fixable.append(f"{line} (fixed in {', '.join(vuln['fix_versions'])})")
            else:
                unfixed.append(f"{line} (no fix available yet)")
    skipped = [f"{d['name']}: {d['skip_reason']}" for d in dependencies if d.get("skip_reason")]

    print(f"pip-audit: {len(dependencies)} packages audited")
    for title, rows in (
        ("Advisories with a fix (blocking)", fixable),
        ("Advisories without a fix (reported only)", unfixed),
        ("Skipped", skipped),
    ):
        if rows:
            print(f"{title}:")
            for row in rows:
                print(f"  - {row}")
    if not fixable and not unfixed:
        print("No known vulnerabilities found")
    return 1 if fixable else 0


if __name__ == "__main__":
    sys.exit(main())
