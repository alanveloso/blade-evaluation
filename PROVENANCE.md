# Provenance

This file records the evidence chain for the published evaluation of BLADE.

## Canonical BLADE Core

- Repository: https://github.com/alanveloso/blade
- Commit: `fbf266f5a9304af3b4541ed82a5d814a6afda5cc`

## Measurement identifiers

| Item | SHA-256 |
|---|---|
| Experiment spec | `af2da9cebbc8f847b02a68f9cce077f06c01a29c7c37494b779159916e5605b0` |
| Runner (`scripts/campaign/run_campaign.py`) | `b502331fe5dff6eff3b31d7da371e9ac8125c5a3a3244c99f210e4d291393c89` |
| Preflight (`scripts/campaign/preflight_enforce.py`) | `6495156a7d19abcd95f2f6326a71b2d5fec7aa076c2d37ec82463b95541af7fb` |

These hashes identify the measurement configuration and runner sources in this artifact. `PUBLIC_MANIFEST.sha256` is the integrity list of this publication package.

## Official raw measurements

| File | Rows | SHA-256 |
|---|---:|---|
| `data/raw/primary.jsonl` | 304 | `718675c92aa438e56a8dac7b1d065a36b05127bbeb417fdd4bde6bf9be6a02c1` |
| `data/raw/secondary.jsonl` | 558 | `d1f91a336ee0e550ce305d3bfebdeaceba42ca604337bed5471cc2ca39d009b0` |
| `ablation/raw/ablation.json` | — | `83bdf04595e7edb73c48b7dbd5dd7bbb2905461cefc2836279491d3dd54ddf8a` |

## Comparison sources

These are the Solidity sources used in the measured comparison.

| Path | SHA-256 |
|---|---|
| `comparison/src/blade-app/BladeRequest.sol` | `d635e2e5be3209c3a69f6aa6dca8e3a7f34150e922bd56c58337aeef854fca1d` |
| `comparison/src/blade-app/BladeContractNet.sol` | `88d92c9ddd73b1a648ad372e733e5f90a137fb2debb3ceb12d10f9186816e38a` |
| `comparison/src/manual/ManualRequest.sol` | `8278ecbb69446673db9da30e5754bcf8ad4562440c38443ac3cb1490bc9f6377` |
| `comparison/src/manual/ManualContractNet.sol` | `c558af3b5abd18efc46bc31618beee4f9222925988bd070bd76b80fd94630198` |

## Ablation A0 vs canonical Core

A0 source files used in the ablation are SHA-256 identical to the canonical BLADE Core source at the evaluated commit.

The nine files under `ablation/variants/A0/` are the ablation control tree and match `src/core` at the Core SHA in `experiment/config/experiment_spec.json`.

Primary-campaign absolute gas and ablation A0 absolute gas must not be mixed for factor deltas.

- Campaign example `conversationId`: `keccak("f3/REQ-R3-P0/blade")`
- Ablation: `keccak("ablation/R3/0")`

Factor effect is always `(gas_Ai − gas_A0_same_harness) / gas_A0_same_harness`.

## Toolchain

- Forge / Cast / Anvil 1.7.1
- Foundry commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8`
- Solidity 0.8.26
- optimizer=true, optimizer_runs=200, via_ir=false, evm_version=cancun
