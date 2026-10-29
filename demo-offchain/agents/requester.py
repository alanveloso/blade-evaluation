#!/usr/bin/env python3
"""Agent A — off-chain requester. Talks only to its BLADE contract via JSON-RPC."""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from agents.common import (  # noqa: E402
    ID_A,
    ID_B,
    ID_C,
    PAYLOAD_ACCEPT,
    PAYLOAD_REFUSE,
    PAYLOAD_STALE,
    PAYLOAD_WRONG,
    PERFORMATIVE_INFORM,
    PERFORMATIVE_REFUSE,
    PHASE_NONE,
    PHASE_REQUESTED,
    append_log,
    init_ids,
    load_config,
    outcome,
    request_status,
    send,
    wait_until,
)


def decide(label: str) -> dict:
    """Local requester policy: which service to ask for. Independent of Agent B."""
    policy = {
        "A": {
            "id_key": "A",
            "payload": PAYLOAD_ACCEPT,
            "expect_performative": PERFORMATIVE_INFORM,
            "wait_outcome": True,
        },
        "B": {
            "id_key": "B",
            "payload": PAYLOAD_REFUSE,
            "expect_performative": PERFORMATIVE_REFUSE,
            "wait_outcome": True,
        },
        "C-wrong": {
            "id_key": "C",
            "payload": PAYLOAD_WRONG,
            "expect_performative": None,
            "wait_outcome": False,
        },
        "C-stale": {
            "id_key": "A",
            "payload": PAYLOAD_STALE,
            "expect_performative": None,
            "wait_outcome": False,
        },
    }
    return policy[label]


def main() -> int:
    parser = argparse.ArgumentParser(description="BLADE off-chain requester (Agent A)")
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    cfg = load_config(Path(args.config))
    ids = init_ids()
    rpc = cfg["rpc"]
    key = cfg["private_key"]
    contract = cfg["contract"]
    participant = cfg["participant_contract"]
    log_path = Path(cfg["log"])
    timeout = float(cfg.get("timeout_sec", 30))

    append_log(
        log_path,
        {
            "agent": "A",
            "event": "start",
            "pid": os_getpid(),
            "contract": contract,
            "policy": "request ACCEPT then REFUSE then open invalid-probe conversations",
        },
    )

    for label in cfg.get("cases", ["A", "B", "C-wrong", "C-stale"]):
        step = decide(label)
        conversation_id = ids[step["id_key"]]
        append_log(
            log_path,
            {
                "agent": "A",
                "event": "policy_decide_request",
                "case": label,
                "conversation_id": conversation_id,
                "payload": step["payload"],
            },
        )
        receipt = send(
            rpc,
            key,
            contract,
            "request(address,bytes32,bytes)",
            participant,
            conversation_id,
            step["payload"],
        )
        status = request_status(rpc, contract, conversation_id)
        append_log(
            log_path,
            {
                "agent": "A",
                "event": "request_sent",
                "case": label,
                "conversation_id": conversation_id,
                "tx": receipt.get("transactionHash"),
                "block": int(receipt.get("blockNumber", "0x0"), 0)
                if isinstance(receipt.get("blockNumber"), str)
                else receipt.get("blockNumber"),
                "phase": status["phase"],
                "role": status["role"],
                "token": status["replyWith"],
                "peer": status["transportPeer"],
            },
        )
        if status["phase"] != PHASE_REQUESTED:
            raise SystemExit(f"Agent A: expected Requested after send, got {status}")

        if step["wait_outcome"]:
            wait_until(
                lambda cid=conversation_id: outcome(rpc, contract, cid)["present"],
                timeout,
                label=f"Agent A outcome {label}",
            )
            result = outcome(rpc, contract, conversation_id)
            final = request_status(rpc, contract, conversation_id)
            append_log(
                log_path,
                {
                    "agent": "A",
                    "event": "outcome_observed",
                    "case": label,
                    "conversation_id": conversation_id,
                    "performative": result["performative"],
                    "correlation": result["correlation"],
                    "content": result["content"],
                    "outcome_block": result["blockNumber"],
                    "phase_after": final["phase"],
                },
            )
            if result["performative"] != step["expect_performative"]:
                raise SystemExit(
                    f"Agent A: unexpected performative {result['performative']} for {label}"
                )
            if final["phase"] != PHASE_NONE:
                raise SystemExit(f"Agent A: conversation {label} not cleared")
        else:
            # Decision of B, if any, must not complete these conversations.
            time.sleep(1.2)
            still = request_status(rpc, contract, conversation_id)
            result = outcome(rpc, contract, conversation_id)
            append_log(
                log_path,
                {
                    "agent": "A",
                    "event": "invalid_probe_window",
                    "case": label,
                    "conversation_id": conversation_id,
                    "phase": still["phase"],
                    "token": still["replyWith"],
                    "outcome_present": result["present"],
                },
            )
            if still["phase"] != PHASE_REQUESTED or result["present"]:
                raise SystemExit(
                    f"Agent A: invalid case {label} must remain Requested without outcome"
                )

    append_log(log_path, {"agent": "A", "event": "done"})
    return 0


def os_getpid() -> int:
    import os

    return os.getpid()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        sys.stderr.write(f"requester failed: {exc}\n")
        raise
