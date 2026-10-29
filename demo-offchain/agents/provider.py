#!/usr/bin/env python3
"""Agent B — off-chain provider. Talks only to its BLADE contract via JSON-RPC."""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from agents.common import (  # noqa: E402
    PAYLOAD_ACCEPT,
    PAYLOAD_REFUSE,
    PAYLOAD_STALE,
    PAYLOAD_WRONG,
    PERFORMATIVE_INFORM,
    PERFORMATIVE_REFUSE,
    REASON_BUSY,
    RESULT_DONE,
    WRONG_TOKEN,
    append_log,
    call,
    load_config,
    pending,
    send,
    send_expect_revert,
)


def as_int(value: str) -> int:
    text = value.strip().lower()
    if not text or text in {"0x", "0x0", "0x00"}:
        return 0
    if not text.startswith("0x"):
        text = "0x" + text
    return int(text, 16)


def policy_decide(content: str, conversation_id: str, remembered: dict[str, str]) -> dict:
    """Local provider policy. Independent of Agent A. Deterministic on payload."""
    payload = as_int(content)
    accept = as_int(PAYLOAD_ACCEPT)
    refuse = as_int(PAYLOAD_REFUSE)
    wrong = as_int(PAYLOAD_WRONG)
    stale = as_int(PAYLOAD_STALE)
    if payload == accept:
        return {
            "action": "inform",
            "performative": PERFORMATIVE_INFORM,
            "token_mode": "live",
            "content": RESULT_DONE,
        }
    if payload == refuse:
        return {
            "action": "refuse",
            "performative": PERFORMATIVE_REFUSE,
            "token_mode": "live",
            "content": REASON_BUSY,
        }
    if payload == wrong:
        return {
            "action": "invalid_wrong_token",
            "performative": PERFORMATIVE_INFORM,
            "token_mode": "wrong",
            "content": RESULT_DONE,
        }
    if payload == stale:
        old = remembered.get(conversation_id.lower())
        return {
            "action": "invalid_stale_token",
            "performative": PERFORMATIVE_INFORM,
            "token_mode": "stale",
            "stale_token": old,
            "content": RESULT_DONE,
        }
    return {
        "action": "refuse_unknown",
        "performative": PERFORMATIVE_REFUSE,
        "token_mode": "live",
        "content": REASON_BUSY,
    }


def list_pending_ids(rpc: str, contract: str) -> list[str]:
    raw = call(rpc, contract, "pendingIdCount()(uint256)")
    count = int(raw.strip(), 0)
    ids = []
    for i in range(count):
        ids.append(call(rpc, contract, "pendingIdAt(uint256)(bytes32)", str(i)).strip())
    return ids


def main() -> int:
    parser = argparse.ArgumentParser(description="BLADE off-chain provider (Agent B)")
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    cfg = load_config(Path(args.config))
    rpc = cfg["rpc"]
    key = cfg["private_key"]
    contract = cfg["contract"]
    log_path = Path(cfg["log"])
    stop_path = Path(cfg["stop_file"])
    poll = float(cfg.get("poll_sec", 0.2))

    remembered_tokens: dict[str, str] = {}
    handled: set[str] = set()
    attempted_invalid: set[str] = set()

    append_log(
        log_path,
        {
            "agent": "B",
            "event": "start",
            "pid": os.getpid(),
            "contract": contract,
            "policy": "ACCEPT->Inform, REFUSE->Refuse, 0x03->wrong token, 0x04->stale token",
        },
    )

    while not stop_path.exists():
        try:
            ids = list_pending_ids(rpc, contract)
        except Exception as exc:
            append_log(log_path, {"agent": "B", "event": "poll_error", "error": str(exc)})
            time.sleep(poll)
            continue

        for conversation_id in ids:
            cid_key = conversation_id.lower()
            item = pending(rpc, contract, conversation_id)
            if not item["present"]:
                continue

            live_token = item["replyWith"]
            instance_key = f"{cid_key}:{live_token.lower()}"
            if instance_key in handled or instance_key in attempted_invalid:
                continue
            previous = remembered_tokens.get(cid_key)
            decision = policy_decide(item["content"], conversation_id, remembered_tokens)
            append_log(
                log_path,
                {
                    "agent": "B",
                    "event": "observed_request",
                    "conversation_id": conversation_id,
                    "requester": item["requester"],
                    "live_token": live_token,
                    "previous_token": previous,
                    "received_block": item["receivedBlock"],
                    "content": item["content"],
                    "decision": decision["action"],
                    "note": "decision is off-chain and after the delivering transaction",
                },
            )

            if decision["token_mode"] == "live":
                token = live_token
            elif decision["token_mode"] == "wrong":
                token = WRONG_TOKEN
            else:
                token = decision.get("stale_token") or WRONG_TOKEN

            if decision["token_mode"] == "live":
                receipt = send(
                    rpc,
                    key,
                    contract,
                    "respond(bytes32,uint8,bytes32,bytes)",
                    conversation_id,
                    str(decision["performative"]),
                    token,
                    decision["content"],
                )
                append_log(
                    log_path,
                    {
                        "agent": "B",
                        "event": "response_sent",
                        "conversation_id": conversation_id,
                        "action": decision["action"],
                        "token_used": token,
                        "tx": receipt.get("transactionHash"),
                        "block": int(receipt.get("blockNumber", "0x0"), 0)
                        if isinstance(receipt.get("blockNumber"), str)
                        else receipt.get("blockNumber"),
                    },
                )
                handled.add(instance_key)
                remembered_tokens[cid_key] = live_token
            else:
                revert_info = send_expect_revert(
                    rpc,
                    key,
                    contract,
                    "respond(bytes32,uint8,bytes32,bytes)",
                    conversation_id,
                    str(decision["performative"]),
                    token,
                    decision["content"],
                )
                still = pending(rpc, contract, conversation_id)
                append_log(
                    log_path,
                    {
                        "agent": "B",
                        "event": "response_rejected_by_core",
                        "conversation_id": conversation_id,
                        "action": decision["action"],
                        "token_used": token,
                        "live_token": live_token,
                        "pending_still_present": still["present"],
                        "revert": revert_info["output"][-800:],
                    },
                )
                attempted_invalid.add(instance_key)

            if previous is None and decision["token_mode"] == "live":
                remembered_tokens[cid_key] = live_token

        time.sleep(poll)

    append_log(log_path, {"agent": "B", "event": "stop"})
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        sys.stderr.write(f"provider failed: {exc}\n")
        raise
