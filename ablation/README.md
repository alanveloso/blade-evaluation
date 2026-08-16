# Implementation ablation

These variants are **experimental counterfactuals**, not BLADE releases. They are measured modifications of **canonical BLADE** at commit `c145305a3ca76f52a64b62a0cb731283dbba9638`.

## A0 reference

A0 source files used in the ablation are SHA-256 identical to the canonical BLADE Core source at the evaluated commit. The nine files in `variants/A0/` match canonical `src/core`.

A0 is the canonical BLADE reference for the ablation harness.

## Variants

| ID | Role |
|---|---|
| A0 | canonical BLADE reference (control in this harness) |
| A1 | dispatch ablation |
| A2 | validation/copy ablation |
| A3 | membership ablation |
| A4 | live-write ablation |
| A34 | A3 + A4 interaction variant |
| A5 | combined ablation (A1+A2+A3+A4) |

Each tree under `variants/` is kept so a reviewer can inspect the measured counterfactual implementation directly. Shared files across variants are expected; the trees are not software versions.

## Harness distinction

Ablation effects are computed against A0 measured in the same harness. Do not mix F3 absolute gas with ablation A0 absolute gas.

- F3 example `conversationId`: `keccak("f3/REQ-R3-P0/blade")`
- Ablation: `keccak("ablation/R3/0")`

```text
(gas_Ai − gas_A0_same_harness) / gas_A0_same_harness
```

## Measured effects

- A1 (dispatch): **+1.909% to +4.490%**
- A2 (validation/copy): **+0.837% to +2.245%**
- A3 (membership): N=1 **+0.527%**; N=8 **+2.035%**; N=16 **+3.874%**
- A4 (live-write) under HALF: **+0.068%**, **+0.125%**, **+0.158%**
- A5 (combined) representative cells: **+5.377% to +9.510%**

Notes:

- N=16 is secondary local-Anvil evidence.
- A3+A4 were additive in the measured HALF 2×2; general additivity is not supported.
- Semantic equivalence tests used with the comparison workloads are under `comparison/test/` (31 non-storage tests).

Raw: `ablation/raw/ablation.json` SHA-256 `ee3a27abba30c6848a479e6afe03d7ea9cb2407e3dc9c96f6ae07ec50cafc894`.
