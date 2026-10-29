"""Shared JSON-RPC / Foundry helpers. Not a communication channel between agents."""

from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
CORE_COMMIT = "4b60b86159e89baccd24a859ca62e7039a8c8be2"

# Anvil default accounts (local only).
ACCOUNT_0 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
ACCOUNT_1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
ACCOUNT_2 = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
KEY_0 = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
KEY_1 = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
KEY_2 = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"

# Deterministic conversation identifiers (keccak256 of the UTF-8 label).
ID_A = None  # filled after first keccak
ID_B = None
ID_C = None

PAYLOAD_ACCEPT = "0x01"
PAYLOAD_REFUSE = "0x00"
PAYLOAD_WRONG = "0x03"
PAYLOAD_STALE = "0x04"
RESULT_DONE = "0xc0ffee"
REASON_BUSY = "0xb1"

PERFORMATIVE_REQUEST = 0
PERFORMATIVE_REFUSE = 2
PERFORMATIVE_INFORM = 4
PROTOCOL_FIPA_REQUEST = 1
PHASE_NONE = 0
PHASE_REQUESTED = 1

ZERO_BYTES32 = "0x" + "00" * 32
WRONG_TOKEN = "0x" + "de" * 32


def keccak(text: str) -> str:
    return run_cast("keccak", text).strip()


def init_ids() -> dict[str, str]:
    global ID_A, ID_B, ID_C
    ID_A = keccak("demo-offchain-A")
    ID_B = keccak("demo-offchain-B")
    ID_C = keccak("demo-offchain-C")
    return {"A": ID_A, "B": ID_B, "C": ID_C}


def run_cmd(args: list[str], **kwargs: Any) -> str:
    env = os.environ.copy()
    env.setdefault("FOUNDRY_DISABLE_NIGHTLY_WARNING", "1")
    completed = subprocess.run(
        args,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        **kwargs,
    )
    return completed.stdout


def run_cmd_unchecked(args: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.setdefault("FOUNDRY_DISABLE_NIGHTLY_WARNING", "1")
    return subprocess.run(
        args,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        **kwargs,
    )


def run_cast(*args: str) -> str:
    return run_cmd(["cast", *args])


def load_config(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def append_log(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    record = dict(record)
    record.setdefault("unix_ts", time.time())
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, sort_keys=True) + "\n")
        fh.flush()


def call(rpc: str, address: str, signature: str, *args: str) -> str:
    out = run_cast("call", address, signature, *args, "--rpc-url", rpc)
    return out.strip()


def send(rpc: str, key: str, address: str, signature: str, *args: str) -> dict[str, Any]:
    out = run_cmd(
        [
            "cast",
            "send",
            "--json",
            address,
            signature,
            *args,
            "--rpc-url",
            rpc,
            "--private-key",
            key,
        ]
    )
    return json.loads(out)


def send_expect_revert(
    rpc: str, key: str, address: str, signature: str, *args: str
) -> dict[str, Any]:
    proc = run_cmd_unchecked(
        [
            "cast",
            "send",
            "--json",
            address,
            signature,
            *args,
            "--rpc-url",
            rpc,
            "--private-key",
            key,
        ]
    )
    combined = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode == 0:
        raise RuntimeError(f"expected revert, transaction succeeded: {combined}")
    return {"reverted": True, "output": combined, "returncode": proc.returncode}


def block_number(rpc: str) -> int:
    return int(run_cast("block-number", "--rpc-url", rpc).strip(), 0)


def parse_tuple(raw: str) -> list[str]:
    text = raw.strip()
    for wrapper in (("(", ")"), ("[", "]")):
        if text.startswith(wrapper[0]) and text.endswith(wrapper[1]):
            text = text[1:-1].strip()
            break
    if not text:
        return []
    if "," in text:
        return [part.strip().strip('"') for part in text.split(",") if part.strip()]
    return [line.strip().strip('"') for line in text.split() if line.strip()]


def request_status(rpc: str, address: str, conversation_id: str) -> dict[str, Any]:
    raw = call(
        rpc,
        address,
        "requestStatus(bytes32)((uint8,uint8,address,bytes32,bytes32))",
        conversation_id,
    )
    parts = parse_tuple(raw)
    if len(parts) < 5:
        # forge-cast may print one field per line
        parts = [
            p.strip()
            for p in raw.replace("[", " ").replace("]", " ").replace("(", " ").replace(")", " ").replace(",", " ").split()
            if p.strip()
        ]
    return {
        "phase": int(parts[0], 0),
        "role": int(parts[1], 0),
        "transportPeer": parts[2],
        "logicalPeer": parts[3],
        "replyWith": parts[4],
    }


def pending(rpc: str, address: str, conversation_id: str) -> dict[str, Any]:
    raw = call(
        rpc,
        address,
        "pending(bytes32)((bool,address,bytes32,uint64,bytes))",
        conversation_id,
    )
    parts = parse_tuple(raw)
    if len(parts) < 5:
        parts = [
            p.strip()
            for p in raw.replace("[", " ").replace("]", " ").replace("(", " ").replace(")", " ").replace(",", " ").split()
            if p.strip()
        ]
    present = parts[0] in {"true", "1"}
    return {
        "present": present,
        "requester": parts[1],
        "replyWith": parts[2],
        "receivedBlock": int(parts[3], 0),
        "content": parts[4],
    }


def outcome(rpc: str, address: str, conversation_id: str) -> dict[str, Any]:
    raw = call(
        rpc,
        address,
        "outcomes(bytes32)((bool,uint8,bytes32,uint64,bytes))",
        conversation_id,
    )
    parts = parse_tuple(raw)
    if len(parts) < 5:
        parts = [
            p.strip()
            for p in raw.replace("[", " ").replace("]", " ").replace("(", " ").replace(")", " ").replace(",", " ").split()
            if p.strip()
        ]
    return {
        "present": parts[0] in {"true", "1"},
        "performative": int(parts[1], 0),
        "correlation": parts[2],
        "blockNumber": int(parts[3], 0),
        "content": parts[4],
    }


def wait_until(predicate, timeout: float, interval: float = 0.15, label: str = "condition"):
    deadline = time.time() + timeout
    last_error = None
    while time.time() < deadline:
        try:
            if predicate():
                return
        except Exception as exc:  # pragma: no cover - polling helper
            last_error = exc
        time.sleep(interval)
    raise TimeoutError(f"timed out waiting for {label}: {last_error}")
