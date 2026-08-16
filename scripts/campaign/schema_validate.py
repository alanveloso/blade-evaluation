#!/usr/bin/env python3
"""Validate schema v2 records. Fail loudly."""
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED = (
    "experiment_spec_id",
    "schema_version",
    "analysis_version",
    "phase",
    "core_sha",
    "freeze_manifest_sha256",
    "baseline_version",
    "implementation",
    "condition_id",
    "protocol",
    "path",
    "payload_bytes",
    "payload_pattern",
    "payload_sha256",
    "participant_count",
    "active_conversations",
    "solc_version",
    "forge_version",
    "forge_commit",
    "optimizer",
    "optimizer_runs",
    "via_ir",
    "evm_version",
    "transaction_gas_used",
    "top_level_calldata_bytes",
    "record_kind",
    "status",
)


def validate_rows(rows: list[dict], *, expect_phase: str | None = None) -> list[str]:
    errs = []
    for i, r in enumerate(rows):
        for k in REQUIRED:
            if r.get(k) in (None, ""):
                errs.append(f"row {i} missing {k}")
        if r.get("schema_version") != 2:
            errs.append(f"row {i} schema_version")
        if r.get("analysis_version") != 1:
            errs.append(f"row {i} analysis_version")
        if r.get("payload_pattern") != "repeat_0xab":
            errs.append(f"row {i} payload_pattern")
        if r.get("implementation") not in ("blade", "manual"):
            errs.append(f"row {i} implementation")
        if r.get("scenario") == "C":
            errs.append(f"row {i} independent scenario C")
        if expect_phase and r.get("phase") != expect_phase:
            errs.append(f"row {i} phase {r.get('phase')} != {expect_phase}")
        if r.get("record_kind") not in ("deployment", "interaction_tx"):
            errs.append(f"row {i} record_kind")
    return errs


def main():
    path = Path(sys.argv[1])
    phase = sys.argv[2] if len(sys.argv) > 2 else None
    rows = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    errs = validate_rows(rows, expect_phase=phase)
    if errs:
        print("SCHEMA FAIL")
        for e in errs[:40]:
            print("-", e)
        sys.exit(1)
    print("SCHEMA PASS", "rows", len(rows))


if __name__ == "__main__":
    main()
