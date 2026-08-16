#!/usr/bin/env python3
"""Primary-matrix completeness from canonical JSON only."""
from __future__ import annotations

from collections import defaultdict

from frozen import PRIMARY, SECONDARY


def expected_primary_pairs() -> set[tuple[str, str]]:
    impls = tuple(PRIMARY["implementations"])
    if impls != ("blade", "manual"):
        raise SystemExit("frozen implementations must be blade, manual")
    return {(c["condition_id"], impl) for c in PRIMARY["conditions"] for impl in impls}


def expected_secondary_pairs() -> set[tuple[str, str]]:
    return {(c["condition_id"], impl) for c in SECONDARY["conditions"] for impl in ("blade", "manual")}


def interaction_pairs(rows: list[dict], *, primary: bool) -> set[tuple[str, str]]:
    out = set()
    for r in rows:
        if r.get("record_kind") != "interaction_tx":
            continue
        cid = r.get("condition_id")
        if primary and str(cid).startswith("SEC-"):
            continue
        if (not primary) and not str(cid).startswith("SEC-"):
            continue
        out.add((cid, r.get("implementation")))
    return out


def completeness_errors(rows: list[dict], *, matrix: str = "primary") -> list[str]:
    errs = []
    conds = PRIMARY["conditions"] if matrix == "primary" else SECONDARY["conditions"]
    expected = expected_primary_pairs() if matrix == "primary" else expected_secondary_pairs()
    by_id = {c["condition_id"]: c for c in conds}

    if matrix == "primary":
        if len(by_id) != PRIMARY["unique_condition_count"]:
            errs.append("canonical unique_condition_count mismatch")
        if PRIMARY["paired_run_count"] != len(expected):
            errs.append("canonical paired_run_count mismatch")
        r3p0 = [c for c in conds if c["path"] == "R3" and c["payload_bytes"] == 0]
        if len(r3p0) != 1:
            errs.append("R3/P0 duplicated as two independent conditions in canonical matrix")

    ids = [r.get("condition_id") for r in rows if r.get("record_kind") == "interaction_tx"]
    if any(i == "C" or (isinstance(i, str) and "CN-C" in i) for i in ids):
        errs.append("Scenario C appearing quantitatively")
    for r in rows:
        if r.get("scenario") == "C":
            errs.append("Scenario C appearing quantitatively")

    r3_ids = {
        r["condition_id"]
        for r in rows
        if r.get("record_kind") == "interaction_tx"
        and r.get("path") == "R3"
        and r.get("payload_bytes") == 0
        and not str(r.get("condition_id", "")).startswith("SEC-")
    }
    if len(r3_ids) > 1:
        errs.append("R3/P0 duplicated as two independent conditions")

    seen_tx = defaultdict(list)
    for r in rows:
        if r.get("record_kind") != "interaction_tx":
            continue
        key = (r.get("condition_id"), r.get("implementation"), r.get("interaction_step"))
        seen_tx[key].append(r)
    # duplicate cell = two different experiment encodings of same condition+impl
    cell_eids = defaultdict(set)
    for r in rows:
        if r.get("record_kind") != "interaction_tx":
            continue
        cell_eids[(r.get("condition_id"), r.get("implementation"))].add(r.get("experiment_id"))
    for k, eids in cell_eids.items():
        if len(eids) > 1:
            errs.append(f"duplicate cell {k}")

    pairs = interaction_pairs(rows, primary=(matrix == "primary"))
    missing = expected - pairs
    unexpected = pairs - expected
    for cid, impl in sorted(missing):
        errs.append(f"missing cell {cid}/{impl}")
    for cid, impl in sorted(unexpected):
        errs.append(f"unexpected condition {cid}/{impl}")
    # missing pair: condition present for one impl only
    by_cond = defaultdict(set)
    for cid, impl in pairs:
        by_cond[cid].add(impl)
    for cid, impls in by_cond.items():
        if impls != {"blade", "manual"}:
            errs.append(f"missing pair {cid} have {sorted(impls)}")
    return errs


def pairing_errors(rows: list[dict]) -> list[str]:
    """Same frozen workload params for blade vs manual; not ABI identity."""
    errs = []
    keys = (
        "condition_id",
        "protocol",
        "scenario",
        "path",
        "payload_bytes",
        "payload_sha256",
        "payload_pattern",
        "participant_count",
        "active_conversations",
        "reply_by",
        "chain_reference_timestamp",
    )
    groups = defaultdict(list)
    for r in rows:
        if r.get("record_kind") != "interaction_tx":
            continue
        groups[r["condition_id"]].append(r)
    for cid, xs in groups.items():
        blade = next((x for x in xs if x["implementation"] == "blade"), None)
        manual = next((x for x in xs if x["implementation"] == "manual"), None)
        if not blade or not manual:
            continue
        for k in keys:
            if blade.get(k) != manual.get(k):
                errs.append(f"pair mismatch {cid} field {k}")
    return errs


def gas_sum_errors(rows: list[dict]) -> list[str]:
    errs = []
    by = defaultdict(list)
    for r in rows:
        if r.get("record_kind") != "interaction_tx":
            continue
        by[(r.get("experiment_id"), r.get("condition_id"), r.get("implementation"))].append(r)
    for key, xs in by.items():
        s = sum(int(x["transaction_gas_used"]) for x in xs)
        comps = {x.get("complete_interaction_gas") for x in xs}
        if len(comps) != 1:
            errs.append(f"mixed complete_interaction_gas {key}")
        elif xs[0].get("status") == "ok" and s != next(iter(comps)):
            errs.append(f"complete_interaction_gas {next(iter(comps))} != sum {s} for {key}")
        for x in xs:
            if x.get("deployment_gas") not in (None,):
                errs.append(f"deployment_gas on interaction {key}")
    return errs
