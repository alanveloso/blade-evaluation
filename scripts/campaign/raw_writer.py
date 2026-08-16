#!/usr/bin/env python3
"""Append-safe schema-v2 writer. Never patches values."""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

from integrity import check_rows


def refuse_if_campaign_raw(raw_dir: Path) -> None:
    raw_dir.mkdir(parents=True, exist_ok=True)
    found = [p.name for p in raw_dir.iterdir() if p.suffix == ".jsonl" and p.stat().st_size > 0]
    if found:
        raise SystemExit(
            "F3 raw already contains campaign records: "
            + ", ".join(found)
            + ". Explicit clean/restart required BEFORE campaign start."
        )


def append_validated(path: Path, rows: list[dict], *, phase: str, matrix: str | None) -> None:
    errs = check_rows(rows, phase=phase, matrix=None)
    # per-cell: do not require full-matrix completeness
    if errs:
        raise SystemExit("record validation failed:\n- " + "\n- ".join(errs[:30]))
    blob = "".join(json.dumps(r, separators=(",", ":")) + "\n" for r in rows)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".append.", dir=str(path.parent), text=True)
    try:
        existing = path.read_text() if path.exists() else ""
        with os.fdopen(fd, "w") as fh:
            fh.write(existing)
            fh.write(blob)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
