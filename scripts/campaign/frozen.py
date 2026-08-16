#!/usr/bin/env python3
"""Campaign constants for this evaluation artifact. Sibling Core: ../blade or $BLADE_CORE."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
V2 = ROOT
EVAL = ROOT
BLADE = Path(os.environ.get("BLADE_CORE", ROOT.parent / "blade")).resolve()

SPEC = json.loads((ROOT / "experiment/config/experiment_spec.json").read_text())
PRIMARY = json.loads((ROOT / "experiment/config/primary_matrix.json").read_text())
SECONDARY = json.loads((ROOT / "experiment/config/secondary_matrix.json").read_text())
RQ3 = json.loads((ROOT / "experiment/config/structural.json").read_text())
STATE = json.loads((ROOT / "data/derived/persistent_state.json").read_text())

CAMPAIGN_MANIFEST = ROOT / "PUBLIC_MANIFEST.sha256"
NEW_CORE = SPEC["core_sha"]
HISTORICAL_CORE = ""

EXPECT_FORGE = SPEC["toolchain"]["forge"]
EXPECT_COMMIT = SPEC["toolchain"]["foundry_commit"]
EXPECT_SOLC = SPEC["toolchain"]["solc"]
CHAIN_ID = int(SPEC["anvil"]["chain_id"])
GAS_LIMIT = int(SPEC["anvil"]["gas_limit"])
BASE_FEE = int(SPEC["anvil"]["base_fee_wei"])
GENESIS_TS = int(SPEC["anvil"]["genesis_timestamp"])
RPC_PORT = int(SPEC["anvil"]["rpc_port"])
RPC = f"http://127.0.0.1:{RPC_PORT}"

V1_RAW: tuple[Path, ...] = ()

PAYLOAD_SHA = {
    0: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    32: "9a2db2e23f1504cd056606553ac049c5e718e8f9ce9233876df1a7a1821af885",
    256: "1080e279b51b8594a78556e2fdb4dfe9ca82ac2fbab5007de2bac4213c2e1f92",
    1024: "4555555dc68d872c2270ba89ecc5f6f094812f65372b37e50071fe5168031c49",
}

DEADLINE = {
    "genesis": GENESIS_TS,
    "chain_ref_ts": int(SPEC["contract_net"]["CHAIN_REF_TS"]),
    "delta": int(SPEC["contract_net"]["DELTA"]),
    "reply_by": int(SPEC["contract_net"]["cfp_replyBy"]),
    "accept_reply_by": int(SPEC["contract_net"]["accept_proposal_replyBy"]),
    "reject_reply_by": int(SPEC["contract_net"]["reject_proposal_replyBy"]),
}


def payload_hex(n: int) -> tuple[str, bytes]:
    raw = bytes([0xAB] * n)
    h = hashlib.sha256(raw).hexdigest()
    if h != PAYLOAD_SHA[n]:
        raise SystemExit(f"repeat_0xab hash mismatch n={n}")
    return ("0x" + raw.hex() if n else "0x"), raw


def condition_by_id(cid: str) -> dict:
    for c in PRIMARY["conditions"]:
        if c["condition_id"] == cid:
            return c
    for c in SECONDARY["conditions"]:
        if c["condition_id"] == cid:
            return {**c, "experiment_class": "secondary"}
    raise KeyError(cid)
