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

expect_sha data/raw/f3.jsonl ee00c96b7992de82803a44d6cea3d583979a44be5d4c83fadab728f30a572d5d
expect_sha data/raw/f3_secondary.jsonl a889e91b13c52739838a36c4c26282c2e2eaff1d100d441f2b86573b0557060c
expect_sha ablation/raw/ablation.json ee3a27abba30c6848a479e6afe03d7ea9cb2407e3dc9c96f6ae07ec50cafc894
expect_lines data/raw/f3.jsonl 304
expect_lines data/raw/f3_secondary.jsonl 558

expect_sha comparison/src/blade-app/BladeRequest.sol 29b646adc8d9bcbbb47e2844fbe604bfd1de120af29c6e0135fa04bb49fb69e7
expect_sha comparison/src/blade-app/BladeContractNet.sol 31d6997e0ea1a29fef780bcd5b22e2bb9b9e573e5384736aa0b971504a04e125
expect_sha comparison/src/manual/ManualRequest.sol 8278ecbb69446673db9da30e5754bcf8ad4562440c38443ac3cb1490bc9f6377
expect_sha comparison/src/manual/ManualContractNet.sol c558af3b5abd18efc46bc31618beee4f9222925988bd070bd76b80fd94630198

for f in \
  results/tables/rq2_request_interaction.csv \
  results/tables/rq2_contractnet_interaction.csv \
  results/tables/rq2_deployment_bytecode.csv \
  results/tables/rq3_structural.csv \
  results/tables/rq4_secondary.csv \
  data/storage/request_r3.json \
  data/storage/cn_a_n2.json \
  data/storage/active_k.json \
  experiment/config/primary_matrix.json \
  ablation/variants/A0/Agent.sol
do
  [[ -f "$f" ]] || fail "missing $f"
done

echo "OK"
echo "canonical Core SHA (documented): c145305a3ca76f52a64b62a0cb731283dbba9638"
