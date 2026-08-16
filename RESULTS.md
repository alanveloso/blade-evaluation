# Results

Official evidence below is the frozen campaign measured at Core `fbf266f5a9304af3b4541ed82a5d814a6afda5cc`.

Central supported trade-off: **BLADE trades additional EVM execution and deployment cost for reusable on-chain protocol machinery and substantially less application-owned protocol code.** This document does not state that the trade-off is “worth it”.

## RQ1 — Protocol semantics (scoped)

The evaluated implementation satisfied the specified deterministic, fuzzing, and invariant properties for the supported Request and Contract Net semantics under Solidity 0.8.26, Cancun, Foundry 1.7.1 / `4072e487…`.

Evidence (not a formal proof):

- Canonical Core `forge test`: 12 suites, 148 passed.
- Invariant families Agent, Request, Contract Net: 48 runs, depth 24, `fail_on_revert=true`.
- Semantic A/B tests in `comparison/test/` (Request R1–R4, Contract Net A N=1/2/4/8, mixed propose/refuse, accepted failure, parametric payloads): 31 non-storage tests against the same Core and paired purpose-built baseline.

Supported Request subset: `request→refuse`; `request→inform`; `request→agree→inform`; `request→agree→failure`; `not-understood`. Outbound continuations bind to the live conversation peer.

Supported Contract Net subset: CFP; propose/refuse; accept/reject; inform/failure; `not-understood`; proposal-collection deadline (`CFP.replyBy`); evaluate after window close. Accept-proposal and reject-proposal use `replyBy = 0`.

The evaluation is limited to the implemented Request and Contract Net subsets and does not establish full FIPA compliance, external interoperability, or production security.

## RQ2 — Resource cost

Primary paired conditions: **18**.

Complete-interaction gas overhead of BLADE relative to purpose-built Solidity: **20.767%** (`CN-FAIL-A-N1-P0`) to **54.039%** (`REQ-R3-P1024`).

Machine-readable tables: `results/tables/request_interaction.csv`, `contractnet_interaction.csv`, `deployment_bytecode.csv`.

Deployment gas and runtime bytecode of BLADE wrappers also exceeded the corresponding purpose-built contracts. These are EVM resource measurements, not utility or developer-effort measurements.

## RQ3 — Structural abstraction

Verified totals (pygount-code + frozen markers):

| Population | Total LOC | Protocol | Policy | Neutral | App protocol checks |
|---|---:|---:|---:|---:|---:|
| A BLADE Core | 576 | — | — | — | — |
| B BLADE application | 84 | 80 | 2 | 2 | 0 |
| C purpose-built | 344 | 342 | 0 | 2 | 101 |

- Application LOC reduction: **75.581%**
- Protocol LOC reduction: **76.608%**

Line-level accounting: `data/derived/structural/line_audit.jsonl`, `totals.json`, `protocol_check_sites.json`.

LOC does **not** establish productivity, ease of use, fewer bugs, maintainability, or developer experience. Core 576 LOC remains visible so reusable machinery is not hidden.

## RQ4 — Scaling and storage

Payload (Request R3 complete-interaction gas): 183330, 186010, 204150, 289341 at 0/32/256/1024 B.

Contract Net Scenario A, 0 B, N=1/2/4/8: 259733, 444308, 813470, 1551774.

Secondary N=16 (local Anvil, 30,000,000 gas limit): BLADE 3028394, purpose-built 2396738, relative overhead 26.355%. Not a production or mainnet capacity claim.

Active Request Agreed conversations K=1/10/100: gas 138754, 1387516, 13875112; active slots I+P: 2, 20, 200; terminal slots: 0.

Storage (`data/storage/`):

- Request R3 (all four payload sizes, both implementations): active initiator 1, active participant 1, terminal 0; `payload_in_storage=false`.
- Contract Net A N=2 manager: 3 non-zero slots after propose and after evaluate, 0 at terminal.

## Ablation

See `ablation/README.md`. Variants A0–A5 are experimental counterfactuals, not BLADE releases. Deltas use A0 measured in the same ablation harness.

## Threats / scope

- Single deterministic execution per frozen cell; no inferential statistics.
- Ablation conversation IDs differ from the primary campaign; do not mix absolute gas across harnesses.
- N=16 and large K are secondary local-Anvil evidence.
- Semantic tests cover the measured happy-path subset, not all invalid-input selectors.
- Published claims are verified from frozen raw and derived files. Campaign re-measurement writes `outputs/` and does not overwrite `data/raw/` until those files are promoted.
- The evaluation is limited to the implemented Request and Contract Net subsets and does not establish full FIPA compliance, external interoperability, or production security.
