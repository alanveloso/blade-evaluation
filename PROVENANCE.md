# Provenance

This file records the evidence chain for the published evaluation of BLADE.

## Canonical BLADE Core

- Repository: https://github.com/alanveloso/blade
- Commit: `c145305a3ca76f52a64b62a0cb731283dbba9638`

## Measurement identifiers

| Item | SHA-256 |
|---|---|
| Experiment spec | `8e613546c1da2c91778d47d641b15e9020e09f8385d96ee78b5e0a1d8f422452` |
| Runner | `67d7c8153f23306b89240ba371ed137cb751968d5fbae9e4967bdda94083b3f3` |
| Preflight | `6f1e3f520eb27cefddcb114f9de0799751f77a2b51394bf1bb8e12bd6730ae28` |
| Scientific freeze-manifest file | `223dbceeccb04a40b3417a8170cb30d58ab7756375965649590c7e04b0829f6e` |

These hashes identify the measurement configuration before data collection. `PUBLIC_MANIFEST.sha256` is the integrity list of this publication package.

## Official raw measurements

| File | Rows | SHA-256 |
|---|---:|---|
| `data/raw/f3.jsonl` | 304 | `ee00c96b7992de82803a44d6cea3d583979a44be5d4c83fadab728f30a572d5d` |
| `data/raw/f3_secondary.jsonl` | 558 | `a889e91b13c52739838a36c4c26282c2e2eaff1d100d441f2b86573b0557060c` |
| `ablation/raw/ablation.json` | — | `ee3a27abba30c6848a479e6afe03d7ea9cb2407e3dc9c96f6ae07ec50cafc894` |

## Comparison sources

These are the Solidity sources used in the measured comparison.

| Path | SHA-256 |
|---|---|
| `comparison/src/blade-app/BladeRequest.sol` | `29b646adc8d9bcbbb47e2844fbe604bfd1de120af29c6e0135fa04bb49fb69e7` |
| `comparison/src/blade-app/BladeContractNet.sol` | `31d6997e0ea1a29fef780bcd5b22e2bb9b9e573e5384736aa0b971504a04e125` |
| `comparison/src/manual/ManualRequest.sol` | `8278ecbb69446673db9da30e5754bcf8ad4562440c38443ac3cb1490bc9f6377` |
| `comparison/src/manual/ManualContractNet.sol` | `c558af3b5abd18efc46bc31618beee4f9222925988bd070bd76b80fd94630198` |

## Ablation A0 vs canonical Core

A0 source files used in the ablation are SHA-256 identical to the canonical BLADE Core source at the evaluated commit.

The nine files under `ablation/variants/A0/` match `src/core` at `c145305a3ca76f52a64b62a0cb731283dbba9638`.

F3 absolute gas and ablation A0 absolute gas must not be mixed for factor deltas.

- F3 example `conversationId`: `keccak("f3/REQ-R3-P0/blade")`
- Ablation: `keccak("ablation/R3/0")`

Factor effect is always `(gas_Ai − gas_A0_same_harness) / gas_A0_same_harness`.

## Toolchain

- Forge / Cast / Anvil 1.7.1
- Foundry commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8`
- Solidity 0.8.26
- optimizer=true, optimizer_runs=200, via_ir=false, evm_version=cancun
