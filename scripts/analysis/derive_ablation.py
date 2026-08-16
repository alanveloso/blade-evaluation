#!/usr/bin/env python3
"""Build ablation/derived/* from ablation/raw/ablation.json."""
from __future__ import annotations

import csv
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RAW = ROOT / "ablation" / "raw" / "ablation.json"
DER = ROOT / "ablation" / "derived"
FIG = ROOT / "ablation" / "figures"


def gas_of(cell: dict) -> int:
    if "complete_interaction_gas" in cell:
        return int(cell["complete_interaction_gas"])
    return int(cell["gas"])


def svg_bars(path: Path, title: str, labels: list[str], values: list[float], ylabel: str) -> None:
    W, H = 720, 420
    L, R, T, B = 88, 28, 40, 80
    pw, ph = W - L - R, H - T - B
    ymax = max(values) * 1.15 if values else 1
    n = len(labels)
    bw = pw / max(n, 1) * 0.62
    parts = [
        f'<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
        '<rect width="100%" height="100%" fill="#fff"/>',
        f'<text x="{W/2}" y="24" text-anchor="middle" font-size="14" font-family="DejaVu Sans,Helvetica,Arial,sans-serif">{title}</text>',
    ]
    for i in range(5):
        yv = ymax * i / 4
        y = T + ph - yv / ymax * ph
        parts.append(f'<line x1="{L}" y1="{y:.2f}" x2="{W-R}" y2="{y:.2f}" stroke="#ddd"/>')
        parts.append(
            f'<text x="{L-8}" y="{y+4:.2f}" text-anchor="end" font-size="11" font-family="DejaVu Sans,Helvetica,Arial,sans-serif">{yv*100:.1f}%</text>'
        )
    for i, (lab, v) in enumerate(zip(labels, values)):
        x = L + (i + 0.5) * (pw / n) - bw / 2
        h = v / ymax * ph
        y = T + ph - h
        parts.append(f'<rect x="{x:.2f}" y="{y:.2f}" width="{bw:.2f}" height="{h:.2f}" fill="#fff" stroke="#111"/>')
        parts.append(
            f'<text x="{x+bw/2:.2f}" y="{H-B+18}" text-anchor="middle" font-size="11" font-family="DejaVu Sans,Helvetica,Arial,sans-serif">{lab}</text>'
        )
    parts.append(f'<text x="{W/2}" y="{H-14}" text-anchor="middle" font-size="12" font-family="DejaVu Sans,Helvetica,Arial,sans-serif">{ylabel}</text>')
    parts.append("</svg>")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(parts) + "\n")


def main() -> None:
    blob = json.loads(RAW.read_text())
    results = blob["results"]
    a0 = results["A0"]
    effects = []
    for factor, cells in results.items():
        if factor == "A0":
            continue
        for cid, rec in sorted(cells.items()):
            g0 = gas_of(a0[cid])
            gi = gas_of(rec)
            effects.append(
                {
                    "cell": cid,
                    "official_gas": g0,
                    "ablated_gas": gi,
                    "delta": gi - g0,
                    "relative_effect": (gi - g0) / g0,
                    "factor": factor,
                }
            )
    DER.mkdir(parents=True, exist_ok=True)
    (DER / "effects.json").write_text(json.dumps(effects, indent=2) + "\n")
    with (DER / "effects.csv").open("w", newline="") as fh:
        w = csv.DictWriter(
            fh,
            fieldnames=["factor", "cell", "official_gas", "ablated_gas", "delta", "relative_effect"],
        )
        w.writeheader()
        for r in effects:
            w.writerow(
                {
                    "factor": r["factor"],
                    "cell": r["cell"],
                    "official_gas": r["official_gas"],
                    "ablated_gas": r["ablated_gas"],
                    "delta": r["delta"],
                    "relative_effect": r["relative_effect"],
                }
            )
    inter = []
    for n in (2, 4, 8):
        cid = f"CN-HALF-N{n}-P0"
        g0 = gas_of(a0[cid])
        g3 = gas_of(results["A3"][cid])
        g4 = gas_of(results["A4"][cid])
        g34 = gas_of(results["A34"][cid])
        add = (g3 - g0) + (g4 - g0)
        comb = g34 - g0
        inter.append(
            {
                "N": n,
                "cell": cid,
                "gas_A0": g0,
                "gas_A3": g3,
                "gas_A4": g4,
                "gas_A34": g34,
                "additive_delta": add,
                "combined_A34_delta": comb,
                "interaction": comb - add,
            }
        )
    (DER / "interaction_a3_a4.json").write_text(json.dumps(inter, indent=2) + "\n")
    (DER / "bytecode.json").write_text(json.dumps(blob.get("bytecode", {}), indent=2) + "\n")

    a3 = [r for r in effects if r["factor"] == "A3" and r["cell"].startswith("CN-A-N") and r["cell"].endswith("-P0")]
    a3.sort(key=lambda r: int(r["cell"].split("-N")[1].split("-")[0]))
    svg_bars(
        FIG / "membership_vs_n.svg",
        "A3 membership relative effect vs N (Scenario A, 0 B)",
        [r["cell"].split("-N")[1].split("-")[0] for r in a3],
        [r["relative_effect"] for r in a3],
        "relative effect vs A0",
    )
    reps = []
    for fac, cid in (("A1", "REQ-R3-P0"), ("A2", "REQ-R3-P0"), ("A3", "CN-A-N8-P0"), ("A4", "CN-HALF-N8-P0"), ("A5", "CN-A-N8-P0")):
        r = next(x for x in effects if x["factor"] == fac and x["cell"] == cid)
        reps.append((f"{fac}", r["relative_effect"]))
    svg_bars(
        FIG / "selected_effects.svg",
        "Selected ablation relative effects vs A0",
        [a for a, _ in reps],
        [v for _, v in reps],
        "relative effect vs A0",
    )

    def rng(fac):
        xs = [r["relative_effect"] for r in effects if r["factor"] == fac]
        return min(xs), max(xs)

    a1 = rng("A1")
    a2 = rng("A2")
    a5 = rng("A5")
    print("A1", f"{a1[0]*100:.3f}%", f"{a1[1]*100:.3f}%")
    print("A2", f"{a2[0]*100:.3f}%", f"{a2[1]*100:.3f}%")
    print("A5", f"{a5[0]*100:.3f}%", f"{a5[1]*100:.3f}%")
    for n in (1, 8, 16):
        r = next(x for x in effects if x["factor"] == "A3" and x["cell"] == f"CN-A-N{n}-P0")
        print("A3 N", n, f"{r['relative_effect']*100:.3f}%")
    for n in (2, 4, 8):
        r = next(x for x in effects if x["factor"] == "A4" and x["cell"] == f"CN-HALF-N{n}-P0")
        print("A4 HALF", n, f"{r['relative_effect']*100:.3f}%")


if __name__ == "__main__":
    main()
