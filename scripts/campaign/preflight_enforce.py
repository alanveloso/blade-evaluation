#!/usr/bin/env python3
"""Abort-on-mismatch preflight for the published evaluation artifact."""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

from frozen import (
    BLADE,
    CAMPAIGN_MANIFEST,
    EXPECT_COMMIT,
    EXPECT_FORGE,
    EXPECT_SOLC,
    NEW_CORE,
    ROOT,
    SPEC,
    V1_RAW,
)

CAST = os.environ.get("CAST", str(Path.home() / ".foundry/bin/cast"))
FORGE = os.environ.get("FORGE", str(Path.home() / ".foundry/bin/forge"))
ANVIL = os.environ.get("ANVIL", str(Path.home() / ".foundry/bin/anvil"))


def abort(msg: str) -> None:
    print("PREFLIGHT ABORT:", msg, file=sys.stderr)
    sys.exit(2)


def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout or "fail")[-800:])
    return p


def parse_forge(text: str) -> tuple[str, str]:
    ver = re.search(r"Version:\s*(\S+)", text)
    sha = re.search(r"Commit SHA:\s*([0-9a-f]{40})", text)
    if not ver or not sha:
        abort(f"unparseable version:\n{text}")
    return ver.group(1), sha.group(1)


def check_spec() -> None:
    if SPEC["schema_version"] != 2:
        abort("schema_version")
    if SPEC["analysis_version"] != 1:
        abort("analysis_version")
    if SPEC["core_sha"] != NEW_CORE:
        abort("core_sha in spec")
    if SPEC["payload_pattern"] != "repeat_0xab":
        abort("payload_pattern")


def check_core() -> None:
    if not BLADE.is_dir():
        abort(f"BLADE Core missing at {BLADE} (clone sibling ../blade or set BLADE_CORE)")
    sha = run(["git", "rev-parse", "HEAD"], cwd=str(BLADE)).stdout.strip()
    if sha != SPEC["core_sha"]:
        abort(f"Core SHA {sha} != spec {SPEC['core_sha']}")
    st = run(["git", "status", "--short"], cwd=str(BLADE)).stdout
    if st.strip():
        abort("Core working tree not empty")


def check_toolchain() -> None:
    fv, fc = parse_forge(run([FORGE, "--version"]).stdout)
    av, ac = parse_forge(run([ANVIL, "--version"]).stdout)
    cv, cc = parse_forge(run([CAST, "--version"]).stdout)
    if fv != EXPECT_FORGE or fc != EXPECT_COMMIT:
        abort(f"forge {fv} {fc}")
    if av != EXPECT_FORGE or ac != EXPECT_COMMIT:
        abort(f"anvil {av} {ac}")
    if cv != EXPECT_FORGE or cc != EXPECT_COMMIT:
        abort(f"cast {cv} {cc}")
    cfg = json.loads(run([FORGE, "config", "--json"], cwd=str(ROOT)).stdout)
    if cfg.get("solc") != EXPECT_SOLC:
        abort(f"solc {cfg.get('solc')}")
    if cfg.get("optimizer") is not True:
        abort("optimizer")
    if int(cfg.get("optimizer_runs")) != 200:
        abort("optimizer_runs")
    if cfg.get("via_ir") is not False:
        abort("via_ir")
    if cfg.get("evm_version") != "cancun":
        abort("evm_version")


def _check_manifest(path: Path) -> str:
    p = subprocess.run(
        ["sha256sum", "--check", "--strict", str(path)],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        abort(f"manifest check failed {path.name}:\n{(p.stderr or p.stdout)[-1500:]}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_manifests(*, require_v2: bool) -> str:
    if require_v2:
        if not CAMPAIGN_MANIFEST.is_file():
            abort("missing PUBLIC_MANIFEST.sha256")
        return _check_manifest(CAMPAIGN_MANIFEST)
    return ""


def check_v1_raw_untouched() -> None:
    for p in V1_RAW:
        if not p.is_file():
            abort(f"historical raw missing {p}")


def campaign_records_present() -> bool:
    raw = ROOT / "outputs" / "raw"
    if not raw.is_dir():
        return False
    return any(p.suffix == ".jsonl" and p.stat().st_size > 0 for p in raw.iterdir())
