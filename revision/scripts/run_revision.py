#!/usr/bin/env python3
"""JAAMAS revision runner.

Derived from scripts/campaign/run_campaign.py, which stays byte-identical because its SHA-256 is part
of the E0 provenance (PROVENANCE.md, PUBLIC_MANIFEST.sha256). Differences from that runner:

* Anvil is started with the campaign hardfork (`--hardfork cancun`) and the effective hardfork is
  validated through `anvil_nodeInfo` plus a Prague precompile probe before any measurement.
* `payload_encoding = minimal` reconstructs inbound messages for BLADE continuations without the
  original payload (neither the application wrapper nor the Core reads `inbound.content`).
* Inbound reconstructions carry the session token read from `requestStatus` (zero on Core fbf266f5).
* Every Core, overlay, manual variant and application source is compiled in an isolated project
  under outputs/revision/<campaign>/project and hashed into meta.json.

Outputs: outputs/revision/<campaign_id>/ only. data/raw/, ablation/raw/ and every file listed in
PUBLIC_MANIFEST.sha256 are verified untouched before and after a run.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "campaign"))

from completeness import completeness_errors, gas_sum_errors, pairing_errors  # noqa: E402
from frozen import DEADLINE, PAYLOAD_SHA, PRIMARY, SECONDARY, condition_by_id, payload_hex  # noqa: E402
from schema_validate import validate_rows  # noqa: E402

CFG_PATH = ROOT / "revision" / "config" / "campaigns.json"
CFG = json.loads(CFG_PATH.read_text())
OUT = ROOT / "outputs" / "revision"
CORES = ROOT / "outputs" / "cores"
CAST = os.environ.get("CAST", str(Path.home() / ".foundry/bin/cast"))
FORGE = os.environ.get("FORGE", str(Path.home() / ".foundry/bin/forge"))
ANVIL = os.environ.get("ANVIL", str(Path.home() / ".foundry/bin/anvil"))
RPC_PORT = int(CFG["anvil"]["rpc_port"])
RPC = f"http://127.0.0.1:{RPC_PORT}"
FROM = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
Z32 = "0x" + "00" * 32
PERFORMATIVE = {
    "Request": 0, "Agree": 1, "Refuse": 2, "Failure": 3, "Inform": 4,
    "Cfp": 7, "Propose": 8, "AcceptProposal": 9,
}
PROTO_REQ = 1
PROTO_CN = 2
MSG = "(uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes)"
PRAGUE_PROBE = "0x000000000000000000000000000000000000000b"  # BLS12_G1ADD, Prague+


def abort(msg: str) -> None:
    print("REVISION ABORT:", msg, file=sys.stderr)
    sys.exit(2)


def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout or "fail")[-1500:])
    return p


def sha256_file(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def gas_used(rec: dict) -> int:
    g = rec.get("gasUsed")
    if isinstance(g, str):
        return int(g, 16) if g.startswith("0x") else int(g)
    return int(g)


def calldata_len(h: str) -> int:
    s = h[2:] if h.startswith("0x") else h
    return len(s) // 2


# ---------------------------------------------------------------------------------------------
# Historical evidence guard
# ---------------------------------------------------------------------------------------------

def check_historical_untouched() -> dict:
    p = subprocess.run(
        ["sha256sum", "--check", "--strict", "--quiet", "PUBLIC_MANIFEST.sha256"],
        cwd=str(ROOT), capture_output=True, text=True,
    )
    if p.returncode != 0:
        abort("PUBLIC_MANIFEST.sha256 no longer verifies (historical artifact modified):\n" + p.stdout[-1500:])
    out = {"PUBLIC_MANIFEST.sha256": sha256_file(ROOT / "PUBLIC_MANIFEST.sha256")}
    for rel, expect in CFG["historical"]["E0"]["raw"].items():
        got = sha256_file(ROOT / rel)
        if got != expect:
            abort(f"historical raw modified: {rel} {got} != {expect}")
        out[rel] = got
    return out


# ---------------------------------------------------------------------------------------------
# Toolchain and Core
# ---------------------------------------------------------------------------------------------

def _version(binary: str) -> dict:
    text = run([binary, "--version"]).stdout
    ver = commit = None
    for line in text.splitlines():
        if "Version:" in line:
            ver = line.split("Version:")[1].strip()
        if "Commit SHA:" in line:
            commit = line.split("Commit SHA:")[1].strip()
    return {"version": ver, "commit": commit, "raw": text.strip()}


def toolchain() -> dict:
    tc = CFG["toolchain"]
    info = {name: _version(b) for name, b in (("forge", FORGE), ("cast", CAST), ("anvil", ANVIL))}
    for name in ("forge", "cast", "anvil"):
        if info[name]["version"] != tc[name] or info[name]["commit"] != tc["foundry_commit"]:
            abort(f"{name} {info[name]['version']} {info[name]['commit']} != frozen toolchain")
    candidates = [Path(d) / tc["solc"] / f"solc-{tc['solc']}"
                  for d in (Path.home() / ".local/share/svm", Path.home() / ".svm")]
    solc = next((c for c in candidates if c.is_file()), None)
    if solc is None:
        abort(f"solc {tc['solc']} not installed (looked in {[str(c) for c in candidates]})")
    info["solc"] = {"version": tc["solc"], "path": str(solc), "raw": run([str(solc), "--version"]).stdout.strip(),
                    "sha256": sha256_file(solc)}
    info["python"] = platform.python_version()
    info["platform"] = platform.platform()
    return info


def core_dir(sha: str) -> Path:
    d = CORES / sha
    if not d.is_dir():
        src = Path(os.environ.get("BLADE_REPO", ROOT.parent / "blade")).resolve()
        CORES.mkdir(parents=True, exist_ok=True)
        run(["git", "clone", "-q", "--no-checkout", str(src), str(d)])
        run(["git", "checkout", "-q", "--detach", sha], cwd=str(d))
    head = run(["git", "rev-parse", "HEAD"], cwd=str(d)).stdout.strip()
    if head != sha:
        abort(f"Core clone {d} at {head} != {sha}")
    if run(["git", "status", "--short"], cwd=str(d)).stdout.strip():
        abort(f"Core clone {d} has local modifications")
    return d


def patched_core(camp: dict, core: Path, dest: Path) -> Path:
    """Overlay = the base Core's src/core with the study's patch files substituted.

    Each patched file must still match the recorded base hash, so a patch cannot silently apply to a
    different Core revision.
    """
    patch = ROOT / camp["core_patch"]
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(core / "src" / "core", dest)
    for f in sorted(patch.glob("*.sol")):
        want = camp["core_patch_base_sha256"].get(f.name)
        if want is None or sha256_file(core / "src" / "core" / f.name) != want:
            abort(f"patch {f.name} does not match the recorded base file of {camp['core_sha']}")
        shutil.copyfile(f, dest / f.name)
    return dest


def core_overlay(camp: dict, core: Path, base: Path) -> Path | None:
    if camp.get("core_patch"):
        return patched_core(camp, core, base / "core-overlay")
    return (ROOT / camp["core_overlay"]).resolve() if camp.get("core_overlay") else None


def eval_git() -> dict:
    head = run(["git", "rev-parse", "HEAD"], cwd=str(ROOT)).stdout.strip()
    status = run(["git", "status", "--short"], cwd=str(ROOT)).stdout
    return {"head": head, "dirty_paths": [l[3:] for l in status.splitlines() if l.strip()]}


# ---------------------------------------------------------------------------------------------
# Isolated build project
# ---------------------------------------------------------------------------------------------

MANUAL_VARIANTS = ROOT / "revision" / "src" / "manual-variants"


def variant_layers(manual_variant) -> list[str]:
    """A manual variant is one name or a list of names applied in order (later layers win)."""
    if not manual_variant:
        return []
    return [manual_variant] if isinstance(manual_variant, str) else list(manual_variant)


def test_profile(name: str) -> dict:
    profiles = CFG["test_profiles"]
    if name not in profiles:
        abort(f"unknown test profile {name}")
    return profiles[name]


def prepare_project(dest: Path, core: Path, overlay: Path | None, manual_variant,
                    with_tests: bool = False, variant_tests: list[str] | None = None,
                    profile: dict | None = None) -> dict:
    if dest.exists():
        shutil.rmtree(dest)
    app = dest / "comparison" / "src"
    shutil.copytree(ROOT / "comparison" / "src" / "blade-app", app / "blade-app")
    shutil.copytree(ROOT / "comparison" / "src" / "manual", app / "manual")
    for layer in variant_layers(manual_variant):
        vdir = MANUAL_VARIANTS / layer
        if not vdir.is_dir():
            abort(f"manual variant {layer} missing")
        for f in sorted(vdir.glob("*.sol")):
            if not (app / "manual" / f.name).is_file():
                abort(f"manual variant file {f.name} does not replace a baseline file")
            shutil.copyfile(f, app / "manual" / f.name)
    if with_tests:
        tdir = dest / "comparison" / "test"
        shutil.copytree(ROOT / "revision" / "test", tdir / "revision")
        if manual_variant:
            for name in variant_tests if variant_tests is not None else variant_layers(manual_variant):
                vt = ROOT / "revision" / "test-variants" / name
                if vt.is_dir():
                    shutil.copytree(vt, tdir / "revision" / f"variant_{name}")
        replaced = (profile or {}).get("replace", {})
        (tdir / "original").mkdir(parents=True)
        for f in sorted((ROOT / "comparison" / "test").glob("*.sol")):
            if f.name in replaced:
                if not (ROOT / "revision" / "test" / replaced[f.name]["by"]).is_file():
                    abort(f"profile replaces {f.name} by missing {replaced[f.name]['by']}")
                inapp = tdir / "inapplicable"
                inapp.mkdir(parents=True, exist_ok=True)
                note = (
                    f"// NOT COMPILED on profile {(profile or {}).get('description', '')}\n"
                    f"// Replaced by revision/test/{replaced[f.name]['by']}.\n"
                    f"// Reason: {replaced[f.name]['reason']}\n"
                    "// Historical file preserved byte-for-byte below (comparison/test/ is untouched).\n"
                )
                (inapp / (f.name + ".historical")).write_text(note + f.read_text())
                continue
            (tdir / "original" / f.name).write_text(f.read_text().replace('"../src/', '"../../src/'))
    allow = [str(core)] + ([str(overlay)] if overlay else [])
    (dest / "foundry.toml").write_text(
        "[profile.default]\n"
        'src = "comparison/src"\nout = "out"\ntest = "comparison/test"\nlibs = []\n'
        f'solc = "{CFG["toolchain"]["solc"]}"\n'
        f'optimizer = {str(CFG["compiler"]["optimizer"]).lower()}\n'
        f'optimizer_runs = {CFG["compiler"]["optimizer_runs"]}\n'
        f'via_ir = {str(CFG["compiler"]["via_ir"]).lower()}\n'
        f'evm_version = "{CFG["compiler"]["evm_version"]}"\n'
        'fs_permissions = [{ access = "read-write", path = "./outputs" }]\n'
        f"allow_paths = {json.dumps(allow)}\n"
    )
    remaps = [f"forge-std/={core}/lib/forge-std/src/", f"blade/={core}/src/", "app/=comparison/src/"]
    if overlay:
        remaps.insert(0, f"blade/core/={overlay}/")
    (dest / "remappings.txt").write_text("\n".join(remaps) + "\n")
    (dest / "outputs" / "storage").mkdir(parents=True, exist_ok=True)
    sources = {}
    for f in sorted(app.rglob("*.sol")):
        sources[str(f.relative_to(dest))] = sha256_file(f)
    core_src = overlay if overlay else core / "src" / "core"
    for f in sorted(core_src.glob("*.sol")):
        sources[f"blade/core/{f.name}"] = sha256_file(f)
    return sources


def forge_config_check(proj: Path) -> dict:
    cfg = json.loads(run([FORGE, "config", "--json"], cwd=str(proj)).stdout)
    want = CFG["compiler"]
    if cfg.get("solc") != CFG["toolchain"]["solc"] or cfg.get("optimizer") is not want["optimizer"] \
            or int(cfg.get("optimizer_runs")) != want["optimizer_runs"] or cfg.get("via_ir") is not want["via_ir"] \
            or cfg.get("evm_version") != want["evm_version"]:
        abort(f"forge config mismatch in {proj}")
    return {k: cfg.get(k) for k in ("solc", "optimizer", "optimizer_runs", "via_ir", "evm_version")}


def build(proj: Path) -> None:
    run([FORGE, "build", "--force"], cwd=str(proj))


# ---------------------------------------------------------------------------------------------
# Anvil
# ---------------------------------------------------------------------------------------------

class Anvil:
    def __init__(self, logp: Path, hardfork: str | None, expected: str):
        self.logp, self.hardfork, self.expected = logp, hardfork, expected
        self.proc = None
        self.info = None

    def __enter__(self):
        self.logp.parent.mkdir(parents=True, exist_ok=True)
        log = open(self.logp, "w")
        a = CFG["anvil"]
        cmd = [ANVIL, "--port", str(RPC_PORT), "--chain-id", str(a["chain_id"]),
               "--timestamp", str(a["genesis_timestamp"]), "--gas-limit", str(a["gas_limit"]),
               "--block-base-fee-per-gas", str(a["base_fee_wei"]), "--order", "fifo", "--silent"]
        if self.hardfork:
            cmd += ["--hardfork", self.hardfork]
        self.proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
        for _ in range(100):
            p = subprocess.run([CAST, "block-number", "--rpc-url", RPC], capture_output=True, text=True)
            if p.returncode == 0:
                break
            time.sleep(0.1)
        else:
            self.proc.kill()
            abort("anvil did not start")
        self.info = effective_environment()
        if self.info["hardfork"] != self.expected:
            self.__exit__()
            abort(f"effective hardfork {self.info['hardfork']} != {self.expected}")
        probe = self.info["bls_probe"]
        if (self.expected == "Cancun") == probe["present"] or \
                (probe["empty_input"] == "error") != probe["present"]:
            self.__exit__()
            abort(f"precompile probe inconsistent with {self.expected}: {self.info}")
        if self.info["chain_id"] != a["chain_id"] or self.info["gas_limit"] != a["gas_limit"] \
                or self.info["base_fee_per_gas"] != a["base_fee_wei"] or self.info["timestamp"] != a["genesis_timestamp"]:
            self.__exit__()
            abort(f"anvil environment {self.info}")
        return self

    def __exit__(self, *exc):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def bls_probe() -> dict:
    """EIP-2537 BLS12-381 G1ADD (0x0b, Prague+) probe with a *valid* input: two points at infinity.

    An active precompile returns the 128-byte encoding of the point at infinity; an address without code
    (Cancun) returns empty output. Any other outcome is inconclusive and aborts the run. The empty-input
    call is kept as secondary evidence (PrecompileError when active, empty success otherwise).
    """
    def call(data: str) -> subprocess.CompletedProcess:
        return subprocess.run([CAST, "rpc", "eth_call", json.dumps({"to": PRAGUE_PROBE, "data": data}), "latest",
                               "--rpc-url", RPC], capture_output=True, text=True)
    valid = call("0x" + "00" * 256)
    if valid.returncode != 0:
        abort(f"BLS probe inconclusive (valid input rejected): {valid.stderr.strip()[-300:]}")
    out = json.loads(valid.stdout)
    n = (len(out) - 2) // 2
    if out == "0x":
        present = False
    elif n == 128 and int(out, 16) == 0:
        present = True
    else:
        abort(f"BLS probe inconclusive: {n}-byte output {out[:40]}")
    empty = call("0x")
    return {"present": present, "valid_input_output_bytes": n,
            "empty_input": "error" if empty.returncode != 0 else f"ok:{json.loads(empty.stdout)}"}


def effective_environment() -> dict:
    node = json.loads(run([CAST, "rpc", "anvil_nodeInfo", "--rpc-url", RPC]).stdout)
    blk = json.loads(run([CAST, "block", "latest", "--rpc-url", RPC, "--json"]).stdout)
    probe = bls_probe()
    as_int = lambda v: int(v, 16) if isinstance(v, str) else int(v)  # noqa: E731
    return {
        "hardfork": node.get("hardFork"),
        "prague_precompile_present": probe["present"],
        "bls_probe": probe,
        "chain_id": int(run([CAST, "chain-id", "--rpc-url", RPC]).stdout.strip()),
        "gas_limit": as_int(blk["gasLimit"]),
        "base_fee_per_gas": as_int(blk["baseFeePerGas"]),
        "timestamp": as_int(blk["timestamp"]),
    }


# ---------------------------------------------------------------------------------------------
# Transactions
# ---------------------------------------------------------------------------------------------

def receipt(tx: str) -> dict:
    return json.loads(run([CAST, "receipt", tx, "--rpc-url", RPC, "--json"]).stdout)


def send(to: str, sig: str, *args, inbound_bytes: int | None = None) -> dict:
    data = run([CAST, "calldata", sig, *args]).stdout.strip()
    tx = {"from": FROM, "to": to, "gas": hex(20_000_000), "gasPrice": hex(1_000_000_000), "data": data}
    txh = run([CAST, "rpc", "eth_sendTransaction", json.dumps(tx), "--rpc-url", RPC]).stdout.strip().strip('"')
    rec = receipt(txh)
    rec["_input"] = data
    rec["_inbound_content_bytes"] = inbound_bytes
    if rec.get("status") in (0, "0", "0x0"):
        rec["_reverted"] = True
    return rec


SOL_OF = {
    "BladeRequester": "BladeRequest.sol", "BladeParticipant": "BladeRequest.sol",
    "BladeManager": "BladeContractNet.sol", "BladeCnParticipant": "BladeContractNet.sol",
    "ManualInitiator": "ManualRequest.sol", "ManualParticipant": "ManualRequest.sol",
    "ManualManager": "ManualContractNet.sol", "ManualCnParticipant": "ManualContractNet.sol",
}


def create(proj: Path, name: str) -> dict:
    art = json.loads((proj / "out" / SOL_OF[name] / f"{name}.json").read_text())
    bytecode = art["bytecode"]["object"]
    bytecode = bytecode if bytecode.startswith("0x") else "0x" + bytecode
    tx = {"from": FROM, "gas": hex(8_000_000), "gasPrice": hex(1_000_000_000), "data": bytecode}
    txh = run([CAST, "rpc", "eth_sendTransaction", json.dumps(tx), "--rpc-url", RPC]).stdout.strip().strip('"')
    rec = receipt(txh)
    rec["_input"] = bytecode
    rec["_deployed"] = rec.get("contractAddress")
    rec["_runtime_bytes"] = calldata_len(art["deployedBytecode"]["object"])
    rec["_initcode_bytes"] = calldata_len(bytecode)
    rec["_inbound_content_bytes"] = None
    if not rec["_deployed"] or rec.get("status") in (0, "0", "0x0"):
        raise RuntimeError(f"deployment failed {name}")
    return rec


def msg(perf: str, proto: int, cid: str, content_hex: str, reply_by: int = 0, reply_with: str = Z32) -> str:
    c = content_hex if content_hex.startswith("0x") else "0x" + content_hex
    return f"({PERFORMATIVE[perf]},{proto},{cid},{reply_with},{Z32},{reply_by},{Z32},{c})"


def request_token(agent: str, cid: str) -> str:
    """Session token kept by a Request agent; Core fbf266f5 has no token field (returns zero)."""
    raw = run([CAST, "call", agent, "requestStatus(bytes32)", cid, "--rpc-url", RPC]).stdout.strip()
    words = [raw[2:][i:i + 64] for i in range(0, len(raw) - 2, 64)]
    if len(words) == 4:
        return Z32
    if len(words) == 5:
        return "0x" + words[4]
    raise RuntimeError(f"unexpected requestStatus layout ({len(words)} words)")


def set_next_ts(ts: int) -> None:
    run([CAST, "rpc", "evm_setNextBlockTimestamp", str(ts), "--rpc-url", RPC])


def warp(ts: int) -> None:
    set_next_ts(ts)
    run([CAST, "rpc", "evm_mine", "--rpc-url", RPC])


# ---------------------------------------------------------------------------------------------
# Workloads
# ---------------------------------------------------------------------------------------------

class Ctx:
    def __init__(self, camp_id: str, camp: dict, proj: Path, phase: str, meta_sha: str):
        self.camp_id, self.camp, self.proj, self.phase, self.meta_sha = camp_id, camp, proj, phase, meta_sha

    @property
    def minimal(self) -> bool:
        return self.camp["payload_encoding"] == "minimal"

    def inbound(self, p: str) -> tuple[str, int]:
        """Content of a reconstructed inbound message and its length."""
        if self.minimal:
            return "0x", 0
        return p, calldata_len(p)


def request_txs(ctx: Ctx, path: str, n: int, cid: str, impl: str, k: int = 1, cid_of=None) -> list:
    p, _ = payload_hex(n)
    pr = ctx.proj
    if impl == "blade":
        dI, dP = create(pr, "BladeRequester"), create(pr, "BladeParticipant")
    else:
        dI, dP = create(pr, "ManualInitiator"), create(pr, "ManualParticipant")
    I, P = dI["_deployed"], dP["_deployed"]
    txs = [("deploy_initiator", dI, True), ("deploy_participant", dP, True)]
    txs.append(("startRequest", send(I, "startRequest(address,bytes32,bytes)", P, cid, p), False))
    blade = impl == "blade"
    if blade:
        content, ib = ctx.inbound(p)
        req = msg("Request", PROTO_REQ, cid, content, 0, request_token(P, cid))

    def agree(label, rq, c):
        if blade:
            return (label, send(P, f"agree({MSG},address)", rq, I, inbound_bytes=ib), False)
        return (label, send(P, "agree(bytes32)", c), False)

    def reply(label, act, rq, c):
        if blade:
            return (label, send(P, f"{act}({MSG},address,bytes)", rq, I, p, inbound_bytes=ib), False)
        return (label, send(P, f"{act}(bytes32,bytes)", c, p), False)

    if path == "R1":
        txs.append(reply("refuse", "refuse", req if blade else None, cid))
    elif path == "R2":
        txs.append(reply("inform", "inform", req if blade else None, cid))
    elif path == "R3":
        txs.append(agree("agree", req if blade else None, cid))
        txs.append(reply("inform", "inform", req if blade else None, cid))
    elif path == "R4":
        txs.append(agree("agree", req if blade else None, cid))
        txs.append(reply("failure", "failure", req if blade else None, cid))
    elif path == "active":
        txs.append(agree("agree", req if blade else None, cid))
        for i in range(1, k):
            cid_i = cid_of(i)
            txs.append((f"startRequest_{i}", send(I, "startRequest(address,bytes32,bytes)", P, cid_i, p), False))
            rq = msg("Request", PROTO_REQ, cid_i, content, 0, request_token(P, cid_i)) if blade else None
            txs.append(agree(f"agree_{i}", rq, cid_i))
    else:
        abort(f"unknown request path {path}")
    return txs


def cn_txs(ctx: Ctx, scenario: str, n_part: int, n: int, cid: str, impl: str) -> list:
    """A: all propose, all accepted. B: first ceil(N/2) propose, rest refuse. fail: A with failure.
    HALF: all propose, first N//2 accepted, rest rejected. REJ: all propose, all rejected."""
    p, _ = payload_hex(n)
    pr = ctx.proj
    by = DEADLINE["reply_by"]
    blade = impl == "blade"
    dM = create(pr, "BladeManager" if blade else "ManualManager")
    dPs = [create(pr, "BladeCnParticipant" if blade else "ManualCnParticipant") for _ in range(n_part)]
    txs = [("deploy_manager", dM, True)] + [(f"deploy_participant_{i}", d, True) for i, d in enumerate(dPs)]
    M = dM["_deployed"]
    parts = [d["_deployed"] for d in dPs]
    set_next_ts(DEADLINE["chain_ref_ts"])
    cfp = send(M, "cfp(address[],bytes32,uint64,bytes)", "[" + ",".join(parts) + "]", cid, str(by), p)
    txs.append(("cfp", cfp, False))
    blk = json.loads(run([CAST, "block", cfp["blockNumber"], "--rpc-url", RPC, "--json"]).stdout)
    ts = int(blk["timestamp"], 16) if isinstance(blk["timestamp"], str) else int(blk["timestamp"])
    if ts != DEADLINE["chain_ref_ts"]:
        abort(f"CFP timestamp {ts}")
    content, ib = ctx.inbound(p)
    cfp_msg = msg("Cfp", PROTO_CN, cid, content, by)
    k_prop = (n_part + 1) // 2 if scenario == "B" else n_part
    for i, P in enumerate(parts):
        if scenario == "B" and i >= k_prop:
            if blade:
                txs.append((f"refuse_{i}", send(P, f"refuse({MSG},address)", cfp_msg, M, inbound_bytes=ib), False))
            else:
                txs.append((f"refuse_{i}", send(P, "refuse(bytes32)", cid), False))
        elif blade:
            txs.append((f"propose_{i}", send(P, f"propose({MSG},address,bytes)", cfp_msg, M, p, inbound_bytes=ib), False))
        else:
            txs.append((f"propose_{i}", send(P, "propose(bytes32,bytes)", cid, p), False))
    warp(by + 1)
    if scenario == "B":
        acc, rej = parts[:k_prop], []
    elif scenario == "HALF":
        acc, rej = parts[: n_part // 2], parts[n_part // 2:]
    elif scenario == "REJ":
        acc, rej = [], parts
    else:
        acc, rej = parts, []
    arr = lambda xs: "[" + ",".join(xs) + "]"  # noqa: E731
    txs.append(("evaluate", send(M, "evaluate(bytes32,address[],address[],address[])", cid, arr(acc), arr(rej), "[]"), False))
    acc_msg = msg("AcceptProposal", PROTO_CN, cid, "0x", DEADLINE["accept_reply_by"])
    for i, P in enumerate(acc):
        act, label = ("failure", "failure") if scenario == "fail" else ("inform", f"inform_{i}")
        if blade:
            txs.append((label, send(P, f"{act}({MSG},address,bytes)", acc_msg, M, p, inbound_bytes=0), False))
        else:
            txs.append((label, send(P, f"{act}(bytes32,bytes)", cid, p), False))
    return txs


# ---------------------------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------------------------

def base_row(ctx: Ctx, cond: dict, impl: str, **extra) -> dict:
    n = cond["payload_bytes"]
    hx, _ = payload_hex(n)
    cn = cond.get("protocol") == "contract-net"
    c = ctx.camp
    r = {
        "experiment_spec_id": CFG["config_id"],
        "campaign_id": ctx.camp_id,
        "campaign_meta_sha256": ctx.meta_sha,
        "schema_version": 2,
        "analysis_version": 1,
        "phase": ctx.phase,
        "core_sha": c["core_sha"],
        "core_overlay": c.get("core_overlay"),
        "manual_variant": c.get("manual_variant"),
        "freeze_manifest_sha256": ctx.meta_sha,
        "baseline_version": "+".join(["eval-v2"] + variant_layers(c.get("manual_variant"))),
        "implementation": impl,
        "condition_id": cond["condition_id"],
        "experiment_id": f"{ctx.camp_id}/{cond['condition_id']}/{impl}",
        "protocol": cond["protocol"],
        "scenario": cond.get("scenario"),
        "path": cond["path"],
        "payload_bytes": n,
        "payload_pattern": "repeat_0xab",
        "payload_sha256": PAYLOAD_SHA[n],
        "payload_encoding": c["payload_encoding"],
        "participant_count": cond["participant_count"],
        "active_conversations": cond.get("active_conversations", 1),
        "solc_version": CFG["toolchain"]["solc"],
        "forge_version": CFG["toolchain"]["forge"],
        "forge_commit": CFG["toolchain"]["foundry_commit"],
        "optimizer": CFG["compiler"]["optimizer"],
        "optimizer_runs": CFG["compiler"]["optimizer_runs"],
        "via_ir": CFG["compiler"]["via_ir"],
        "evm_version": CFG["compiler"]["evm_version"],
        "hardfork_requested": c["hardfork"],
        "hardfork_effective": c["expected_node_hardfork"],
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
        "inbound_content_bytes": None,
        "status": "ok",
        "notes": "secondary" if str(cond["condition_id"]).startswith("SEC-") else None,
        "record_kind": None,
        "payload_hex": hx,
    }
    r.update(extra)
    return r


def rows_of(ctx: Ctx, cond: dict, impl: str, txs: list, error: str | None) -> list[dict]:
    rows = []
    default_note = "secondary" if str(cond["condition_id"]).startswith("SEC-") else None
    for i, (name, rec, dep) in enumerate(txs):
        rows.append(base_row(
            ctx, cond, impl,
            interaction_step=name, transaction_index=i,
            transaction_gas_used=gas_used(rec),
            deployment_gas=gas_used(rec) if dep else None,
            runtime_bytecode_bytes=rec.get("_runtime_bytes") if dep else None,
            initcode_bytes=rec.get("_initcode_bytes") if dep else None,
            top_level_calldata_bytes=calldata_len(rec["_input"]),
            inbound_content_bytes=rec.get("_inbound_content_bytes"),
            record_kind="deployment" if dep else "interaction_tx",
            status="ok" if error is None else "resource_failed",
            notes=str(error)[-400:] if error else default_note,
        ))
    inter = [r for r in rows if r["record_kind"] == "interaction_tx"]
    total = sum(int(r["transaction_gas_used"]) for r in inter)
    for r in rows:
        r["complete_interaction_gas"] = total if r["record_kind"] == "interaction_tx" else None
    return rows


def measure(ctx: Ctx, cond: dict, impl: str, cid_label: str) -> list[dict]:
    cid = run([CAST, "keccak", cid_label]).stdout.strip()
    txs: list = []
    err = None
    try:
        if cond["protocol"] == "request":
            cid_of = lambda i: run([CAST, "keccak", f"{cid_label}/{i}"]).stdout.strip()  # noqa: E731
            txs = request_txs(ctx, cond["path"], cond["payload_bytes"], cid, impl,
                              cond.get("active_conversations", 1), cid_of)
        else:
            txs = cn_txs(ctx, cond.get("scenario") or "A", cond["participant_count"], cond["payload_bytes"], cid, impl)
        bad = [n for n, r, _ in txs if r.get("_reverted")]
        if bad:
            err = "reverted " + ",".join(bad)
    except RuntimeError as e:
        err = str(e)
    if err:
        print(f"    !! {cond['condition_id']}/{impl}: {err[-300:]}", flush=True)
    return rows_of(ctx, cond, impl, txs, err)


# ---------------------------------------------------------------------------------------------
# Campaign modes
# ---------------------------------------------------------------------------------------------

def conditions_for(matrix: str) -> list[dict]:
    if matrix == "primary":
        return list(PRIMARY["conditions"])
    if matrix == "secondary":
        return [{**c, "experiment_class": "secondary"} for c in SECONDARY["conditions"]]
    return [condition_by_id(c) for c in CFG["matrices"][matrix]]


def setup_campaign(camp_id: str, tests: bool = False, profile_name: str | None = None
                   ) -> tuple[dict, Path, dict, Path]:
    if camp_id not in CFG["campaigns"]:
        abort(f"unknown campaign {camp_id}")
    camp = CFG["campaigns"][camp_id]
    profile = test_profile(profile_name or camp["test_profile"]) if tests else None
    hist = check_historical_untouched()
    tc = toolchain()
    core = core_dir(camp["core_sha"])
    base = OUT / camp_id
    base.mkdir(parents=True, exist_ok=True)
    overlay = core_overlay(camp, core, base)
    proj = base / ("test-project" if tests else "project")
    sources = prepare_project(proj, core, overlay, camp.get("manual_variant"), with_tests=tests,
                              variant_tests=camp.get("variant_tests"), profile=profile)
    compiler = forge_config_check(proj)
    build(proj)
    meta = {
        "campaign_id": camp_id,
        "config_id": CFG["config_id"],
        "config_sha256": sha256_file(CFG_PATH),
        "runner_sha256": sha256_file(Path(__file__)),
        "campaign": camp,
        "core_path": str(core),
        "evaluation_git": eval_git(),
        "historical_hashes_verified": hist,
        "toolchain": tc,
        "compiler": compiler,
        "anvil_flags": {**CFG["anvil"], "hardfork": camp["hardfork"]},
        "sources_sha256": sources,
    }
    return camp, proj, meta, base


def write_meta(base: Path, meta: dict, name: str = "meta.json") -> str:
    p = base / name
    p.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")
    return sha256_file(p)


def pair_validate(rows: list[dict], phase: str) -> list[str]:
    errs = validate_rows(rows, expect_phase=phase) + gas_sum_errors(rows) + pairing_errors(rows)
    for r in rows:
        if r["record_kind"] == "interaction_tx" and r["implementation"] == "blade" \
                and r["inbound_content_bytes"] not in (None, 0) and r["payload_encoding"] == "minimal":
            errs.append(f"redundant inbound content in {r['experiment_id']} {r['interaction_step']}")
    return errs


def mode_campaign(camp_id: str, matrices: list[str], phase: str) -> None:
    camp, proj, meta, base = setup_campaign(camp_id)
    meta["matrices"] = matrices
    meta["phase"] = phase
    envs = {}
    meta_sha = write_meta(base, meta)
    rawdir = base / "raw"
    rawdir.mkdir(exist_ok=True)
    for matrix in matrices:
        rawp = rawdir / f"{matrix}.jsonl"
        if rawp.exists():
            abort(f"{rawp} exists; remove it explicitly before re-running")
        ctx = Ctx(camp_id, camp, proj, phase, meta_sha)
        all_rows = []
        for cond in conditions_for(matrix):
            print(f"  {camp_id} {matrix} {cond['condition_id']}", flush=True)
            pair = []
            for impl in ("blade", "manual"):
                with Anvil(base / "logs" / f"{cond['condition_id']}_{impl}.log", camp["hardfork"],
                           camp["expected_node_hardfork"]) as node:
                    envs[f"{cond['condition_id']}/{impl}"] = node.info
                    # Same conversationId derivation as the submitted campaign (phase "f3").
                    pair += measure(ctx, cond, impl, f"f3/{cond['condition_id']}/{impl}")
            errs = pair_validate(pair, phase)
            if errs:
                abort("pair validation:\n" + "\n".join(errs[:20]))
            with rawp.open("a") as fh:
                for r in pair:
                    fh.write(json.dumps(r, separators=(",", ":")) + "\n")
            all_rows += pair
        if matrix in ("primary", "secondary"):
            errs = [e for e in completeness_errors(all_rows, matrix=matrix)]
            if errs:
                abort(f"{matrix} completeness:\n" + "\n".join(errs[:30]))
        failed = sorted({r["experiment_id"] for r in all_rows if r["status"] != "ok"})
        print(f"  {camp_id} {matrix}: {len(all_rows)} rows, failed cells: {failed or 'none'}", flush=True)
    write_meta(base, {"effective_environment_per_cell": envs}, "environment.json")
    check_historical_untouched()
    print("CAMPAIGN COMPLETE", camp_id, "meta", meta_sha)


def mode_preflight(camp_id: str) -> None:
    camp, proj, meta, base = setup_campaign(camp_id)
    with Anvil(base / "logs" / "preflight.log", camp["hardfork"], camp["expected_node_hardfork"]) as node:
        meta["preflight_environment"] = node.info
        # Smoke: one deployment of each contract under the effective environment.
        for name in SOL_OF:
            create(proj, name)
    write_meta(base, meta, "preflight.json")
    print("PREFLIGHT PASS", camp_id, json.dumps(meta["preflight_environment"]))


def mode_tests(camp_id: str, match: list[str], profile_name: str | None = None) -> None:
    camp, proj, meta, base = setup_campaign(camp_id, tests=True, profile_name=profile_name)
    pname = profile_name or camp["test_profile"]
    profile = test_profile(pname)
    args = [FORGE, "test", "-vv"]
    for m in match:
        args += ["--match-path", m]
    env = {**os.environ, **profile.get("env", {})}
    p = subprocess.run(args, cwd=str(proj), capture_output=True, text=True, env=env)
    suffix = '_'.join(x.replace('/', '-').replace('*', 'X') for x in match) or 'all'
    if profile_name and profile_name != camp["test_profile"]:
        suffix += f"_{pname}"
    logp = base / f"tests_{suffix}.log"
    logp.write_text(p.stdout + p.stderr)
    ran = sorted(str(f.relative_to(proj)) for f in (proj / "comparison" / "test").rglob("*.t.sol"))
    (base / f"test_profile_{suffix}.json").write_text(json.dumps({
        "campaign_id": camp_id, "profile": pname, "definition": profile, "env": profile.get("env", {}),
        "test_files": ran, "core_sha": camp["core_sha"], "config_sha256": sha256_file(CFG_PATH),
        "runner_sha256": sha256_file(Path(__file__)), "sources_sha256": meta["sources_sha256"],
        "forge_exit": p.returncode,
        "summary": [l for l in p.stdout.splitlines() if l.startswith("Ran ") and "test suites" in l],
    }, indent=2) + "\n")
    for f in (proj / "outputs" / "storage").glob("*.json"):
        dst = base / "storage"
        dst.mkdir(exist_ok=True)
        shutil.copyfile(f, dst / f.name)
    tail = [l for l in p.stdout.splitlines() if "Suite result" in l or "tests passed" in l or "[FAIL" in l]
    print("\n".join(tail))
    print("TESTS EXIT", p.returncode, "log", logp)
    if p.returncode != 0:
        sys.exit(1)


def mode_core_tests(camp_id: str) -> None:
    """Run the Core repository's own suite (plus revision/test-core) against the campaign's Core tree.

    The Core clone is copied, its src/core replaced by the campaign overlay (if any), and forge runs
    with the Core's foundry.toml and a fixed fuzz seed so official and variant runs are comparable.
    """
    camp = CFG["campaigns"][camp_id]
    check_historical_untouched()
    tc = toolchain()
    core = core_dir(camp["core_sha"])
    base = OUT / camp_id
    base.mkdir(parents=True, exist_ok=True)
    overlay = core_overlay(camp, core, base)
    proj = base / "core-tests"
    if proj.exists():
        shutil.rmtree(proj)
    shutil.copytree(core, proj, ignore=shutil.ignore_patterns(".git", "out", "cache", "broadcast"))
    if overlay:
        shutil.rmtree(proj / "src" / "core")
        shutil.copytree(overlay, proj / "src" / "core")
    shutil.copytree(ROOT / "revision" / "test-core", proj / "test" / "revision")
    seed = CFG["core_tests"]["fuzz_seed"]
    p = subprocess.run(
        [FORGE, "test", "--fuzz-seed", seed, "--no-match-path", "lib/", "-vv"],
        cwd=str(proj), capture_output=True, text=True,
    )
    (base / "core_tests.log").write_text(p.stdout + "\n" + p.stderr)
    results = {}
    for line in (p.stdout + p.stderr).splitlines():
        if line.startswith("[PASS]"):
            results[line.split("(", 1)[0][len("[PASS] "):].strip()] = "PASS"
        elif line.startswith("[FAIL"):
            name = line.split("]", 1)[-1]
            name = name.split("(", 1)[0].strip()
            results[name] = "FAIL"
        elif line.startswith("[SKIP"):
            name = line.split("]", 1)[-1].split("(", 1)[0].strip()
            results[name] = "SKIP"
    if not results and p.returncode == 0:
        abort(f"core tests produced no [PASS]/[FAIL] lines; see {base / 'core_tests.log'}")
    summary = {"campaign_id": camp_id, "core_sha": camp["core_sha"], "core_patch": camp.get("core_patch"),
               "fuzz_seed": seed, "toolchain_forge": tc["forge"]["version"],
               "core_sha256": {f.name: sha256_file(f) for f in sorted((proj / "src" / "core").glob("*.sol"))},
               "counts": {s: sum(1 for v in results.values() if v == s) for s in sorted(set(results.values()))},
               "results": dict(sorted(results.items()))}
    (base / "core_tests_summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("CORE TESTS", camp_id, summary["counts"], "exit", p.returncode)
    if p.returncode != 0:
        sys.exit(1)


# ---------------------------------------------------------------------------------------------
# Ablation
# ---------------------------------------------------------------------------------------------

def ablation_tree(variant: str, base_core: Path, rebase: str | None, dest: Path) -> Path:
    src = ROOT / "ablation" / "variants" / variant
    if variant == "A0" and not rebase:
        return src
    dest.mkdir(parents=True, exist_ok=True)
    for f in src.glob("*.sol"):
        shutil.copyfile(f, dest / f.name)
    if rebase:
        a0 = ROOT / "ablation" / "variants" / "A0" / rebase
        if sha256_file(src / rebase) != sha256_file(a0):
            abort(f"{variant} modifies {rebase}; cannot rebase")
        shutil.copyfile(base_core / "src" / "core" / rebase, dest / rebase)
    if variant == "A0":
        for f in dest.glob("*.sol"):
            if sha256_file(f) != sha256_file(base_core / "src" / "core" / f.name):
                abort(f"rebased A0 differs from Core at {f.name}")
    return dest


def ablation_cell_cond(kind, path, nbytes, n) -> tuple[str, dict, str]:
    if kind == "REQ":
        cid = f"REQ-{path}-P{nbytes}"
        cond = {"condition_id": cid, "protocol": "request", "path": path, "payload_bytes": nbytes,
                "participant_count": 1, "active_conversations": 1, "scenario": None}
        return cid, cond, f"ablation/{path}/{nbytes}"
    cid = f"CN-{path}-N{n}-P{nbytes}"
    cond = {"condition_id": cid, "protocol": "contract-net", "path": path, "payload_bytes": nbytes,
            "participant_count": n, "active_conversations": 1, "scenario": path}
    return cid, cond, f"ablation/cn/{path}/{n}/{nbytes}"


def mode_ablation(abl_id: str) -> None:
    acfg = CFG["ablation"]
    if abl_id not in acfg["campaigns"]:
        abort(f"unknown ablation campaign {abl_id}")
    spec = acfg["campaigns"][abl_id]
    camp = dict(CFG["campaigns"][spec["base"]])
    camp["manual_variant"] = None
    hist = check_historical_untouched()
    tc = toolchain()
    core = core_dir(camp["core_sha"])
    base = OUT / abl_id
    base.mkdir(parents=True, exist_ok=True)
    cells = dict(acfg["cells"])
    if abl_id == "ABL-E0R":
        cells.update(acfg["historical_cells"])
    needed = {v: {tuple(c) for c in cells.get(v, [])} for v in acfg["variants"]}
    needed["A0"] = set().union(*needed.values())
    meta = {"ablation_id": abl_id, "base_campaign": spec["base"], "campaign": camp,
            "config_sha256": sha256_file(CFG_PATH), "runner_sha256": sha256_file(Path(__file__)),
            "evaluation_git": eval_git(), "historical_hashes_verified": hist, "toolchain": tc,
            "variants": {}}
    results = {}
    for v in acfg["variants"]:
        tree = ablation_tree(v, core, spec["variant_rebase"], base / "trees" / v)
        proj = base / "projects" / v
        sources = prepare_project(proj, core, tree, None)
        compiler = forge_config_check(proj)
        build(proj)
        meta["variants"][v] = {"tree": str(tree), "sources_sha256": sources, "compiler": compiler}
        meta_sha = hashlib.sha256(json.dumps(meta["variants"][v], sort_keys=True).encode()).hexdigest()
        ctx = Ctx(abl_id, camp, proj, "ablation", meta_sha)
        results[v] = {}
        for cell in sorted(needed[v], key=str):
            cid, cond, label = ablation_cell_cond(*cell)
            print(f"  {abl_id} {v} {cid}", flush=True)
            with Anvil(base / "logs" / f"{v}_{cid}.log", camp["hardfork"], camp["expected_node_hardfork"]):
                rows = measure(ctx, cond, "blade", label)
            if any(r["status"] != "ok" for r in rows):
                abort(f"ablation cell failed {v} {cid}: {rows[0]['notes']}")
            inter = [r for r in rows if r["record_kind"] == "interaction_tx"]
            results[v][cid] = {
                "cell": cid,
                "complete_interaction_gas": inter[0]["complete_interaction_gas"],
                "interaction_calldata_bytes": sum(r["top_level_calldata_bytes"] for r in inter),
                "deployment_gas": {r["interaction_step"]: r["deployment_gas"] for r in rows if r["record_kind"] == "deployment"},
                "steps": [{"step": r["interaction_step"], "gas": r["transaction_gas_used"],
                           "calldata": r["top_level_calldata_bytes"], "deploy": r["record_kind"] == "deployment"}
                          for r in rows],
            }
    write_meta(base, meta)
    (base / "ablation.json").write_text(json.dumps({"results": results}, indent=2) + "\n")
    check_historical_untouched()
    print("ABLATION COMPLETE", abl_id)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--mode", required=True, choices=["preflight", "campaign", "tests", "ablation", "core-tests"])
    ap.add_argument("--campaign", required=True)
    ap.add_argument("--matrix", nargs="*", default=["primary", "secondary"])
    ap.add_argument("--phase", default="revision")
    ap.add_argument("--match-path", nargs="*", default=[])
    ap.add_argument("--profile", default=None, help="test profile override (default: campaign test_profile)")
    a = ap.parse_args()
    if a.mode == "preflight":
        mode_preflight(a.campaign)
    elif a.mode == "campaign":
        mode_campaign(a.campaign, a.matrix, a.phase)
    elif a.mode == "tests":
        mode_tests(a.campaign, a.match_path, a.profile)
    elif a.mode == "core-tests":
        mode_core_tests(a.campaign)
    else:
        mode_ablation(a.campaign)


if __name__ == "__main__":
    main()
