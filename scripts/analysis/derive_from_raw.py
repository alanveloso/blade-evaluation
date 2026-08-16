#!/usr/bin/env python3
"""Build data/derived/* from data/raw JSONL. Does not overwrite raw."""
from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RAW = ROOT / "data" / "raw"
DER = ROOT / "data" / "derived"
CFG = ROOT / "experiment" / "config"


def load_jsonl(path: Path) -> list[dict]:
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip()]


def dump(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2) + "\n")


def complete_gas(rows: list[dict], cid: str, impl: str) -> int:
    xs = [
        r["complete_interaction_gas"]
        for r in rows
        if r["condition_id"] == cid
        and r["implementation"] == impl
        and r.get("record_kind") == "interaction_tx"
        and r.get("complete_interaction_gas") is not None
    ]
    vals = set(xs)
    if len(vals) != 1:
        raise SystemExit(f"gas {cid} {impl}: {vals}")
    return next(iter(vals))


def calldata_sum(rows: list[dict], cid: str, impl: str) -> int:
    return sum(
        int(r.get("top_level_calldata_bytes") or 0)
        for r in rows
        if r["condition_id"] == cid
        and r["implementation"] == impl
        and r.get("record_kind") == "interaction_tx"
    )


def meta(rows: list[dict], cid: str) -> dict:
    r = next(x for x in rows if x["condition_id"] == cid)
    return {
        "protocol": r.get("protocol"),
        "scenario": r.get("scenario"),
        "path": r.get("path"),
        "payload_bytes": r.get("payload_bytes"),
        "participant_count": r.get("participant_count"),
        "active_conversations": r.get("active_conversations"),
    }


def pair_row(rows: list[dict], cid: str) -> dict:
    b, m = complete_gas(rows, cid, "blade"), complete_gas(rows, cid, "manual")
    md = meta(rows, cid)
    return {
        "condition_id": cid,
        **md,
        "gas_blade": b,
        "gas_manual": m,
        "absolute_overhead": b - m,
        "relative_overhead": (b - m) / m,
        "ratio": b / m,
        "calldata_bytes_blade": calldata_sum(rows, cid, "blade"),
        "calldata_bytes_manual": calldata_sum(rows, cid, "manual"),
        "analysis_version": 1,
    }


def main() -> None:
    pri = load_jsonl(RAW / "primary.jsonl")
    sec = load_jsonl(RAW / "secondary.jsonl")
    pri_ids = []
    seen = set()
    for r in pri:
        cid = r["condition_id"]
        if cid not in seen:
            seen.add(cid)
            pri_ids.append(cid)
    overhead = [pair_row(pri, cid) for cid in pri_ids]
    dump(DER / "overhead.json", overhead)

    sec_ids = []
    seen = set()
    for r in sec:
        cid = r["condition_id"]
        if cid not in seen:
            seen.add(cid)
            sec_ids.append(cid)
    soh = [pair_row(sec, cid) for cid in sec_ids]
    dump(DER / "secondary_overhead.json", soh)

    with (DER / "overhead.csv").open("w", newline="") as fh:
        w = csv.DictWriter(
            fh,
            fieldnames=[
                "condition_id", "protocol", "path", "payload_bytes", "N", "K",
                "gas_blade", "gas_manual", "absolute_overhead", "relative_overhead", "ratio",
            ],
        )
        w.writeheader()
        for r in overhead + soh:
            w.writerow(
                {
                    "condition_id": r["condition_id"],
                    "protocol": r["protocol"],
                    "path": r["path"],
                    "payload_bytes": r["payload_bytes"],
                    "N": r["participant_count"],
                    "K": r["active_conversations"],
                    "gas_blade": r["gas_blade"],
                    "gas_manual": r["gas_manual"],
                    "absolute_overhead": r["absolute_overhead"],
                    "relative_overhead": r["relative_overhead"],
                    "ratio": r["ratio"],
                }
            )

    req = [r for r in overhead if r["protocol"] == "request"]
    with (DER / "request_interaction_gas.csv").open("w", newline="") as fh:
        w = csv.DictWriter(
            fh,
            fieldnames=["condition_id", "path", "payload_bytes", "gas_blade", "gas_manual", "relative_overhead"],
        )
        w.writeheader()
        for r in req:
            w.writerow({k: r[k] for k in w.fieldnames})

    dump(DER / "request_r3_payload.json", [r for r in overhead if r["condition_id"].startswith("REQ-R3-")])
    dump(DER / "cn_a_vs_n.json", [r for r in overhead if r["condition_id"] in {f"CN-A-N{n}-P0" for n in (1, 2, 4, 8)}])
    dump(DER / "cn_a_n2_vs_payload.json", [r for r in overhead if r["condition_id"].startswith("CN-A-N2-")])

    dump(
        DER / "calldata.json",
        {r["condition_id"]: {"blade": r["calldata_bytes_blade"], "manual": r["calldata_bytes_manual"]} for r in overhead},
    )

    dep = []
    seen_d = set()
    for r in pri:
        if r.get("record_kind") != "deployment":
            continue
        key = (r["implementation"], r["protocol"], r["interaction_step"], r["condition_id"])
        want = (
            (r["implementation"], "request", r["interaction_step"], "REQ-R1-P0")
            if r["protocol"] == "request"
            else (r["implementation"], "contract-net", r["interaction_step"], "CN-A-N1-P0")
        )
        if (r["implementation"], r["protocol"], r["interaction_step"]) in seen_d:
            continue
        if r["condition_id"] not in ("REQ-R1-P0", "CN-A-N1-P0"):
            continue
        seen_d.add((r["implementation"], r["protocol"], r["interaction_step"]))
        dep.append(
            {
                "implementation": r["implementation"],
                "protocol": r["protocol"],
                "step": r["interaction_step"],
                "deployment_gas": r["deployment_gas"],
                "condition_id": r["condition_id"],
            }
        )
    dump(DER / "deployment_gas.json", dep)

    name_map = {
        ("blade", "deploy_initiator"): "BladeRequester",
        ("blade", "deploy_participant"): "BladeParticipant",
        ("blade", "deploy_manager"): "BladeManager",
        ("blade", "deploy_participant_0"): "BladeCnParticipant",
        ("manual", "deploy_initiator"): "ManualInitiator",
        ("manual", "deploy_participant"): "ManualParticipant",
        ("manual", "deploy_manager"): "ManualManager",
        ("manual", "deploy_participant_0"): "ManualCnParticipant",
    }
    out = ROOT / "out"
    bc = {}
    for (impl, step), cname in name_map.items():
        sol = {
            "BladeRequester": "BladeRequest.sol",
            "BladeParticipant": "BladeRequest.sol",
            "BladeManager": "BladeContractNet.sol",
            "BladeCnParticipant": "BladeContractNet.sol",
            "ManualInitiator": "ManualRequest.sol",
            "ManualParticipant": "ManualRequest.sol",
            "ManualManager": "ManualContractNet.sol",
            "ManualCnParticipant": "ManualContractNet.sol",
        }[cname]
        artp = out / sol / f"{cname}.json"
        if not artp.is_file():
            continue

        def blen(obj):
            if isinstance(obj, dict):
                obj = obj.get("object") or ""
            s = obj[2:] if isinstance(obj, str) and obj.startswith("0x") else (obj or "")
            return len(s) // 2

        art = json.loads(artp.read_text())
        bc[cname] = {
            "runtime_bytecode_bytes": blen(art.get("deployedBytecode")),
            "initcode_bytes": blen(art.get("bytecode")),
        }
    dump(DER / "bytecode_sizes.json", bc)

    st = json.loads((CFG / "structural.json").read_text())
    app_red = (st["C"]["total"] - st["B"]["total"]) / st["C"]["total"]
    prot_red = (st["C"]["protocol"] - st["B"]["protocol"]) / st["C"]["protocol"]
    dump(
        DER / "structural.json",
        {
            "source": "experiment/config/structural.json",
            "A_core_loc": st["A"]["core_loc_context"],
            "B": st["B"],
            "C": st["C"],
            "application_loc_reduction": app_red,
            "protocol_loc_reduction": prot_red,
            "application_loc_reduction_pct": round(app_red * 100, 3),
            "protocol_loc_reduction_pct": round(prot_red * 100, 3),
        },
    )

    store = {
        "request_r3": json.loads((ROOT / "data/storage/request_r3.json").read_text()),
        "cn_a_n2": json.loads((ROOT / "data/storage/cn_a_n2.json").read_text()),
        "active_k": json.loads((ROOT / "data/storage/active_k.json").read_text()),
    }
    dump(DER / "storage.json", store)

    rels = [(r["condition_id"], r["relative_overhead"]) for r in overhead]
    mn, mx = min(rels, key=lambda x: x[1]), max(rels, key=lambda x: x[1])
    dump(
        ROOT / "results" / "summary.json",
        {
            "primary_relative_overhead_min": mn[1],
            "primary_relative_overhead_min_cell": mn[0],
            "primary_relative_overhead_max": mx[1],
            "primary_relative_overhead_max_cell": mx[0],
            "rq3_application_reduction": app_red,
            "rq3_protocol_reduction": prot_red,
            "storage": store,
            "raw_primary_sha256": hashlib.sha256((RAW / "primary.jsonl").read_bytes()).hexdigest(),
            "raw_secondary_sha256": hashlib.sha256((RAW / "secondary.jsonl").read_bytes()).hexdigest(),
        },
    )
    print("derived OK", "overhead cells", len(overhead), "min", f"{mn[1]*100:.3f}%", mn[0], "max", f"{mx[1]*100:.3f}%", mx[0])


if __name__ == "__main__":
    main()
