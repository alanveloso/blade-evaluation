# E3 provenance (Contract Net generated conversation ids)

Additive to the published E0/E1/E2 package (`PUBLIC_MANIFEST.sha256` / `PROVENANCE.md` unchanged for
those campaigns). Record both SHAs when promoting E3 evidence.

| Item | Value |
|---|---|
| BLADE (E3) | `f9ebfd36937abe66b35496ead25aa980e3c4b527` (update after the blade feature commit) |
| Evaluation branch | `feature/contract-net-generated-ids` |
| Evaluation commit | set from `evaluation_git.head` in `outputs/revision/E3/meta.json` after a run |
| Campaign | `E3` (`revision/config/campaigns.json`, profile `cn-generated`) |
| Ablation | `ABL-E3` (needs ablation trees rebased onto the E3 BLADE tree) |

`comparison/src/blade-app/BladeContractNet.sol` stays on the published `PUBLIC_MANIFEST` (E0–E2).
E3 only overlays `revision/pinned/blade-app/BladeContractNet.generated-ids.sol` inside the isolated
project. E2 event ablation overlays remain on `4b60b86159e89baccd24a859ca62e7039a8c8be2`.
