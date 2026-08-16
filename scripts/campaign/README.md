# Campaign runner

Portable measurement of gas, structural LOC, and ablation. Does not require `blade-internal`.

Layout:

```text
parent/
  blade/                 # git checkout matching experiment/config/experiment_spec.json core_sha
  blade-evaluation/      # this repository
```

Or set `BLADE_CORE` to the Core clone.

```bash
cp experiment/environment/foundry.toml foundry.toml
cp experiment/environment/remappings.txt remappings.txt
mkdir -p outputs/storage

python3 scripts/campaign/run_campaign.py --mode preflight-only
python3 scripts/campaign/run_campaign.py --mode dryrun
python3 scripts/campaign/run_campaign.py --mode campaign
python3 scripts/campaign/run_campaign.py --mode structural

python3 scripts/ablation/measure.py
```

Outputs:

- `outputs/raw/` — new JSONL (does not overwrite `data/raw/`)
- `outputs/structural/` — pygount / classify
- `outputs/ablation/raw/` — ablation JSON (does not overwrite `ablation/raw/`)
- `outputs/logs/`, `out/`, `cache/` — local

Structural LOC: `pip install pygount`. Drift versus `experiment/config/structural.json` is reported; set `STRUCTURAL_ENFORCE_FREEZE=1` to abort.

Toolchain: Forge/Cast/Anvil 1.7.1, Foundry `4072e48705af9d93e3c0f6e29e93b5e9a40caed8`, solc 0.8.26.
