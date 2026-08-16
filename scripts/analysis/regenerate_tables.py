#!/usr/bin/env python3
"""Regenerate publication tables/figures from published raw + derived JSON.

Run from the blade-evaluation root:
    python3 scripts/analysis/regenerate_tables.py
"""
from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TAB = ROOT / "results" / "tables"
FIG = ROOT / "results" / "figures"
EXPECT_PRI = "ee00c96b7992de82803a44d6cea3d583979a44be5d4c83fadab728f30a572d5d"
EXPECT_SEC = "a889e91b13c52739838a36c4c26282c2e2eaff1d100d441f2b86573b0557060c"


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def loadj(p: Path):
    return json.loads(p.read_text())


def pick(rows, cid):
    return next(r for r in rows if r["condition_id"] == cid)


def write_csv(path: Path, headers: list[str], rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=headers)
        w.writeheader()
        for r in rows:
            w.writerow({k: r[k] for k in headers})


def svg_xy(
    path: Path,
    *,
    title: str,
    xlabel: str,
    ylabel: str,
    xs: list[float],
    blade: list[float],
    manual: list[float],
    xticks: list[tuple[float, str]],
) -> None:
    W, H = 720, 480
    L, R, T, B = 88, 28, 36, 64
    pw, ph = W - L - R, H - T - B
    ymax = max(max(blade), max(manual)) * 1.08
    xmax = max(xs) * 1.06 if max(xs) else 1
    xmin = 0.0

    def sx(x):
        return L + (x - xmin) / (xmax - xmin) * pw

    def sy(y):
        return T + ph - y / ymax * ph

    def poly(vals, dash, mark):
        pts = " ".join(f"{sx(x):.2f},{sy(y):.2f}" for x, y in zip(xs, vals))
        d = f' stroke-dasharray="{dash}"' if dash else ""
        lines = [
            f'<polyline fill="none" stroke="#111" stroke-width="1.6"{d} points="{pts}"/>'
        ]
        for x, y in zip(xs, vals):
            if mark == "circle":
                lines.append(
                    f'<circle cx="{sx(x):.2f}" cy="{sy(y):.2f}" r="4.2" fill="#fff" stroke="#111" stroke-width="1.6"/>'
                )
            else:
                s = 7
                lines.append(
                    f'<rect x="{sx(x)-s/2:.2f}" y="{sy(y)-s/2:.2f}" width="{s}" height="{s}" fill="#fff" stroke="#111" stroke-width="1.6"/>'
                )
        return "\n".join(lines)

    yticks = 5
    grid = []
    for i in range(yticks + 1):
        yv = ymax * i / yticks
        y = sy(yv)
        grid.append(
            f'<line x1="{L}" y1="{y:.2f}" x2="{W-R}" y2="{y:.2f}" stroke="#ddd" stroke-width="1"/>'
        )
        lab = f"{int(round(yv)):,}"
        grid.append(
            f'<text x="{L-8}" y="{y+4:.2f}" text-anchor="end" font-size="11" font-family="DejaVu Sans,Helvetica,Arial,sans-serif">{lab}</text>'
        )
    xt = []
    for xv, lab in xticks:
        xt.append(
            f'<text x="{sx(xv):.2f}" y="{H-B+18}" text-anchor="middle" font-size="11" font-family="DejaVu Sans,Helvetica,Arial,sans-serif">{lab}</text>'
        )
    legend = f"""
    <g transform="translate({L+12},{T+8})">
      <line x1="0" y1="8" x2="28" y2="8" stroke="#111" stroke-width="1.6"/>
      <circle cx="14" cy="8" r="4.2" fill="#fff" stroke="#111" stroke-width="1.6"/>
      <text x="36" y="12" font-size="12" font-family="DejaVu Sans,Helvetica,Arial,sans-serif">BLADE</text>
      <line x1="120" y1="8" x2="148" y2="8" stroke="#111" stroke-width="1.6" stroke-dasharray="6 4"/>
      <rect x="131" y="4.5" width="7" height="7" fill="#fff" stroke="#111" stroke-width="1.6"/>
      <text x="156" y="12" font-size="12" font-family="DejaVu Sans,Helvetica,Arial,sans-serif">purpose-built Solidity</text>
    </g>"""
    body = f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <rect width="100%" height="100%" fill="#fff"/>
  <text x="{W/2}" y="22" text-anchor="middle" font-size="14" font-family="DejaVu Sans,Helvetica,Arial,sans-serif">{title}</text>
  {''.join(grid)}
  <line x1="{L}" y1="{T}" x2="{L}" y2="{H-B}" stroke="#111" stroke-width="1.2"/>
  <line x1="{L}" y1="{H-B}" x2="{W-R}" y2="{H-B}" stroke="#111" stroke-width="1.2"/>
  {poly(blade, '', 'circle')}
  {poly(manual, '6 4', 'square')}
  {''.join(xt)}
  <text x="{W/2}" y="{H-14}" text-anchor="middle" font-size="12" font-family="DejaVu Sans,Helvetica,Arial,sans-serif">{xlabel}</text>
  <text transform="translate(16,{T+ph/2}) rotate(-90)" text-anchor="middle" font-size="12" font-family="DejaVu Sans,Helvetica,Arial,sans-serif">{ylabel}</text>
  {legend}
</svg>
"""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)


def main() -> None:
    pri = ROOT / "data/raw/f3.jsonl"
    sec = ROOT / "data/raw/f3_secondary.jsonl"
    if sha(pri) != EXPECT_PRI or sha(sec) != EXPECT_SEC:
        raise SystemExit("ABORT: published raw hash mismatch")
    oh = loadj(ROOT / "data/derived/overhead.json")
    ohs = loadj(ROOT / "data/derived/secondary_overhead.json")
    dep = loadj(ROOT / "data/derived/deployment_gas.json")
    bc = loadj(ROOT / "data/derived/bytecode_sizes.json")
    rq3 = loadj(ROOT / "experiment/config/rq3.json")

    req_ids = [
        "REQ-R1-P0", "REQ-R2-P0", "REQ-R3-P0", "REQ-R4-P0",
        "REQ-R3-P32", "REQ-R3-P256", "REQ-R3-P1024",
    ]
    cn_ids = [
        "CN-A-N1-P0", "CN-A-N2-P0", "CN-A-N4-P0", "CN-A-N8-P0",
        "CN-A-N1-P256", "CN-A-N2-P32", "CN-A-N2-P256", "CN-A-N4-P256",
        "CN-A-N2-P1024", "CN-B-N2-P0", "CN-FAIL-A-N1-P0",
    ]
    headers = [
        "condition_id", "path", "payload_bytes", "participant_count",
        "gas_blade", "gas_manual", "absolute_delta", "relative_overhead",
        "ratio", "calldata_bytes_blade", "calldata_bytes_manual",
    ]

    def row(r):
        return {
            "condition_id": r["condition_id"],
            "path": r["path"],
            "payload_bytes": r["payload_bytes"],
            "participant_count": r["participant_count"],
            "gas_blade": r["gas_blade"],
            "gas_manual": r["gas_manual"],
            "absolute_delta": r["absolute_overhead"],
            "relative_overhead": f"{r['relative_overhead']:.10f}",
            "ratio": f"{r['ratio']:.10f}",
            "calldata_bytes_blade": r["calldata_bytes_blade"],
            "calldata_bytes_manual": r["calldata_bytes_manual"],
        }

    write_csv(TAB / "rq2_request_interaction.csv", headers, [row(pick(oh, i)) for i in req_ids])
    write_csv(TAB / "rq2_contractnet_interaction.csv", headers, [row(pick(oh, i)) for i in cn_ids])
    write_csv(
        TAB / "rq4_secondary.csv",
        headers + ["active_conversations"],
        [{**row(r), "active_conversations": r["active_conversations"]} for r in ohs],
    )

    dep_rows = []
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
    for r in dep:
        cname = name_map.get((r["implementation"], r["step"]))
        sizes = bc.get(cname, {})
        dep_rows.append(
            {
                "implementation": r["implementation"],
                "protocol": r["protocol"],
                "contract": cname or r["step"],
                "deployment_gas": r["deployment_gas"],
                "runtime_bytecode_bytes": sizes.get("runtime_bytecode_bytes", ""),
                "initcode_bytes": sizes.get("initcode_bytes", ""),
                "source_condition": r["condition_id"],
            }
        )
    write_csv(
        TAB / "rq2_deployment_bytecode.csv",
        [
            "implementation", "protocol", "contract", "deployment_gas",
            "runtime_bytecode_bytes", "initcode_bytes", "source_condition",
        ],
        dep_rows,
    )
    write_csv(
        TAB / "rq3_structural.csv",
        ["population", "total_loc", "protocol_loc", "policy_loc", "neutral_loc", "check_sites", "note"],
        [
            {
                "population": "A Core",
                "total_loc": rq3["A"]["core_loc_context"],
                "protocol_loc": "", "policy_loc": "", "neutral_loc": "",
                "check_sites": "",
                "note": "reusable framework; not subtracted in B vs C",
            },
            {
                "population": "B BLADE application",
                "total_loc": rq3["B"]["total"],
                "protocol_loc": rq3["B"]["protocol"],
                "policy_loc": rq3["B"]["policy"],
                "neutral_loc": rq3["B"]["neutral"],
                "check_sites": rq3["B"]["application_owned_protocol_check_sites"],
                "note": "application-owned protocol state = 0",
            },
            {
                "population": "C purpose-built Solidity",
                "total_loc": rq3["C"]["total"],
                "protocol_loc": rq3["C"]["protocol"],
                "policy_loc": rq3["C"]["policy"],
                "neutral_loc": rq3["C"]["neutral"],
                "check_sites": rq3["C"]["application_owned_protocol_check_sites"],
                "note": "mappings=3 nested=1 structs=4",
            },
        ],
    )

    r3 = [pick(oh, f"REQ-R3-P{n}") for n in (0, 32, 256, 1024)]
    svg_xy(
        FIG / "fig1_request_r3_payload.svg",
        title="Request R3 complete-interaction gas vs payload",
        xlabel="payload size (bytes)",
        ylabel="complete-interaction gas (gasUsed sum)",
        xs=[0, 32, 256, 1024],
        blade=[r["gas_blade"] for r in r3],
        manual=[r["gas_manual"] for r in r3],
        xticks=[(0, "0"), (32, "32"), (256, "256"), (1024, "1024")],
    )
    nser = [pick(oh, f"CN-A-N{n}-P0") for n in (1, 2, 4, 8)]
    svg_xy(
        FIG / "fig2_cn_a_vs_n.svg",
        title="Contract Net Scenario A complete-interaction gas vs N (0 B)",
        xlabel="participants N",
        ylabel="complete-interaction gas (gasUsed sum)",
        xs=[1, 2, 4, 8],
        blade=[r["gas_blade"] for r in nser],
        manual=[r["gas_manual"] for r in nser],
        xticks=[(1, "1"), (2, "2"), (4, "4"), (8, "8")],
    )
    print("LEVEL 2 regenerate OK")


if __name__ == "__main__":
    main()
