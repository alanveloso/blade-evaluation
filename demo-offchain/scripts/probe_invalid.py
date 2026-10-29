#!/usr/bin/env python3
"""Validation probe for Case C: unauthorized sender. Not an agent."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from agents.common import (  # noqa: E402
    ACCOUNT_2,
    KEY_2,
    PERFORMATIVE_INFORM,
    PHASE_REQUESTED,
    PROTOCOL_FIPA_REQUEST,
    ZERO_BYTES32,
    append_log,
    init_ids,
    load_config,
    outcome,
    request_status,
    send_expect_revert,
)


def encode_handle_tuple(conversation_id: str, token: str) -> str:
    # Message: (uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes)
    return (
        f"({PERFORMATIVE_INFORM},{PROTOCOL_FIPA_REQUEST},{conversation_id},"
        f"{ZERO_BYTES32},{token},0,{ZERO_BYTES32},0x)"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    cfg = load_config(Path(args.config))
    ids = init_ids()
    rpc = cfg["rpc"]
    requester = cfg["requester"]
    log_path = Path(cfg["log"])
    conversation_id = ids["C"]

    before = request_status(rpc, requester, conversation_id)
    if before["phase"] != PHASE_REQUESTED:
        raise SystemExit(f"probe expected live Case C, got {before}")
    token = before["replyWith"]

    revert_info = send_expect_revert(
        rpc,
        KEY_2,
        requester,
        "handle((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes))",
        encode_handle_tuple(conversation_id, token),
    )
    after = request_status(rpc, requester, conversation_id)
    out = outcome(rpc, requester, conversation_id)
    record = {
        "probe": "unauthorized_sender",
        "from": ACCOUNT_2,
        "conversation_id": conversation_id,
        "phase_before": before["phase"],
        "phase_after": after["phase"],
        "token_before": before["replyWith"],
        "token_after": after["replyWith"],
        "outcome_present": out["present"],
        "state_unchanged": before == after and not out["present"],
        "revert": revert_info["output"][-800:],
    }
    append_log(log_path, record)
    print(json.dumps(record, indent=2))
    if not record["state_unchanged"]:
        raise SystemExit("unauthorized probe mutated conversation state")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
