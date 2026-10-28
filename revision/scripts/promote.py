#!/usr/bin/env python3
"""Promote validated revision outputs from outputs/revision/<id>/ to revision/data/<id>/.

Copies raw JSONL, meta/environment JSON, storage probes and test logs; refuses campaigns with
non-ok cells; then rewrites revision/REVISION_MANIFEST.sha256 over revision/ (excluding itself).
"""
from __future__ import annotations

import hashlib
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "outputs" / "revision"
DST = ROOT / "revision" / "data"
KEEP = ("raw/*.jsonl", "meta.json", "environment.json", "preflight.json", "storage/revision_*.json",
        "tests_all.log", "test_profile_all.json", "ablation.json",
        "core_tests.log", "core_tests_summary.json")


def main(ids: list[str]) -> None:
    for cid in ids:
        src = SRC / cid
        if not src.is_dir():
            sys.exit(f"missing {src}")
        for f in (src / "raw").glob("*.jsonl") if (src / "raw").is_dir() else []:
            bad = [json.loads(l)["experiment_id"] for l in f.read_text().splitlines()
                   if l.strip() and json.loads(l)["status"] != "ok"]
            if bad:
                sys.exit(f"{cid}/{f.name}: non-ok cells {sorted(set(bad))}")
        dst = DST / cid
        if dst.exists():
            shutil.rmtree(dst)
        n = 0
        for pat in KEEP:
            for f in src.glob(pat):
                out = dst / f.relative_to(src)
                out.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(f, out)
                n += 1
        print("promoted", cid, n, "files")
    rev = ROOT / "revision"
    lines = []
    for f in sorted(p for p in rev.rglob("*") if p.is_file() and p.name != "REVISION_MANIFEST.sha256"
                    and "__pycache__" not in p.parts):
        lines.append(f"{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.relative_to(ROOT)}")
    (rev / "REVISION_MANIFEST.sha256").write_text("\n".join(lines) + "\n")
    print("manifest", len(lines), "files")


if __name__ == "__main__":
    main(sys.argv[1:])
