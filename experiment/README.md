# Experiment

This directory holds the frozen experimental design used to measure BLADE against the purpose-built Solidity baseline. Machine-readable matrices and totals are in `config/`. Field meanings for raw records are in `schema/schema.md`.

## Environment

Place this artifact next to the canonical framework:

```text
parent/
  blade/                 # https://github.com/alanveloso/blade
                         # commit matching experiment/config/experiment_spec.json core_sha
  blade-evaluation/      # this repository
```

Compiler (as used in the measured campaign):

- Solidity 0.8.26
- optimizer true, optimizer_runs 200, via_ir false, evm_version cancun
- Forge / Cast / Anvil 1.7.1
- Foundry commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8`

Anvil (primary campaign): chain_id 31337, gas_limit 30000000, base_fee 1 gwei (`--block-base-fee-per-gas 1000000000`), genesis timestamp 1700000000.

Public Foundry files for semantic tests: `environment/foundry.toml` and `environment/remappings.txt`. They expect a sibling directory `../blade` at the evaluated commit.

## Deterministic inputs

Payload pattern: `repeat_0xab` (byte `0xab` repeated `n` times; not `0xA5`). Sizes: 0, 32, 256, 1024 bytes. Matched BLADE / purpose-built cells receive identical bytes.

| n | sha256 |
|---|---|
| 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| 32 | `9a2db2e23f1504cd056606553ac049c5e718e8f9ce9233876df1a7a1821af885` |
| 256 | `1080e279b51b8594a78556e2fdb4dfe9ca82ac2fbab5007de2bac4213c2e1f92` |
| 1024 | `4555555dc68d872c2270ba89ecc5f6f094812f65372b37e50071fe5168031c49` |

Host wall-clock (`date`, `time.time`) is not used as an experimental input.

## Interaction matrix

- **18** primary paired conditions (BLADE vs purpose-built): `config/primary_matrix.json`.
- Secondary cells: Request Agreed active conversations K = 1 / 10 / 100, and Contract Net N=16 under the 30M-gas local Anvil limit: `config/secondary_matrix.json`.
- Structural populations and markers: `config/structural.json`.
- Experiment spec identifier (frozen campaign label in raw records): `config/experiment_spec.json`.

Request R3 / 0 B appears once physically and serves both R-core and R-scale analyses (no duplicate row). Scenario C is not an independent quantitative observation. Feasibility / N=16 / active-K are secondary and are not mixed into primary overhead tables.

## Measurement definitions

### Gas

- Primary transaction gas: `receipt.gasUsed`.
- Complete-interaction gas: `sum(receipt.gasUsed)` over frozen **top-level** workload transactions.
- Deployment gas: deployment transaction `receipt.gasUsed`, reported separately from interaction gas.
- Excluded from interaction gas: Anvil startup, test setup, account funding, unrelated deployment, measurement-harness-only transactions, empty `evm_mine` blocks.
- Internal CALL gas is already inside `receipt.gasUsed`; do not add it again.

### Fees

- Anvil `base_fee = 1 gwei`. Base fee affects ETH paid, not EVM `gasUsed`.
- Monetary ETH/USD cost is not a primary metric.

### Block gas limit

- Experimental Anvil block gas limit: **30,000,000**. This is experiment configuration, not a mainnet support claim.
- N=16 completed under this local limit; that is not a claim that N=16 is supported on Ethereum mainnet.

### Calldata

- Primary: full top-level transaction input length, including the 4-byte selector.

### Storage

- `vm.record` / `vm.accesses` identify written slots; `vm.load` post-phase value.
- Count non-zero slots attributable to the measured workload; exclude harness/test storage.
- Request R3: before, active Agreed, terminal Inform.
- Contract Net scenario A: active proposal/evaluation phase and terminal completion.
- Do not equate RQ3 structural mappings/structs with measured storage slots.

## Deadline configuration

| Name | Value |
|---|---|
| Anvil genesis `--timestamp` | `1700000000` |
| `CHAIN_REF_TS` | `1700001000` |
| `DELTA` | `100` |
| CFP `replyBy` | `CHAIN_REF_TS + DELTA` = `1700001100` |
| accept-proposal `replyBy` | `0` |
| reject-proposal `replyBy` | `0` |

`replyBy` on CFP is the proposal-collection deadline. Zero on accept/reject is the Core encoding, not missing data. Request workloads use `replyBy = 0` in Message fields.

Procedure for every Contract Net CFP:

1. Start a fresh Anvil in the frozen genesis state (`--timestamp 1700000000`, no `--block-time`) per Contract Net measurement cell.
2. Immediately before the CFP transaction: `evm_setNextBlockTimestamp(CHAIN_REF_TS)`.
3. Send CFP with `replyBy = 1700001100`.
4. After propose/refuse acts: `evm_setNextBlockTimestamp(replyBy + 1)` then `evm_mine` (unmeasured empty block; not in interaction gas).
5. Continue evaluate / inform / failure.
6. Reconstruct AcceptProposal inbound messages for BLADE participant continuations with `replyBy = 0`.

The numeric CFP `replyBy` is part of CFP calldata; equivalent cells must reproduce the same encoding.

## Analysis definitions

Paired BLADE vs purpose-built on the same `condition_id`:

- absolute overhead: `BLADE - purpose-built`
- relative overhead: `(BLADE - purpose-built) / purpose-built`
- ratio: `BLADE / purpose-built`

Rules:

- Do not add statistical significance tests to deterministic gas.
- Do not average repeated identical executions.
- One canonical deterministic measurement per frozen condition.
- Do not fit a scaling model to the primary campaign.
- `phase = preflight` records are excluded from F3 derived tables.

## Reproduction notes

Level 1 (published hashes): `./scripts/verify_artifact.sh`

Level 2 (tables/figures from published raw + derived JSON): `python3 scripts/analysis/regenerate_tables.py`

Semantic tests: copy `environment/foundry.toml` and `environment/remappings.txt` to the artifact root and run `forge test` with sibling `blade` at the evaluated commit.

Published claims are verified from the frozen raw and derived files in this artifact.
