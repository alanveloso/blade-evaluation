# Results

Official evidence for the empirical evaluation of **BLADE** at commit `c145305a3ca76f52a64b62a0cb731283dbba9638`.

Central supported trade-off: **BLADE trades additional EVM execution and deployment cost for reusable on-chain protocol machinery and substantially less application-owned protocol code.** This document does not state that the trade-off is “worth it”.

## RQ1 — Protocol semantics (scoped)

The evaluated implementation satisfied the specified deterministic, fuzzing, and invariant properties for the supported Request and Contract Net semantics under Solidity 0.8.26, Cancun, Foundry 1.7.1 / `4072e487…`.

Evidence (not a formal proof):

- Canonical Core `forge test`: 10 suites, 129 passed.
- Invariant families Agent, Request, Contract Net: 48 runs, depth 24, `fail_on_revert=true`.
- Semantic A/B tests in `comparison/test/` (Request R1–R4, Contract Net A N=1/2/4/8, mixed propose/refuse, accepted failure, parametric payloads): 31 non-storage tests against the same Core and paired purpose-built baseline.

Supported Request subset: `request→refuse`; `request→inform`; `request→agree→inform`; `request→agree→failure`; `not-understood`. Outbound continuations bind to the live conversation peer.

Supported Contract Net subset: CFP; propose/refuse; accept/reject; inform/failure; `not-understood`; proposal-collection deadline (`CFP.replyBy`); evaluate after window close. Accept-proposal and reject-proposal use `replyBy = 0`.

The evaluation is limited to the implemented Request and Contract Net subsets and does not establish full FIPA compliance, external interoperability, or production security.

## RQ2 — Resource cost

Primary paired conditions: **18**.

Complete-interaction gas overhead of BLADE relative to purpose-built Solidity: **20.338%** (`CN-FAIL-A-N1-P0`) to **53.948%** (`REQ-R3-P1024`).

Machine-readable tables: `results/tables/rq2_request_interaction.csv`, `rq2_contractnet_interaction.csv`, `rq2_deployment_bytecode.csv`.

Deployment gas and runtime bytecode of BLADE wrappers also exceeded the corresponding purpose-built contracts. These are EVM resource measurements, not utility or developer-effort measurements.

## RQ3 — Structural abstraction

Verified totals (pygount-code + frozen markers):

| Population | Total LOC | Protocol | Policy | Neutral | App protocol checks |
|---|---:|---:|---:|---:|---:|
| A BLADE Core | 539 | — | — | — | — |
| B BLADE application | 82 | 78 | 2 | 2 | 0 |
| C purpose-built | 344 | 342 | 0 | 2 | 101 |

- Application LOC reduction: **76.163%**
- Protocol LOC reduction: **77.193%**

Line-level accounting: `data/derived/rq3/line_audit.jsonl`, `rq3_totals.json`, `protocol_check_sites.json`.

LOC does **not** establish productivity, ease of use, fewer bugs, maintainability, or developer experience. Core 539 LOC remains visible so reusable machinery is not hidden.

## RQ4 — Scaling and storage

Payload (Request R3 complete-interaction gas): 183046, 185726, 203866, 289170 at 0/32/256/1024 B.

Contract Net Scenario A, 0 B, N=1/2/4/8: 258810, 442410, 809622, 1544026.

Secondary N=16 (local Anvil, 30,000,000 gas limit): BLADE 3012846, purpose-built 2396738, relative overhead 25.706%. Not a production or mainnet capacity claim.

Active Request Agreed conversations K=1/10/100: gas 138583, 1385806, 13858012; active slots I+P: 2, 20, 200; terminal slots: 0.

Storage (`data/storage/`):

- Request R3 (all four payload sizes, both implementations): active initiator 1, active participant 1, terminal 0; `payload_in_storage=false`.
- Contract Net A N=2 manager: 3 non-zero slots after propose and after evaluate, 0 at terminal.

## Ablation

See `ablation/README.md`. Variants A0–A5 are experimental counterfactuals, not BLADE releases. Deltas use A0 measured in the same ablation harness.

## Threats / scope

- Single deterministic execution per frozen cell; no inferential statistics.
- Ablation conversation IDs differ from F3; do not mix absolute gas across harnesses.
- N=16 and large K are secondary local-Anvil evidence.
- Semantic tests cover the measured happy-path subset, not all invalid-input selectors.
- Published claims are verified from frozen raw and derived files; full campaign re-measurement is not packaged as a self-contained public command.
- The evaluation is limited to the implemented Request and Contract Net subsets and does not establish full FIPA compliance, external interoperability, or production security.
