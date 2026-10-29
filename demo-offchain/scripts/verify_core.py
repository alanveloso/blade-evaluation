#!/usr/bin/env python3
"""Confirm the sibling BLADE Core is the E2 commit and that its sources are unmodified."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

CORE_COMMIT = "4b60b86159e89baccd24a859ca62e7039a8c8be2"
CORE_PATH = Path(__file__).resolve().parents[3] / "blade"


def git(args: list[str]) -> str:
    return subprocess.check_output(["git", *args], cwd=CORE_PATH, text=True).strip()


def main() -> int:
    if not (CORE_PATH / ".git").exists():
        print(f"FAIL: BLADE Core not found at {CORE_PATH}", file=sys.stderr)
        return 1
    head = git(["rev-parse", "HEAD"])
    dirty = git(["status", "--porcelain", "--", "src", "examples", "test", "foundry.toml"])
    report = {
        "core_path": str(CORE_PATH),
        "expected_commit": CORE_COMMIT,
        "head": head,
        "src_clean": dirty == "",
        "dirty_paths": dirty.splitlines(),
    }
    print(json.dumps(report, indent=2))
    if head != CORE_COMMIT:
        print("FAIL: Core HEAD is not the E2 commit.", file=sys.stderr)
        return 1
    if dirty:
        print("FAIL: Core sources have local modifications.", file=sys.stderr)
        return 1
    print("OK: official BLADE Core is unchanged at E2.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
