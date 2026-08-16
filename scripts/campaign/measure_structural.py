#!/usr/bin/env python3
"""F1.5 RQ3 measurement: one pygount-code universe for totals and protocol/policy/neutral."""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from frozen import BLADE, ROOT

PYGOUNT_BIN = shutil.which("pygount")
if not PYGOUNT_BIN:
    raise SystemExit("pygount not on PATH (pip install pygount)")
OUT = ROOT / "outputs" / "structural"
OUT.mkdir(parents=True, exist_ok=True)

MARKER = re.compile(r"^\s*//\s*RQ3:(PROTOCOL|POLICY|END)\s*$")
CHECK = re.compile(r"\b(if|require|assert)\s*\(|\brevert\s")
SPDX_OR_PRAGMA = re.compile(r"^\s*(// SPDX-License-Identifier:|pragma solidity)")

from pygount.analysis import _line_parts, guess_lexer  # noqa: E402


def pygount_cli(target: Path, label: str) -> dict:
    raw_path = OUT / f"pygount_{label}.json"
    subprocess.run(
        [
            str(PYGOUNT_BIN),
            "--format=json",
            "--suffix=sol",
            "--encoding=utf-8",
            "--out",
            str(raw_path),
            str(target),
        ],
        check=True,
    )
    data = json.loads(raw_path.read_text())
    return {
        "label": label,
        "raw": str(raw_path.relative_to(ROOT)),
        "pygount_code": int(data.get("summary", {}).get("totalCodeCount", 0)),
        "files": [{"path": f.get("path"), "codeCount": f.get("codeCount")} for f in data.get("files", [])],
    }


def pygount_kinds(path: Path, text: str) -> list[str]:
    lexer = guess_lexer(str(path), text)
    kinds: list[str] = []
    for parts in _line_parts(lexer, text):
        mark = "e"
        for candidate in ("d", "s", "c"):
            if candidate in parts:
                mark = candidate
        kinds.append(mark)
    return kinds


def parse_markers(path: Path, nlines: int) -> tuple[dict[int, str], list[str]]:
    """Return per-line region (protocol/policy/none) and audit issues."""
    lines = path.read_text().splitlines()
    issues: list[str] = []
    events: list[tuple[int, str]] = []
    cur = None
    for i, line in enumerate(lines, 1):
        m = MARKER.match(line)
        if not m:
            continue
        kind = m.group(1)
        events.append((i, kind))
        if kind in ("PROTOCOL", "POLICY"):
            cur = kind
        elif kind == "END":
            if cur is None:
                issues.append(f"{path}:{i}: unmatched END")
            elif cur == "POLICY":
                cur = "PROTOCOL"
            else:
                cur = None
    if cur is not None:
        issues.append(f"{path}: unmatched open {cur} at EOF")

    mapping: dict[int, str] = {}
    cur = None
    start = 0
    ranges: list[tuple[str, int, int]] = []

    def flush(end: int) -> None:
        nonlocal cur, start
        if cur and end >= start:
            ranges.append((cur.lower(), start, end))
        cur = None

    for i, line in enumerate(lines, 1):
        m = MARKER.match(line)
        if not m:
            continue
        kind = m.group(1)
        if kind in ("PROTOCOL", "POLICY"):
            if cur:
                ranges.append((cur.lower(), start, i - 1))
            cur = kind
            start = i + 1
        elif kind == "END":
            if cur:
                ranges.append((cur.lower(), start, i - 1))
            if cur == "POLICY":
                cur = "PROTOCOL"
                start = i + 1
            else:
                cur = None
    if cur:
        ranges.append((cur.lower(), start, nlines))

    for kind, a, b in ranges:
        for n in range(a, b + 1):
            if n in mapping:
                issues.append(f"{path}:{n}: overlapping marker range")
            mapping[n] = kind
    return mapping, issues


def classify_path(path: Path) -> tuple[dict, list[dict], list[dict], list[str]]:
    text = path.read_text()
    lines = text.splitlines()
    kinds = pygount_kinds(path, text)
    if len(kinds) != len(lines):
        raise SystemExit(f"pygount line alignment failed {path}: {len(kinds)} vs {len(lines)}")
    region, issues = parse_markers(path, len(lines))
    rel = str(path.relative_to(ROOT))
    audit_rows: list[dict] = []
    checks: list[dict] = []
    counts = {"protocol": 0, "policy": 0, "neutral": 0, "non_code": 0}
    for i, line in enumerate(lines, 1):
        kind = kinds[i - 1]
        is_code = kind == "c"
        marker_cls = region.get(i)
        if SPDX_OR_PRAGMA.match(line) and is_code:
            cls = "neutral"
            counts["neutral"] += 1
        elif not is_code:
            cls = f"non_code_{kind}"
            counts["non_code"] += 1
        elif marker_cls == "protocol":
            cls = "protocol"
            counts["protocol"] += 1
            if CHECK.search(line):
                checks.append({"file": rel, "line": i, "text": line.strip()[:160]})
        elif marker_cls == "policy":
            cls = "policy"
            counts["policy"] += 1
        else:
            cls = "neutral"
            counts["neutral"] += 1
        if is_code:
            audit_rows.append(
                {
                    "file": rel,
                    "line": i,
                    "classification": cls,
                    "source": line,
                    "source_sha256": hashlib.sha256(line.encode()).hexdigest()[:16],
                    "pygount_mark": kind,
                }
            )
        else:
            audit_rows.append(
                {
                    "file": rel,
                    "line": i,
                    "classification": cls,
                    "source": line,
                    "source_sha256": hashlib.sha256(line.encode()).hexdigest()[:16],
                    "pygount_mark": kind,
                }
            )
    file_summary = {
        "file": rel,
        "pygount_code": counts["protocol"] + counts["policy"] + counts["neutral"],
        "protocol_loc": counts["protocol"],
        "policy_loc": counts["policy"],
        "neutral_loc": counts["neutral"],
        "non_code_lines": counts["non_code"],
        "check_sites": len(checks),
    }
    if file_summary["pygount_code"] != file_summary["protocol_loc"] + file_summary["policy_loc"] + file_summary["neutral_loc"]:
        issues.append(f"{rel}: identity failed")
    return file_summary, audit_rows, checks, issues


def main() -> None:
    b_files = sorted((ROOT / "comparison/src/blade-app").glob("*.sol"))
    c_files = sorted((ROOT / "comparison/src/manual").glob("*.sol"))
    all_audit: list[dict] = []
    all_checks: list[dict] = []
    issues: list[str] = []
    pop_files = {"B": b_files, "C": c_files}
    accounting = {}
    for pop, files in pop_files.items():
        rows = []
        for p in files:
            summary, audit, checks, iss = classify_path(p)
            rows.append(summary)
            all_audit.extend(audit)
            all_checks.extend([{**c, "implementation": "blade-app" if pop == "B" else "manual"} for c in checks])
            issues.extend(iss)
        accounting[pop] = {
            "total_code_loc": sum(r["pygount_code"] for r in rows),
            "protocol_loc": sum(r["protocol_loc"] for r in rows),
            "policy_loc": sum(r["policy_loc"] for r in rows),
            "neutral_loc": sum(r["neutral_loc"] for r in rows),
            "files": rows,
        }
        a = accounting[pop]
        if a["total_code_loc"] != a["protocol_loc"] + a["policy_loc"] + a["neutral_loc"]:
            issues.append(f"population {pop} identity failed")

    py_a = pygount_cli(BLADE / "src/core", "A")
    py_b = pygount_cli(ROOT / "comparison/src/blade-app", "B")
    py_c = pygount_cli(ROOT / "comparison/src/manual", "C")
    if py_b["pygount_code"] != accounting["B"]["total_code_loc"]:
        issues.append(f"B pygount CLI {py_b['pygount_code']} != classified {accounting['B']['total_code_loc']}")
    if py_c["pygount_code"] != accounting["C"]["total_code_loc"]:
        issues.append(f"C pygount CLI {py_c['pygount_code']} != classified {accounting['C']['total_code_loc']}")

    (OUT / "line_audit.jsonl").write_text("".join(json.dumps(r) + "\n" for r in all_audit))
    (OUT / "marker_audit.json").write_text(json.dumps({"issues": issues, "ok": not issues}, indent=2))
    (OUT / "pygount_summary.json").write_text(json.dumps({"A": py_a, "B": py_b, "C": py_c}, indent=2))
    (OUT / "totals.json").write_text(
        json.dumps(
            {
                "B": accounting["B"],
                "C": accounting["C"],
                "identity_B": accounting["B"]["total_code_loc"]
                == accounting["B"]["protocol_loc"] + accounting["B"]["policy_loc"] + accounting["B"]["neutral_loc"],
                "identity_C": accounting["C"]["total_code_loc"]
                == accounting["C"]["protocol_loc"] + accounting["C"]["policy_loc"] + accounting["C"]["neutral_loc"],
                "B_check_sites": sum(1 for c in all_checks if c["implementation"] == "blade-app"),
                "C_check_sites": sum(1 for c in all_checks if c["implementation"] == "manual"),
                "issues": issues,
            },
            indent=2,
        )
    )
    sites = []
    for c in all_checks:
        t = c["text"]
        cat = "lifecycle"
        if "msg.sender" in t or "peer" in t.lower():
            cat = "peer"
        elif "bytes32(0)" in t or "Zero" in t:
            cat = "correlation"
        elif "replyBy" in t or "timestamp" in t:
            cat = "deadline"
        elif "phase" in t or "REQ_" in t or "CN_SLOT" in t or "CN_PART" in t or "evaluated" in t:
            cat = "phase"
        sites.append(
            {
                "file": c["file"],
                "line": c["line"],
                "implementation": c["implementation"],
                "protocol": "Request" if "Request" in c["file"] else "ContractNet",
                "check_category": cat,
                "rationale": t,
            }
        )
    (OUT / "protocol_check_sites.json").write_text(
        json.dumps({"count_rule": "per check site on pygount-code protocol lines", "sites": sites}, indent=2)
    )
    print(json.dumps({k: {kk: accounting[k][kk] for kk in ("total_code_loc", "protocol_loc", "policy_loc", "neutral_loc")} for k in ("B", "C")}, indent=2))
    print("issues", issues)
    if issues:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
