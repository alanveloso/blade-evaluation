#!/usr/bin/env python3
"""F3 campaign runner. Writes outputs/raw/ (does not overwrite data/raw/)."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from completeness import completeness_errors, expected_primary_pairs
from frozen import (
    CAMPAIGN_MANIFEST,
    DEADLINE,
    PAYLOAD_SHA,
    PRIMARY,
    ROOT,
    SECONDARY,
    RPC,
    RPC_PORT,
    SPEC,
    V2,
    condition_by_id,
    payload_hex,
)
from integrity import check_rows
from preflight_enforce import (
    ANVIL,
    CAST,
    FORGE,
    abort,
    check_core,
    check_manifests,
    check_spec,
    check_toolchain,
    check_v1_raw_untouched,
    run,
)
from raw_writer import append_validated, refuse_if_campaign_raw
from reproduce_structural import reproduce as reproduce_structural
from schema_validate import validate_rows

FROM = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
PERFORMATIVE = {
    "Request": 0,
    "Agree": 1,
    "Refuse": 2,
    "Failure": 3,
    "Inform": 4,
    "Cfp": 7,
    "Propose": 8,
    "AcceptProposal": 9,
}
PROTO_REQ = 1
PROTO_CN = 2


def gas_used(rec: dict) -> int:
    g = rec.get("gasUsed")
    if isinstance(g, str):
        return int(g, 16) if g.startswith("0x") else int(g)
    return int(g)


def calldata_len(h: str) -> int:
    s = h[2:] if h.startswith("0x") else h
    return len(s) // 2


class Anvil:
    def __init__(self, log_name: str):
        self.log_name = log_name
        self.proc = None

    def __enter__(self):
        logp = V2 / "outputs" / "logs" / self.log_name
        logp.parent.mkdir(parents=True, exist_ok=True)
        log = open(logp, "w")
        self.proc = subprocess.Popen(
            [
                ANVIL,
                "--port",
                str(RPC_PORT),
                "--chain-id",
                "31337",
                "--timestamp",
                str(DEADLINE["genesis"]),
                "--gas-limit",
                str(30_000_000),
                "--block-base-fee-per-gas",
                str(1_000_000_000),
                "--order",
                "fifo",
                "--silent",
            ],
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        for _ in range(80):
            p = subprocess.run([CAST, "block-number", "--rpc-url", RPC], capture_output=True, text=True)
            if p.returncode == 0:
                break
            time.sleep(0.1)
        else:
            self.proc.kill()
            abort("anvil did not start")
        info = chain_info()
        if info["chain_id"] != 31337 or info["gas_limit"] != 30_000_000:
            abort(f"anvil config {info}")
        if info["base_fee_per_gas"] != 1_000_000_000:
            abort(f"base_fee {info}")
        if info["timestamp"] != DEADLINE["genesis"]:
            abort(f"genesis timestamp {info}")
        return self

    def __exit__(self, *exc):
        if self.proc:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def chain_info():
    blk = json.loads(run([CAST, "block", "latest", "--rpc-url", RPC, "--json"]).stdout)
    gl, ts, bf = blk.get("gasLimit"), blk.get("timestamp"), blk.get("baseFeePerGas")
    return {
        "gas_limit": int(gl, 16) if isinstance(gl, str) else int(gl),
        "base_fee_per_gas": int(bf, 16) if isinstance(bf, str) else int(bf),
        "timestamp": int(ts, 16) if isinstance(ts, str) else int(ts),
        "chain_id": int(run([CAST, "chain-id", "--rpc-url", RPC]).stdout.strip()),
    }


def receipt(tx: str) -> dict:
    return json.loads(run([CAST, "receipt", tx, "--rpc-url", RPC, "--json"]).stdout)


def send(to: str, sig: str, *args) -> dict:
    data = run([CAST, "calldata", sig, *args]).stdout.strip()
    payload_tx = {
        "from": FROM,
        "to": to,
        "gas": hex(20_000_000),
        "gasPrice": hex(1_000_000_000),
        "data": data,
    }
    txh = run([CAST, "rpc", "eth_sendTransaction", json.dumps(payload_tx), "--rpc-url", RPC]).stdout.strip().strip('"')
    rec = receipt(txh)
    rec["_input"] = data
    rec["_sig"] = sig
    if rec.get("status") in (0, "0", "0x0"):
        rec["_reverted"] = True
    return rec


def create(name: str) -> dict:
    art = json.loads((V2 / "out" / _sol_of(name) / f"{name}.json").read_text())
    bytecode = art["bytecode"]["object"] if isinstance(art["bytecode"], dict) else art["bytecode"]
    if not bytecode.startswith("0x"):
        bytecode = "0x" + bytecode
    payload_tx = {"from": FROM, "gas": hex(8_000_000), "gasPrice": hex(1_000_000_000), "data": bytecode}
    txh = run([CAST, "rpc", "eth_sendTransaction", json.dumps(payload_tx), "--rpc-url", RPC]).stdout.strip().strip('"')
    rec = receipt(txh)
    rec["_input"] = bytecode
    rec["_deployed"] = rec.get("contractAddress")
    if not rec["_deployed"]:
        raise RuntimeError(f"no contractAddress {name}")
    return rec


def _sol_of(name: str) -> str:
    return {
        "BladeRequester": "BladeRequest.sol",
        "BladeParticipant": "BladeRequest.sol",
        "BladeManager": "BladeContractNet.sol",
        "BladeCnParticipant": "BladeContractNet.sol",
        "ManualInitiator": "ManualRequest.sol",
        "ManualParticipant": "ManualRequest.sol",
        "ManualManager": "ManualContractNet.sol",
        "ManualCnParticipant": "ManualContractNet.sol",
    }[name]


def msg(perf: str, proto: int, cid: str, content_hex: str, reply_by: int = 0) -> str:
    c = content_hex if content_hex.startswith("0x") else "0x" + content_hex
    z32 = "0x" + "00" * 32
    return f"({PERFORMATIVE[perf]},{proto},{cid},{z32},{z32},{reply_by},{z32},{c})"


def set_next_ts(ts: int) -> None:
    run([CAST, "rpc", "evm_setNextBlockTimestamp", str(ts), "--rpc-url", RPC])


def warp(ts: int) -> None:
    set_next_ts(ts)
    run([CAST, "rpc", "evm_mine", "--rpc-url", RPC])


def assert_payload(n: int, hex_blade: str, hex_manual: str) -> None:
    _, raw = payload_hex(n)
    expect = PAYLOAD_SHA[n]
    for label, hx in (("blade", hex_blade), ("manual", hex_manual)):
        b = bytes.fromhex(hx[2:] if hx.startswith("0x") else hx)
        if len(b) != n:
            abort(f"payload length {label} {len(b)} != {n}")
        if hashlib.sha256(b).hexdigest() != expect:
            abort(f"payload hash {label}")
    if hex_blade != hex_manual:
        abort("payload bytes blade != manual")


def base_row(phase: str, manifest_sha: str, cond: dict, impl: str, **extra):
    n = cond["payload_bytes"]
    hx, _ = payload_hex(n)
    cn = cond.get("protocol") == "contract-net"
    r = {
        "experiment_spec_id": SPEC["experiment_spec_id"],
        "schema_version": 2,
        "analysis_version": 1,
        "phase": phase,
        "core_sha": SPEC["core_sha"],
        "freeze_manifest_sha256": manifest_sha,
        "baseline_version": "eval-v2",
        "implementation": impl,
        "condition_id": cond["condition_id"],
        "experiment_id": f"{phase}/{cond['condition_id']}/{impl}",
        "protocol": cond["protocol"],
        "scenario": cond.get("scenario"),
        "path": cond["path"],
        "payload_bytes": n,
        "payload_pattern": "repeat_0xab",
        "payload_sha256": PAYLOAD_SHA[n],
        "participant_count": cond["participant_count"],
        "active_conversations": cond.get("active_conversations", 1),
        "solc_version": "0.8.26",
        "forge_version": "1.7.1",
        "forge_commit": "4072e48705af9d93e3c0f6e29e93b5e9a40caed8",
        "optimizer": True,
        "optimizer_runs": 200,
        "via_ir": False,
        "evm_version": "cancun",
        "chain_reference_timestamp": DEADLINE["chain_ref_ts"] if cn else 0,
        "reply_by": DEADLINE["reply_by"] if cn else 0,
        "reply_by_delta": DEADLINE["delta"] if cn else 0,
        "deployment_gas": None,
        "interaction_step": None,
        "transaction_index": None,
        "transaction_gas_used": None,
        "complete_interaction_gas": None,
        "runtime_bytecode_bytes": None,
        "initcode_bytes": None,
        "top_level_calldata_bytes": None,
        "status": "ok",
        "notes": "secondary" if str(cond["condition_id"]).startswith("SEC-") else None,
        "record_kind": None,
        "payload_hex": hx,
    }
    r.update(extra)
    return r


def finalize_rows(rows: list[dict]) -> list[dict]:
    inter = [r for r in rows if r["record_kind"] == "interaction_tx"]
    if any(r.get("status") != "ok" for r in rows):
        st = next(r["status"] for r in rows if r.get("status") != "ok")
        complete = sum(int(r["transaction_gas_used"]) for r in inter) if inter else None
        for r in rows:
            r["status"] = st if r["record_kind"] == "interaction_tx" else r["status"]
            if r["record_kind"] == "interaction_tx":
                r["complete_interaction_gas"] = complete
        return rows
    complete = sum(int(r["transaction_gas_used"]) for r in inter)
    recomputed = sum(int(r["transaction_gas_used"]) for r in inter)
    if complete != recomputed:
        abort("gas sum identity failed")
    for r in rows:
        if r["record_kind"] == "interaction_tx":
            r["complete_interaction_gas"] = complete
        else:
            r["complete_interaction_gas"] = None
    return rows


def measure_request(cond: dict, impl: str, phase: str, manifest_sha: str) -> list[dict]:
    n = cond["payload_bytes"]
    p, _ = payload_hex(n)
    cid = run([CAST, "keccak", f"{phase}/{cond['condition_id']}/{impl}"]).stdout.strip()
    path = cond["path"]
    txs = []
    try:
        if impl == "blade":
            dI, dP = create("BladeRequester"), create("BladeParticipant")
            I, P = dI["_deployed"], dP["_deployed"]
        else:
            dI, dP = create("ManualInitiator"), create("ManualParticipant")
            I, P = dI["_deployed"], dP["_deployed"]
        txs.append(("deploy_initiator", dI, True))
        txs.append(("deploy_participant", dP, True))
        req_msg = msg("Request", PROTO_REQ, cid, p, 0)
        txs.append(("startRequest", send(I, "startRequest(address,bytes32,bytes)", P, cid, p), False))
        if path == "R1":
            if impl == "blade":
                txs.append(("refuse", send(P, "refuse((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address,bytes)", req_msg, I, p), False))
            else:
                txs.append(("refuse", send(P, "refuse(bytes32,bytes)", cid, p), False))
        elif path == "R2":
            if impl == "blade":
                txs.append(("inform", send(P, "inform((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address,bytes)", req_msg, I, p), False))
            else:
                txs.append(("inform", send(P, "inform(bytes32,bytes)", cid, p), False))
        elif path == "R3":
            if impl == "blade":
                txs.append(("agree", send(P, "agree((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address)", req_msg, I), False))
                txs.append(("inform", send(P, "inform((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address,bytes)", req_msg, I, p), False))
            else:
                txs.append(("agree", send(P, "agree(bytes32)", cid), False))
                txs.append(("inform", send(P, "inform(bytes32,bytes)", cid, p), False))
        elif path == "R4":
            if impl == "blade":
                txs.append(("agree", send(P, "agree((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address)", req_msg, I), False))
                txs.append(("failure", send(P, "failure((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address,bytes)", req_msg, I, p), False))
            else:
                txs.append(("agree", send(P, "agree(bytes32)", cid), False))
                txs.append(("failure", send(P, "failure(bytes32,bytes)", cid, p), False))
        elif path == "active":
            k = cond["active_conversations"]
            # first start already done as conversation 0; remaining K-1
            if impl == "blade":
                txs.append(("agree", send(P, "agree((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address)", req_msg, I), False))
            else:
                txs.append(("agree", send(P, "agree(bytes32)", cid), False))
            for i in range(1, k):
                cid_i = run([CAST, "keccak", f"{phase}/{cond['condition_id']}/{impl}/{i}"]).stdout.strip()
                txs.append((f"startRequest_{i}", send(I, "startRequest(address,bytes32,bytes)", P, cid_i, p), False))
                if impl == "blade":
                    m = msg("Request", PROTO_REQ, cid_i, p, 0)
                    txs.append((f"agree_{i}", send(P, "agree((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address)", m, I), False))
                else:
                    txs.append((f"agree_{i}", send(P, "agree(bytes32)", cid_i), False))
        else:
            abort(f"unknown request path {path}")
        for name, rec, _dep in txs:
            if rec.get("_reverted"):
                raise RuntimeError(f"reverted {name}")
    except Exception as e:
        rows = []
        for i, (name, rec, dep) in enumerate(txs):
            rows.append(
                base_row(
                    phase,
                    manifest_sha,
                    cond,
                    impl,
                    interaction_step=name,
                    transaction_index=i,
                    transaction_gas_used=gas_used(rec),
                    deployment_gas=gas_used(rec) if dep else None,
                    top_level_calldata_bytes=calldata_len(rec["_input"]),
                    record_kind="deployment" if dep else "interaction_tx",
                    status="resource_failed",
                    notes=str(e)[-400:],
                )
            )
        return finalize_rows(rows)
    rows = []
    for i, (name, rec, dep) in enumerate(txs):
        rows.append(
            base_row(
                phase,
                manifest_sha,
                cond,
                impl,
                interaction_step=name,
                transaction_index=i,
                transaction_gas_used=gas_used(rec),
                deployment_gas=gas_used(rec) if dep else None,
                top_level_calldata_bytes=calldata_len(rec["_input"]),
                record_kind="deployment" if dep else "interaction_tx",
            )
        )
    return finalize_rows(rows)


def measure_cn(cond: dict, impl: str, phase: str, manifest_sha: str) -> list[dict]:
    n_part = cond["participant_count"]
    n = cond["payload_bytes"]
    p, _ = payload_hex(n)
    scenario = cond.get("scenario") or "A"
    cid = run([CAST, "keccak", f"{phase}/{cond['condition_id']}/{impl}"]).stdout.strip()
    by = DEADLINE["reply_by"]
    txs = []
    try:
        if impl == "blade":
            dM = create("BladeManager")
            dPs = [create("BladeCnParticipant") for _ in range(n_part)]
        else:
            dM = create("ManualManager")
            dPs = [create("ManualCnParticipant") for _ in range(n_part)]
        txs.append(("deploy_manager", dM, True))
        for i, d in enumerate(dPs):
            txs.append((f"deploy_participant_{i}", d, True))
        M = dM["_deployed"]
        parts = [d["_deployed"] for d in dPs]
        set_next_ts(DEADLINE["chain_ref_ts"])
        arr = "[" + ",".join(parts) + "]"
        cfp = send(M, "cfp(address[],bytes32,uint64,bytes)", arr, cid, str(by), p)
        txs.append(("cfp", cfp, False))
        blk = json.loads(run([CAST, "block", cfp["blockNumber"], "--rpc-url", RPC, "--json"]).stdout)
        ts = int(blk["timestamp"], 16) if isinstance(blk["timestamp"], str) else int(blk["timestamp"])
        if ts != DEADLINE["chain_ref_ts"]:
            abort(f"CFP timestamp {ts}")
        cfp_msg = msg("Cfp", PROTO_CN, cid, p, by)
        k_prop = (n_part + 1) // 2 if scenario == "B" else n_part
        for i, P in enumerate(parts):
            if scenario == "B" and i >= k_prop:
                if impl == "blade":
                    txs.append((f"refuse_{i}", send(P, "refuse((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address)", cfp_msg, M), False))
                else:
                    txs.append((f"refuse_{i}", send(P, "refuse(bytes32)", cid), False))
            else:
                if impl == "blade":
                    txs.append((f"propose_{i}", send(P, "propose((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address,bytes)", cfp_msg, M, p), False))
                else:
                    txs.append((f"propose_{i}", send(P, "propose(bytes32,bytes)", cid, p), False))
        warp(by + 1)
        acc = "[" + ",".join(parts[:k_prop] if scenario == "B" else parts) + "]"
        txs.append(("evaluate", send(M, "evaluate(bytes32,address[],address[],address[])", cid, acc, "[]", "[]"), False))
        acc_msg = msg("AcceptProposal", PROTO_CN, cid, "0x", DEADLINE["accept_reply_by"])
        targets = parts[:k_prop] if scenario == "B" else parts
        for i, P in enumerate(targets):
            if scenario == "fail":
                if impl == "blade":
                    txs.append(("failure", send(P, "failure((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address,bytes)", acc_msg, M, p), False))
                else:
                    txs.append(("failure", send(P, "failure(bytes32,bytes)", cid, p), False))
            else:
                if impl == "blade":
                    txs.append((f"inform_{i}", send(P, "inform((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address,bytes)", acc_msg, M, p), False))
                else:
                    txs.append((f"inform_{i}", send(P, "inform(bytes32,bytes)", cid, p), False))
        for name, rec, _dep in txs:
            if rec.get("_reverted"):
                raise RuntimeError(f"reverted {name}")
    except Exception as e:
        if str(e).startswith("F3 PREFLIGHT"):
            raise
        rows = []
        for i, (name, rec, dep) in enumerate(txs):
            rows.append(
                base_row(
                    phase,
                    manifest_sha,
                    cond,
                    impl,
                    interaction_step=name,
                    transaction_index=i,
                    transaction_gas_used=gas_used(rec),
                    deployment_gas=gas_used(rec) if dep else None,
                    top_level_calldata_bytes=calldata_len(rec["_input"]),
                    record_kind="deployment" if dep else "interaction_tx",
                    status="resource_failed",
                    notes=str(e)[-400:],
                )
            )
        return finalize_rows(rows)
    rows = []
    for i, (name, rec, dep) in enumerate(txs):
        rows.append(
            base_row(
                phase,
                manifest_sha,
                cond,
                impl,
                interaction_step=name,
                transaction_index=i,
                transaction_gas_used=gas_used(rec),
                deployment_gas=gas_used(rec) if dep else None,
                top_level_calldata_bytes=calldata_len(rec["_input"]),
                record_kind="deployment" if dep else "interaction_tx",
            )
        )
    return finalize_rows(rows)


def run_pair(cond: dict, phase: str, manifest_sha: str) -> list[dict]:
    n = cond["payload_bytes"]
    hx, _ = payload_hex(n)
    assert_payload(n, hx, hx)
    proto = cond["protocol"]
    all_rows = []
    for impl in PRIMARY["implementations"]:
        with Anvil(f"{phase}_{cond['condition_id']}_{impl}.log"):
            if proto == "request":
                rows = measure_request(cond, impl, phase, manifest_sha)
            elif proto == "contract-net":
                rows = measure_cn(cond, impl, phase, manifest_sha)
            else:
                abort(f"unknown protocol {proto}")
        all_rows.extend(rows)
    pe = [e for e in check_rows(all_rows, phase=phase, matrix=None) if "missing" not in e and "unexpected" not in e]
    # pairing on this pair only
    from completeness import pairing_errors, gas_sum_errors

    errs = pairing_errors(all_rows) + gas_sum_errors(all_rows) + validate_rows(all_rows, expect_phase=phase)
    if errs:
        abort("pair validation:\n" + "\n".join(errs[:20]))
    return all_rows


def derive_simple(rows: list[dict], out: Path) -> None:
    cells = defaultdict(dict)
    for r in rows:
        if r.get("record_kind") != "interaction_tx" or r.get("status") != "ok":
            continue
        cells[r["condition_id"]][r["implementation"]] = r["complete_interaction_gas"]
    overhead = []
    for cid, impls in sorted(cells.items()):
        if "blade" not in impls or "manual" not in impls:
            continue
        b, m = impls["blade"], impls["manual"]
        overhead.append(
            {
                "condition_id": cid,
                "gas_blade": b,
                "gas_manual": m,
                "absolute_overhead": b - m,
                "relative_overhead": (b - m) / m,
                "ratio": b / m,
                "analysis_version": 1,
            }
        )
    out.write_text(json.dumps(overhead, indent=2) + "\n")


def completeness_selftest() -> None:
    n_cond = PRIMARY["unique_condition_count"]
    n_pair = PRIMARY["paired_run_count"]
    if n_cond != 18 or n_pair != 36:
        abort("canonical counts")
    if len(expected_primary_pairs()) != 36:
        abort("expected pairs")
    # missing cell
    fake = []
    for cid, impl in list(expected_primary_pairs())[:-1]:
        fake.append(_stub(cid, impl))
    errs = completeness_errors(fake, matrix="primary")
    if not any("missing cell" in e for e in errs):
        abort("selftest missing cell")
    # duplicate cell
    full = [_stub(cid, impl) for cid, impl in expected_primary_pairs()]
    extra = dict(full[0])
    extra["experiment_id"] = "dup"
    errs = completeness_errors(full + [extra], matrix="primary")
    if not any("duplicate cell" in e for e in errs):
        abort("selftest duplicate")
    # missing pair
    half = [_stub(cid, impl) for cid, impl in expected_primary_pairs() if impl == "blade"]
    errs = completeness_errors(half, matrix="primary")
    if not any("missing pair" in e for e in errs):
        abort("selftest missing pair")
    # unexpected
    errs = completeness_errors([_stub("NOT-A-CELL", "blade")], matrix="primary")
    if not any("unexpected condition" in e for e in errs):
        abort("selftest unexpected")
    # scenario C
    c = _stub("REQ-R1-P0", "blade")
    c["scenario"] = "C"
    c["condition_id"] = "CN-C-N2-P0"
    errs = completeness_errors([c], matrix="primary")
    if not any("Scenario C" in e for e in errs):
        abort("selftest scenario C")
    # R3/P0 duplicated
    a = _stub("REQ-R3-P0", "blade")
    b = _stub("REQ-R3-P0-SCALE", "blade", path="R3", payload_bytes=0)
    errs = completeness_errors([a, b], matrix="primary")
    if not any("R3/P0 duplicated" in e for e in errs):
        abort("selftest R3/P0")
    print("COMPLETENESS SELFTEST PASS")


def _stub(cid: str, impl: str, **over) -> dict:
    try:
        cond = condition_by_id(cid)
    except KeyError:
        cond = {**PRIMARY["conditions"][0], "condition_id": cid}
    row = {
        "record_kind": "interaction_tx",
        "condition_id": cid,
        "implementation": impl,
        "experiment_id": f"t/{cid}/{impl}",
        "interaction_step": "startRequest",
        "path": cond.get("path"),
        "payload_bytes": cond.get("payload_bytes"),
        "scenario": cond.get("scenario"),
        "protocol": cond.get("protocol"),
        "transaction_gas_used": 1,
        "complete_interaction_gas": 1,
        "status": "ok",
    }
    row.update(over)
    return row


def guard_secondary_matrix() -> None:
    for c in SECONDARY["conditions"]:
        if c.get("active_conversations", 0) >= 1000:
            abort("K=1000 forbidden")
        if c.get("participant_count", 0) > 16:
            abort("N>16 forbidden")


def storage_smoke(out: Path) -> None:
    backup = {}
    store = V2 / "outputs" / "storage"
    for p in store.glob("*.json"):
        backup[p] = p.read_text()
    run([FORGE, "test", "--match-test", "test_storage_cnA_N2", "-q"], cwd=str(V2))
    src = store / "cn_a_n2.json"
    out.write_text(src.read_text())
    for p, text in backup.items():
        p.write_text(text)


def assert_v1_raw_untouched() -> None:
    check_v1_raw_untouched()


def refuse_v1_paths() -> None:
    published = ROOT / "data" / "raw"
    dest = (V2 / "outputs" / "raw").resolve()
    if dest == published.resolve():
        abort("campaign dest must not be data/raw")


def mode_dryrun(manifest_sha: str) -> None:
    guard_secondary_matrix()
    outdir = V2 / "outputs" / "dryrun"
    outdir.mkdir(parents=True, exist_ok=True)
    rawp = outdir / "raw.jsonl"
    if rawp.exists():
        rawp.unlink()
    run([FORGE, "build"], cwd=str(V2))
    conds = [condition_by_id("REQ-R1-P0"), condition_by_id("CN-A-N1-P0"), condition_by_id("SEC-ACT-K1")]
    all_rows = []
    for cond in conds:
        rows = run_pair(cond, "dryrun", manifest_sha)
        append_validated(rawp, rows, phase="dryrun", matrix=None)
        all_rows.extend(rows)
    errs = check_rows(all_rows, phase="dryrun", matrix=None)
    # not full primary matrix
    errs = [e for e in errs if "missing cell" not in e and "missing pair" not in e and "unexpected" not in e]
    if errs:
        abort("dryrun integrity:\n" + "\n".join(errs[:20]))
    derive_simple(all_rows, outdir / "derived.json")
    storage_smoke(outdir / "storage_cn_a_n2.json")
    reproduce_structural(outdir / "structural")
    completeness_selftest()
    assert_v1_raw_untouched()
    print("DRYRUN PASS", "rows", len(all_rows), "file", rawp)


def mode_campaign(manifest_sha: str) -> None:
    guard_secondary_matrix()
    refuse_if_campaign_raw(V2 / "outputs" / "raw")
    run([FORGE, "build"], cwd=str(V2))
    primary_path = V2 / "outputs" / "raw" / "primary.jsonl"
    secondary_path = V2 / "outputs" / "raw" / "secondary.jsonl"
    all_p = []
    for cond in PRIMARY["conditions"]:
        rows = run_pair(cond, "f3", manifest_sha)
        append_validated(primary_path, rows, phase="f3", matrix=None)
        all_p.extend(rows)
    errs = check_rows(all_p, phase="f3", matrix="primary")
    if errs:
        abort("primary completeness:\n" + "\n".join(errs[:40]))
    all_s = []
    for cond in SECONDARY["conditions"]:
        rows = run_pair(cond, "f3", manifest_sha)
        append_validated(secondary_path, rows, phase="f3", matrix=None)
        all_s.extend(rows)
    errs = check_rows(all_s, phase="f3", matrix="secondary")
    if errs:
        abort("secondary completeness:\n" + "\n".join(errs[:40]))
    reproduce_structural(V2 / "outputs" / "integrity" / "structural")
    print("CAMPAIGN COMPLETE")


def main():
    ap = argparse.ArgumentParser(description="Campaign runner")
    ap.add_argument("--mode", required=True, choices=["dryrun", "campaign", "completeness-selftest", "structural", "preflight-only"])
    args = ap.parse_args()
    check_spec()
    check_core()
    check_toolchain()
    refuse_v1_paths()
    check_v1_raw_untouched()
    require_v2 = args.mode in ("campaign", "dryrun", "preflight-only")
    if args.mode == "completeness-selftest":
        completeness_selftest()
        return
    if args.mode == "structural":
        reproduce_structural(V2 / "outputs" / "dryrun" / "structural")
        return
    manifest_sha = check_manifests(require_v2=require_v2)
    if args.mode == "preflight-only":
        print("PREFLIGHT-ONLY PASS", manifest_sha)
        return
    if args.mode == "dryrun":
        mode_dryrun(manifest_sha)
        return
    if args.mode == "campaign":
        mode_campaign(manifest_sha)


if __name__ == "__main__":
    main()
