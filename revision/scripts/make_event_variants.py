#!/usr/bin/env python3
"""Generate the event-cost counterfactual Core trees under revision/variants/events/.

Each tree is the E2 Core `src/core` with selected `emit` statements removed. Event declarations stay,
so the ABI is unchanged. These trees are experimental counterfactuals, not BLADE releases.

    python3 revision/scripts/make_event_variants.py            # (re)generate
    python3 revision/scripts/make_event_variants.py --check    # verify committed trees
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CFG = json.loads((ROOT / "revision" / "config" / "campaigns.json").read_text())
BASE_SHA = CFG["campaigns"]["E2"]["core_sha"]
DEST = ROOT / "revision" / "variants" / "events"
PHASE_EVENTS = ("RequestAdvanced", "ContractNetSlot", "ContractNetParticipantPhase")
VARIANTS = {
    "EV-NORECV": ("Received",),
    "EV-NOPHASE": PHASE_EVENTS,
    "EV-NONE": ("Received",) + PHASE_EVENTS,
}


def strip_emits(text: str, events: tuple[str, ...]) -> tuple[str, int]:
    removed = 0
    out = text
    for ev in events:
        pat = re.compile(r"\n([ \t]*)emit " + re.escape(ev) + r"\(")
        while True:
            m = pat.search(out)
            if not m:
                break
            i = m.end()
            depth = 1
            while depth:
                depth += {"(": 1, ")": -1}.get(out[i], 0)
                i += 1
            if out[i] != ";":
                raise SystemExit(f"unexpected emit termination for {ev}")
            out = out[: m.start()] + out[i + 1:]
            removed += 1
    return out, removed


def base_files() -> dict[str, str]:
    names = subprocess.run(
        ["git", "ls-tree", "--name-only", BASE_SHA, "src/core/"],
        cwd=str(ROOT.parent / "blade"), capture_output=True, text=True, check=True,
    ).stdout.split()
    return {
        Path(n).name: subprocess.run(
            ["git", "show", f"{BASE_SHA}:{n}"], cwd=str(ROOT.parent / "blade"),
            capture_output=True, text=True, check=True,
        ).stdout
        for n in names if n.endswith(".sol")
    }


def generate() -> dict[str, dict[str, str]]:
    files = base_files()
    trees = {}
    for name, events in VARIANTS.items():
        tree = {}
        counts = {}
        for fname, text in files.items():
            new, k = strip_emits(text, events)
            if k:
                counts[fname] = k
            tree[fname] = new
        if sum(counts.values()) == 0:
            raise SystemExit(f"{name}: nothing removed")
        trees[name] = tree
        print(name, "removed emits:", counts)
    return trees


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    trees = generate()
    bad = []
    for name, tree in trees.items():
        d = DEST / name
        if a.check:
            for fname, text in tree.items():
                p = d / fname
                if not p.is_file() or p.read_text() != text:
                    bad.append(str(p))
            extra = {p.name for p in d.glob("*.sol")} - set(tree)
            bad += [str(d / e) for e in extra]
            continue
        d.mkdir(parents=True, exist_ok=True)
        for fname, text in tree.items():
            (d / fname).write_text(text)
    if bad:
        print("EVENT VARIANT CHECK FAIL:", *bad, sep="\n  ")
        sys.exit(1)
    print("EVENT VARIANTS", "CHECK PASS" if a.check else "WRITTEN", "base", BASE_SHA)


if __name__ == "__main__":
    main()
