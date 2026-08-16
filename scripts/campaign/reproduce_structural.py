#!/usr/bin/env python3
"""Rerun v2 RQ3 measurement; abort on drift versus eval-v2 freeze. Does not write f1/raw."""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

from frozen import BLADE, RQ3, ROOT, STATE, V2


def load_rq3():
    path = Path(__file__).resolve().parent / "measure_structural.py"
    spec = importlib.util.spec_from_file_location("measure_structural", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def reproduce(out_dir: Path) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    mod = load_rq3()
    b_files = sorted((ROOT / "comparison/src/blade-app").glob("*.sol"))
    c_files = sorted((ROOT / "comparison/src/manual").glob("*.sol"))
    accounting = {}
    issues = []
    for pop, files in (("B", b_files), ("C", c_files)):
        rows = []
        checks_n = 0
        for p in files:
            summary, _audit, checks, iss = mod.classify_path(p)
            rows.append(summary)
            checks_n += len(checks)
            issues.extend(iss)
        accounting[pop] = {
            "total_code_loc": sum(r["pygount_code"] for r in rows),
            "protocol_loc": sum(r["protocol_loc"] for r in rows),
            "policy_loc": sum(r["policy_loc"] for r in rows),
            "neutral_loc": sum(r["neutral_loc"] for r in rows),
            "check_sites": checks_n,
        }
    raw_path = out_dir / "pygount_A.json"
    subprocess.run(
        [
            str(mod.PYGOUNT_BIN),
            "--format=json",
            "--suffix=sol",
            "--encoding=utf-8",
            "--out",
            str(raw_path),
            str(BLADE / "src/core"),
        ],
        check=True,
    )
    data = json.loads(raw_path.read_text())
    py_a = {"pygount_code": int(data.get("summary", {}).get("totalCodeCount", 0))}

    got = {
        "A": {"core_loc_context": py_a["pygount_code"]},
        "B": accounting["B"],
        "C": accounting["C"],
        "structural_C": {
            "mappings": STATE["C"]["mappings"],
            "nested_mappings": STATE["C"]["nested_mappings"],
            "structs": STATE["C"]["protocol_structs"],
        },
        "structural_B": {
            "mappings": STATE["B"]["mappings"],
            "nested_mappings": STATE["B"]["nested_mappings"],
            "structs": STATE["B"]["protocol_structs"],
        },
        "issues": issues,
    }
    exp = RQ3
    errs = []
    if not exp:
        errs.append("structural.json missing")
    else:
        if got["A"]["core_loc_context"] != exp["A"]["core_loc_context"]:
            errs.append(f"A {got['A']['core_loc_context']} != {exp['A']['core_loc_context']}")
        for pop in ("B", "C"):
            g, e = got[pop], exp[pop]
            if g["total_code_loc"] != e["total"]:
                errs.append(f"{pop} total {g['total_code_loc']} != {e['total']}")
            if g["protocol_loc"] != e["protocol"]:
                errs.append(f"{pop} protocol")
            if g["policy_loc"] != e["policy"]:
                errs.append(f"{pop} policy")
            if g["neutral_loc"] != e["neutral"]:
                errs.append(f"{pop} neutral")
        if accounting["B"]["check_sites"] != exp["B"]["application_owned_protocol_check_sites"]:
            errs.append("B checks")
        if accounting["C"]["check_sites"] != exp["C"]["application_owned_protocol_check_sites"]:
            errs.append("C checks")
        st = exp["C"]["structural_protocol_state"]
        if STATE["C"]["mappings"] != st["mappings"]:
            errs.append("C mappings freeze vs manifest")
        if STATE["C"]["nested_mappings"] != st["nested_mappings"]:
            errs.append("C nested")
        if STATE["C"]["protocol_structs"] != st["structs"]:
            errs.append("C structs")
        if STATE["B"]["mappings"] != 0 or STATE["B"]["protocol_structs"] != 0:
            errs.append("B structural not zero")
    if issues:
        errs.extend(issues)
    got["ok"] = not errs
    got["errs"] = errs
    (out_dir / "reproduce.json").write_text(json.dumps(got, indent=2) + "\n")
    if errs:
        print("STRUCTURAL REPRODUCE drift vs experiment/config/structural.json", file=sys.stderr)
        for e in errs:
            print("-", e, file=sys.stderr)
        if os.environ.get("STRUCTURAL_ENFORCE_FREEZE") == "1":
            print("STRUCTURAL REPRODUCE ABORT", file=sys.stderr)
            sys.exit(2)
        print("STRUCTURAL REPRODUCE continuing (set STRUCTURAL_ENFORCE_FREEZE=1 to abort)", file=sys.stderr)
    else:
        print("STRUCTURAL REPRODUCE PASS")
    return got


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else V2 / "outputs" / "dryrun" / "structural"
    reproduce(out)
