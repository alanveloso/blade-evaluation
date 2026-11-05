# E3 provenance (Contract Net generated conversation ids)

Additive to the published E0/E1/E2 package (`PUBLIC_MANIFEST.sha256` / `PROVENANCE.md` unchanged for
those campaigns).

| Item | Value |
|---|---|
| BLADE | `f9ebfd36937abe66b35496ead25aa980e3c4b527` |
| Evaluation (evidence commit) | `6d2997e268134ac38e0b108574fc199dbe92dc3f` (promote of `revision/data/E3` + `ABL-E3`) |
| Campaign | `E3` — profile `cn-generated` in `revision/config/campaigns.json` |
| Ablation | `ABL-E3` — trees in `ablation/variants-e3/` (A0 byte-identical to BLADE `src/core` at the pin above) |
| Derived tables | `revision/results/` via `revision/scripts/analyze_revision.py` (includes E3 / ABL-E3) |

## Layout

- Historical `comparison/src/blade-app/BladeContractNet.sol` remains on `PUBLIC_MANIFEST` (E0–E2).
- E3 overlays `revision/pinned/blade-app/BladeContractNet.generated-ids.sol` only inside the isolated
  runner project.
- Promoted raw evidence: `revision/data/E3/`, `revision/data/ABL-E3/`.
- E2 event ablation overlays stay on `4b60b86159e89baccd24a859ca62e7039a8c8be2`.

## Reproduce

```sh
export BLADE_REPO=/path/to/blade   # checkout containing f9ebfd3…
R=revision/scripts/run_revision.py
python3 $R --mode tests --campaign E3
python3 $R --mode campaign --campaign E3 --matrix diagnostic primary secondary
python3 $R --mode ablation --campaign ABL-E3
python3 revision/scripts/promote.py E3 ABL-E3
(cd revision/scripts && python3 analyze_revision.py)
```
