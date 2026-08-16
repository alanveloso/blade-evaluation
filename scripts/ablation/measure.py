#!/usr/bin/env python3
"""Ablation measurements vs official BLADE. Does not write F3 raw or public Core."""
from __future__ import annotations

import hashlib
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ABL = ROOT / "ablation"
BLADE = Path(os.environ.get("BLADE_CORE", ROOT.parent / "blade")).resolve()
CAST = os.environ.get("CAST", str(Path.home() / ".foundry/bin/cast"))
FORGE = os.environ.get("FORGE", str(Path.home() / ".foundry/bin/forge"))
ANVIL = os.environ.get("ANVIL", str(Path.home() / ".foundry/bin/anvil"))
RPC = "http://127.0.0.1:8549"
FROM = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
PERFORMATIVE = {
    "Request": 0, "Agree": 1, "Refuse": 2, "Failure": 3, "Inform": 4,
    "Cfp": 7, "Propose": 8, "AcceptProposal": 9,
}
CHAIN_REF, DELTA, REPLY_BY, GENESIS = 1700001000, 100, 1700001100, 1700000000


def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout or "fail")[-1200:])
    return p


def gas_used(rec):
    g = rec.get("gasUsed")
    return int(g, 16) if isinstance(g, str) and g.startswith("0x") else int(g)


def calldata_len(h):
    s = h[2:] if h.startswith("0x") else h
    return len(s) // 2


def payload_hex(n):
    raw = bytes([0xAB] * n)
    return ("0x" + raw.hex() if n else "0x"), raw


def remap(variant: str) -> str:
    if variant == "A0":
        return f"blade/={BLADE}/src/"
    return f"blade/core/={ROOT}/ablation/variants/{variant}/"


def build(variant: str) -> dict:
    run([FORGE, "build", "--force", "--remappings", remap(variant)], cwd=str(ROOT))
    names = {
        "BladeRequester": "BladeRequest.sol",
        "BladeParticipant": "BladeRequest.sol",
        "BladeManager": "BladeContractNet.sol",
        "BladeCnParticipant": "BladeContractNet.sol",
    }
    out = {}
    for name, sol in names.items():
        art = json.loads((ROOT / "out" / sol / f"{name}.json").read_text())
        def blen(obj):
            if isinstance(obj, dict):
                obj = obj.get("object") or ""
            s = obj[2:] if isinstance(obj, str) and obj.startswith("0x") else obj
            return len(s) // 2
        out[name] = {
            "runtime_bytecode_bytes": blen(art.get("deployedBytecode")),
            "initcode_bytes": blen(art.get("bytecode")),
        }
    return out


class Anvil:
    def __enter__(self):
        logp = ABL / "logs" / "anvil.log"
        logp.parent.mkdir(parents=True, exist_ok=True)
        log = open(logp, "w")
        self.proc = subprocess.Popen(
            [ANVIL, "--port", "8549", "--chain-id", "31337", "--timestamp", str(GENESIS),
             "--gas-limit", "30000000", "--block-base-fee-per-gas", "1000000000",
             "--order", "fifo", "--silent"],
            stdout=log, stderr=subprocess.STDOUT,
        )
        for _ in range(80):
            p = subprocess.run([CAST, "block-number", "--rpc-url", RPC], capture_output=True, text=True)
            if p.returncode == 0:
                break
            time.sleep(0.1)
        else:
            self.proc.kill()
            raise RuntimeError("anvil")
        return self

    def __exit__(self, *exc):
        self.proc.send_signal(signal.SIGTERM)
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def receipt(tx):
    return json.loads(run([CAST, "receipt", tx, "--rpc-url", RPC, "--json"]).stdout)


def send(to, sig, *args):
    data = run([CAST, "calldata", sig, *args]).stdout.strip()
    payload_tx = {"from": FROM, "to": to, "gas": hex(20_000_000), "gasPrice": hex(1_000_000_000), "data": data}
    txh = run([CAST, "rpc", "eth_sendTransaction", json.dumps(payload_tx), "--rpc-url", RPC]).stdout.strip().strip('"')
    rec = receipt(txh)
    rec["_input"] = data
    if rec.get("status") in (0, "0", "0x0"):
        rec["_reverted"] = True
    return rec


def create(name):
    sol = {
        "BladeRequester": "BladeRequest.sol", "BladeParticipant": "BladeRequest.sol",
        "BladeManager": "BladeContractNet.sol", "BladeCnParticipant": "BladeContractNet.sol",
    }[name]
    art = json.loads((ROOT / "out" / sol / f"{name}.json").read_text())
    bytecode = art["bytecode"]["object"] if isinstance(art["bytecode"], dict) else art["bytecode"]
    if not bytecode.startswith("0x"):
        bytecode = "0x" + bytecode
    payload_tx = {"from": FROM, "gas": hex(8_000_000), "gasPrice": hex(1_000_000_000), "data": bytecode}
    txh = run([CAST, "rpc", "eth_sendTransaction", json.dumps(payload_tx), "--rpc-url", RPC]).stdout.strip().strip('"')
    rec = receipt(txh)
    rec["_input"] = bytecode
    rec["_deployed"] = rec.get("contractAddress")
    rec["_name"] = name
    return rec


def msg(perf, proto, cid, content_hex, reply_by=0):
    c = content_hex if content_hex.startswith("0x") else "0x" + content_hex
    z32 = "0x" + "00" * 32
    return f"({PERFORMATIVE[perf]},{proto},{cid},{z32},{z32},{reply_by},{z32},{c})"


def set_ts(ts):
    run([CAST, "rpc", "evm_setNextBlockTimestamp", str(ts), "--rpc-url", RPC])


def warp(ts):
    set_ts(ts)
    run([CAST, "rpc", "evm_mine", "--rpc-url", RPC])


def summarize(txs):
    inter = [(n, r) for n, r, dep in txs if not dep]
    if any(r.get("_reverted") for _, r, _ in txs):
        raise RuntimeError("reverted " + ",".join(n for n, r, _ in txs if r.get("_reverted")))
    igas = sum(gas_used(r) for _, r in inter)
    dgas = {n: gas_used(r) for n, r, dep in txs if dep}
    cd = sum(calldata_len(r["_input"]) for _, r in inter)
    return {
        "complete_interaction_gas": igas,
        "deployment_gas": dgas,
        "interaction_calldata_bytes": cd,
        "steps": [{"step": n, "gas": gas_used(r), "calldata": calldata_len(r["_input"]), "deploy": dep} for n, r, dep in txs],
    }


def measure_request(path: str, nbytes: int):
    p, _ = payload_hex(nbytes)
    cid = run([CAST, "keccak", f"ablation/{path}/{nbytes}"]).stdout.strip()
    dI, dP = create("BladeRequester"), create("BladeParticipant")
    I, P = dI["_deployed"], dP["_deployed"]
    txs = [("deploy_initiator", dI, True), ("deploy_participant", dP, True)]
    req_msg = msg("Request", 1, cid, p, 0)
    txs.append(("startRequest", send(I, "startRequest(address,bytes32,bytes)", P, cid, p), False))
    if path == "R1":
        txs.append(("refuse", send(P, "refuse((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address,bytes)", req_msg, I, p), False))
    elif path == "R3":
        txs.append(("agree", send(P, "agree((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address)", req_msg, I), False))
        txs.append(("inform", send(P, "inform((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address,bytes)", req_msg, I, p), False))
    else:
        raise SystemExit(path)
    return summarize(txs)


def measure_cn(n_part: int, nbytes: int, pattern: str):
    """pattern: A = all accept; HALF = first n//2 accept, rest reject; all propose."""
    p, _ = payload_hex(nbytes)
    cid = run([CAST, "keccak", f"ablation/cn/{pattern}/{n_part}/{nbytes}"]).stdout.strip()
    dM = create("BladeManager")
    dPs = [create("BladeCnParticipant") for _ in range(n_part)]
    txs = [("deploy_manager", dM, True)]
    for i, d in enumerate(dPs):
        txs.append((f"deploy_participant_{i}", d, True))
    M = dM["_deployed"]
    parts = [d["_deployed"] for d in dPs]
    set_ts(CHAIN_REF)
    arr = "[" + ",".join(parts) + "]"
    cfp = send(M, "cfp(address[],bytes32,uint64,bytes)", arr, cid, str(REPLY_BY), p)
    txs.append(("cfp", cfp, False))
    cfp_msg = msg("Cfp", 2, cid, p, REPLY_BY)
    for i, P in enumerate(parts):
        txs.append((f"propose_{i}", send(P, "propose((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address,bytes)", cfp_msg, M, p), False))
    warp(REPLY_BY + 1)
    k = n_part // 2 if pattern == "HALF" else n_part
    acc = "[" + ",".join(parts[:k]) + "]"
    rej = "[" + ",".join(parts[k:]) + "]" if pattern == "HALF" else "[]"
    txs.append(("evaluate", send(M, "evaluate(bytes32,address[],address[],address[])", cid, acc, rej, "[]"), False))
    acc_msg = msg("AcceptProposal", 2, cid, "0x", 0)
    for i, P in enumerate(parts[:k]):
        txs.append((f"inform_{i}", send(P, "inform((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes),address,bytes)", acc_msg, M, p), False))
    return summarize(txs)


CELLS = {
    "A1": [("REQ", "R1", 0, None), ("REQ", "R3", 0, None), ("REQ", "R3", 1024, None),
           ("CN", "A", 0, 1), ("CN", "A", 0, 2)],
    "A2": [("REQ", "R1", 0, None), ("REQ", "R3", 0, None), ("REQ", "R3", 1024, None),
           ("CN", "A", 0, 2), ("CN", "A", 1024, 2)],
    "A3": [("CN", "A", 0, n) for n in (1, 2, 4, 8, 16)]
    + [("CN", "HALF", 0, n) for n in (2, 4, 8)],
    "A4": [("CN", "HALF", 0, n) for n in (2, 4, 8)] + [("CN", "A", 0, 2)],
    "A5": [("REQ", "R1", 0, None), ("REQ", "R3", 0, None), ("CN", "A", 0, 2), ("CN", "A", 0, 8)],
    "A34": [("CN", "HALF", 0, n) for n in (2, 4, 8)],
    "A0": None,  # filled as union
}


def cell_id(kind, path, nbytes, n):
    if kind == "REQ":
        return f"REQ-{path}-P{nbytes}"
    return f"CN-{path}-N{n}-P{nbytes}"


def all_cells():
    s = set()
    for k, cells in CELLS.items():
        if not cells:
            continue
        for c in cells:
            s.add(c)
    return sorted(s, key=str)


def measure_cell(kind, path, nbytes, n):
    with Anvil():
        if kind == "REQ":
            return measure_request(path, nbytes)
        return measure_cn(n, nbytes, path)


def main():
    ABL.mkdir(parents=True, exist_ok=True)
    (ABL / "raw").mkdir(exist_ok=True)
    variants = ["A0", "A1", "A2", "A3", "A4", "A5", "A34"]
    needed = {v: set(CELLS[v] if CELLS[v] else []) for v in variants}
    union = all_cells()
    needed["A0"] = set(union)
    results = {}
    bytecode = {}
    for v in variants:
        print("BUILD", v, flush=True)
        bytecode[v] = build(v)
        results[v] = {}
        for cell in sorted(needed[v], key=str):
            kind, path, nbytes, n = cell
            cid = cell_id(kind, path, nbytes, n)
            print("  ", v, cid, flush=True)
            results[v][cid] = measure_cell(kind, path, nbytes, n)
            results[v][cid]["cell"] = cid
    outp = ROOT / "outputs" / "ablation" / "raw"
    outp.mkdir(parents=True, exist_ok=True)
    rawp = outp / "ablation.json"
    rawp.write_text(json.dumps({"results": results, "bytecode": bytecode}, indent=2) + "\n")
    print("wrote", rawp)


if __name__ == "__main__":
    main()
