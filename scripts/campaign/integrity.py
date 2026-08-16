#!/usr/bin/env python3
"""Schema v2 + integrity gates. Fail before accepting raw."""
from __future__ import annotations

import json
import sys
from pathlib import Path

from completeness import completeness_errors, gas_sum_errors, pairing_errors
from frozen import HISTORICAL_CORE, NEW_CORE, SPEC
from schema_validate import validate_rows


def check_rows(rows: list[dict], *, phase: str, matrix: str | None) -> list[str]:
    errs = validate_rows(rows, expect_phase=phase)
    errs.extend(gas_sum_errors(rows))
    errs.extend(pairing_errors(rows))
    if matrix:
        errs.extend(completeness_errors(rows, matrix=matrix))
    for r in rows:
        if r.get("phase") in ("preflight", "dryrun") and phase == "f3":
            errs.append("preflight/pilot mixed into final")
        if r.get("phase") == "f2-pilot":
            errs.append("pilot mixed into records")
        if r.get("experiment_spec_id") != "blade-core-eval-v2":
            errs.append("not eval-v2 spec id")
        if HISTORICAL_CORE and r.get("core_sha") == HISTORICAL_CORE:
            errs.append("historical Core SHA in records")
        if r.get("core_sha") != NEW_CORE:
            errs.append("core_sha mismatch")
        if r.get("core_sha") != SPEC["core_sha"]:
            errs.append("core_sha != spec")
    return errs


def main():
    path = Path(sys.argv[1])
    phase = sys.argv[2]
    matrix = sys.argv[3] if len(sys.argv) > 3 else None
    rows = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    errs = check_rows(rows, phase=phase, matrix=matrix)
    if errs:
        print("INTEGRITY FAIL")
        for e in errs[:50]:
            print("-", e)
        sys.exit(1)
    print("INTEGRITY PASS", "rows", len(rows))


if __name__ == "__main__":
    main()
