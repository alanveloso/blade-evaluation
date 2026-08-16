#!/usr/bin/env bash
# Verify published evidence hashes and row counts (run from the repository root).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
sha() { sha256sum -- "$1" | awk '{print $1}'; }
expect_sha() {
  local f="$1" e="$2"
  local g
  g="$(sha "$f")"
  [[ "$g" == "$e" ]] || fail "$f expected $e got $g"
}
expect_lines() {
  local f="$1" n="$2"
  local g
  g="$(wc -l < "$f" | tr -d ' ')"
  [[ "$g" == "$n" ]] || fail "$f expected $n lines got $g"
}

[[ -f PUBLIC_MANIFEST.sha256 ]] || fail "PUBLIC_MANIFEST.sha256 missing"
sha256sum --strict -c PUBLIC_MANIFEST.sha256

expect_sha data/raw/primary.jsonl 718675c92aa438e56a8dac7b1d065a36b05127bbeb417fdd4bde6bf9be6a02c1
expect_sha data/raw/secondary.jsonl d1f91a336ee0e550ce305d3bfebdeaceba42ca604337bed5471cc2ca39d009b0
expect_sha ablation/raw/ablation.json 83bdf04595e7edb73c48b7dbd5dd7bbb2905461cefc2836279491d3dd54ddf8a
expect_lines data/raw/primary.jsonl 304
expect_lines data/raw/secondary.jsonl 558

expect_sha comparison/src/blade-app/BladeRequest.sol d635e2e5be3209c3a69f6aa6dca8e3a7f34150e922bd56c58337aeef854fca1d
expect_sha comparison/src/blade-app/BladeContractNet.sol 88d92c9ddd73b1a648ad372e733e5f90a137fb2debb3ceb12d10f9186816e38a
expect_sha comparison/src/manual/ManualRequest.sol 8278ecbb69446673db9da30e5754bcf8ad4562440c38443ac3cb1490bc9f6377
expect_sha comparison/src/manual/ManualContractNet.sol c558af3b5abd18efc46bc31618beee4f9222925988bd070bd76b80fd94630198

for f in \
  results/tables/request_interaction.csv \
  results/tables/contractnet_interaction.csv \
  results/tables/deployment_bytecode.csv \
  results/tables/structural.csv \
  results/tables/scaling_secondary.csv \
  data/storage/request_r3.json \
  data/storage/cn_a_n2.json \
  data/storage/active_k.json \
  experiment/config/primary_matrix.json \
  ablation/variants/A0/Agent.sol
do
  [[ -f "$f" ]] || fail "missing $f"
done

echo "OK"
echo "canonical Core SHA (documented): fbf266f5a9304af3b4541ed82a5d814a6afda5cc"
