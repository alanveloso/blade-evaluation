# JAAMAS revision: experimental re-evaluation

This directory holds the revised evaluation. It is additive: nothing listed in
`PUBLIC_MANIFEST.sha256` (submitted scripts, raw data, ablation data, comparison sources and
README/RESULTS) is modified. Every revision run verifies those hashes before and after it executes,
and `scripts/verify_artifact.sh` still passes.

## Campaigns

| ID | Core | Hardfork | Inbound payload | Manual baseline | Purpose |
|---|---|---|---|---|---|
| E0 | fbf266f | Anvil default (`latest` = Bpo1) | legacy (re-sent) | submitted | Submitted results (`data/raw`, untouched) |
| E0R | fbf266f | Anvil default | legacy | submitted | Replay of E0 through the revision runner |
| E1H | fbf266f | Cancun (explicit) | legacy | submitted | Isolates the hardfork effect |
| E1 | fbf266f | Cancun | minimal | submitted | Original Core, corrected methodology |
| E2 | 4b60b86 | Cancun | minimal | submitted | Corrected Core, corrected methodology |
| E2-EV-NORECV / -NOPHASE / -NONE | 4b60b86 with `emit`s stripped | Cancun | minimal | submitted | Event cost (measurement-only Cores) |
| E2-MOBS | 4b60b86 | Cancun | minimal | `observable` | Manual with BLADE-identical events |
| E2-MCORR | 4b60b86 | Cancun | minimal | `correlated` | Manual with the E2 correlation guarantee |
| E2-MCOBS | 4b60b86 | Cancun | minimal | `observable` + `correlated-observable` | Manual with both |
| ABL-E0R / ABL-E1 / ABL-E2 | E0R / E1 / E2 bases | as base | as base | n/a | Ablations A1–A5, A34 |
| S-NONCE | 4b60b86 + nonce-packed overlay | Cancun | minimal | submitted | Isolated study, not E3 |

Core commits (`git@github.com:alanveloso/blade.git`):
`fbf266f5a9304af3b4541ed82a5d814a6afda5cc` is the submitted Core;
`4b60b86159e89baccd24a859ca62e7039a8c8be2` is the corrected Core. Its Solidity sources are identical
to `baeae00`, which additionally contained an accidentally nested `blade/` directory.

Divergences from the original revision plan:

- The commit references given in the plan were stale; the SHAs above are the ones measured.
- E0 was not run under Cancun. Anvil 1.7.1 defaults to `--hardfork latest` (Bpo1), so the
  EIP-7623 calldata floor applied to the 1024-byte cells. E1H separates this effect.
- The harness change that removes the redundant payload is a methodology change, not a Core change.
  It is therefore applied to both E1 and E2.

Configuration: `config/campaigns.json` (`config_id` `blade-jaamas-revision-r1`). Each campaign writes
to `outputs/revision/<ID>/` (with `meta.json`, `environment.json`, per-row `campaign_id`, requested and
effective hardfork, toolchain versions and source hashes). Validated outputs are promoted to
`data/<ID>/`. Toolchain: Foundry/Anvil 1.7.1 (4072e48), solc 0.8.26, optimizer 200 runs, no via-IR.

## Running

```sh
R=revision/scripts/run_revision.py
python3 $R --mode tests     --campaign E2          # profile `token` (default for E2)
python3 $R --mode tests     --campaign E1          # profile `historical` (originals + revision ports)
python3 $R --mode core-tests --campaign E2         # Core suite + revision/test-core
python3 $R --mode preflight --campaign E2          # hardfork, chain and determinism checks
python3 $R --mode campaign  --campaign E2          # primary + secondary matrices
python3 $R --mode campaign  --campaign E2-EV-NONE --matrix events
python3 $R --mode ablation  --campaign ABL-E2
python3 revision/scripts/make_event_variants.py --check
python3 revision/scripts/promote.py E2 ABL-E2      # copies outputs and rewrites REVISION_MANIFEST.sha256
(cd revision/scripts && python3 analyze_revision.py)
```

Anvil is started with an explicit `--hardfork`. A campaign aborts unless `anvil_nodeInfo` reports the
expected hardfork and a probe of EIP-2537 BLS12-381 G1ADD (`0x0b`, Prague+) is consistent with it.
The probe sends a *valid* input (two G1 points at infinity, 256 zero bytes). An active precompile
returns the 128-byte encoding of infinity; Cancun has no code at that address and returns empty
output. An empty-input call is secondary evidence (PrecompileError when the precompile is active).
Empirically: Cancun → empty `0x` on both calls; Anvil default Bpo1 → 128-byte infinity and
PrecompileError. Campaigns already measured under this rule were not rerun.

## Test profiles

Historical tests in `comparison/test/` are never modified. Each campaign selects a profile in
`config/campaigns.json`; replaced originals are copied into the isolated project as
`comparison/test/inapplicable/*.historical` (not compiled) with the reason recorded in
`test_profile_all.json`.

| Profile | Campaigns | What runs |
|---|---|---|
| `historical` | E0R, E1H, E1 | Original Request/Parametric/Storage/ContractNet plus all revision tests |
| `token` | E2, E2-EV-NOPHASE, baselines, S-NONCE | Originals that cannot express the token are replaced by complete ports (`RequestEquivalenceRev`, `ParametricEquivalenceRev`, `StorageRev`); `ContractNetEquivalence` unchanged |
| `token-no-received` | E2-EV-NORECV, E2-EV-NONE | As `token`, plus `REVISION_EXPECT_RECEIVED=false`: payload delivery is asserted on recorded `handle` calldata; `Received` logs must be absent |

`ParametricEquivalenceRev` keeps the 13 original cells and state assertions, carries the Core-assigned
token, and requires the N=8 cell to pass (the original may skip on resource exhaustion).
`StorageRev` keeps the three probes and requires session slots to return to zero while allowing the
persistent nonce slot.

## Results (all values in `results/`)

### Reproduction and methodology effects

- E0R reproduces every interaction transaction of E0 exactly (862 rows). The only deployment
  difference is BladeParticipant, 946,271 vs 946,259 gas, caused by the bytecode metadata hash of
  different source paths. ABL-E0R reproduces `ablation/raw/ablation.json` exactly.
- Hardfork (E1H − E0): the effect is zero up to 256-byte payloads. REQ-R3-P1024 changes by −22,821
  (BLADE) and −19,505 (manual), so the overhead rises from 54.039% to 58.331%. CN-A-N2-P1024 changes by
  −31,684 and −47,195, raising the overhead from 33.232% to 40.433%.
- Redundant payload (E1 − E1H, BLADE only): the payload was re-sent in the inbound message of every
  continuation, and neither the wrappers nor the Core read it (`PayloadEncodingEquivalence.t.sol`
  shows identical logs and state with payload, empty or garbage content). Removing it saves 32,792
  gas on REQ-R3-P1024 and 8,216 on CN-A-N2-P256 (−4,108 per participant at 256 B).
- Primary-matrix overhead ranges: E0 20.767–54.039%, E1H 20.767–58.331%, E1 20.767–38.850%,
  E2 20.767–102.184%. Contract Net is unchanged between E1 and E2.

### Corrected Core (E2 − E1)

The Request fix assigns a single-use token per conversation and stores it on both sides.

- Complete Request interactions increase by 74.3k–79.5k gas. Per transaction, `startRequest` costs
  +66,756 for the first request and +49,656 in steady state (the nonce slot is already non-zero).
  `agree` costs +5,175 and terminal replies about +7.5k.
- Deployment: BladeRequester +78,053 (runtime 3,422 → 3,783 B); BladeParticipant +50,579
  (4,136 → 4,370 B).
- Marginal cost per additional active conversation (K=10 → 100): E1 138,751; E2 193,580; manual 107,141.

### Storage

While a conversation is active, E2 BLADE holds 2 session slots on each side; E1 and the submitted
manual baseline hold 1. The initiator also keeps 1 persistent nonce slot. Session slots return to
zero at the terminal message, and the payload is never stored. An abandoned conversation strands
3 initiator + 2 participant slots in E2, against 1 + 1 in E1 and the manual baseline. The
correlated manual variants have exactly the E2 storage profile.

### Events

Events account for 7.1–20.5% of BLADE gas in the measured cells. Without any event, BLADE's overhead
over the submitted manual baseline is 5.7–6.4% for Contract Net and 60.8–87.8% for Request. Against a
manual baseline that emits the same events, the overheads are 5.5–6.7% and 48.7–78.3%.
The official Core keeps all its events; the event-stripped Cores in `variants/events/` exist only
for measurement.

### Baseline guarantees (sensitivity, not replacement)

The submitted manual baseline binds each continuation to stored state and has no
application-supplied inbound message or relay, so a stale reply cannot be expressed against it.
Token correlation is the guarantee E2 adds for an API where the application does supply inbound
messages. Neither design defends against a malicious peer. The revised baselines are therefore
reported as sensitivity bounds next to the submitted one, not instead of it.

| Baseline | Request overhead (primary) | Contract Net overhead (primary) |
|---|---|---|
| submitted manual | 83.1–102.2% | 20.8–32.9% |
| correlated | 16.0–25.2% | unchanged (20.8–32.9%) |
| observable | 48.7–78.3% | 5.4–7.0% |
| correlated + observable | 7.8–10.9% | 5.4–7.0% |

The variants pass dedicated tests. `test-variants/correlated-observable` compares per-role logs as
**ordered sequences of full values** (addresses and tokens mapped; any other difference fails),
checks the Core token formula `keccak256(chainid, initiator, conversationId, nonce)`, rejects a
stale token after `conversationId` reuse, isolates concurrent conversations, and records that both
sides clear storage at the terminal message. Transaction sequences are identical
(`startRequest`, `agree`, `inform` / `refuse` / `failure`). Compiler, hardfork, payload encoding and
the BLADE-side Core are the same as E2.

Documented semantic differences (not hidden gaps):

- Tokens differ numerically because each initiator hashes its own address.
- The purpose-built participant takes the token from storage, so a wrong application-supplied
  inbound token is not expressible there; BLADE rejects it (`test_wrongTokenFromParticipantSide`).
- The purpose-built API has no `logicalSender` / `trustedRelay`.
- Contract Net in E2-MCOBS is the `observable` layer (events only); it has no Request-style token.

### Ablation

Deltas are variant − A0. A positive delta means the Core optimisation saves gas.

- A4 is **negative** (−101 gas, −0.039% to −0.007%) in every all-accept cell (N = 1, 2, 4, 8). It is
  positive with partial acceptance (HALF: +0.068%, +0.124%, +0.157%) and with rejection (REJ: +0.206%,
  +0.276%, +0.317%). No cell is exactly neutral. The submitted README omitted the negative A-N2 cell.
  The cause is that A4's extra writes hit a warm, already-dirty slot (`live` and `evaluated` are
  packed together), so they cost less than the bookkeeping A4 removes.
- A1, A2, A3 and A5 are positive in every measured cell. Their relative effect depends on the base:
  A1 on Request is 1.91–4.24% in E0 and 2.27–2.76% in E2 (the E2 denominator is larger, and the E0
  1024-byte cell is distorted by the Bpo1 calldata floor).
- A3 is now also measured on REJ cells (+0.590%, +1.089%, +2.170% for N = 2, 4, 8). The A3 × A4
  interaction (A34 − A3 − A4) is 0 gas on every HALF cell and ±1 gas on REJ, so the two effects are
  additive.

## Residual limitations (Contract Net not modified)

| Limitation | Status | Scope |
|---|---|---|
| Abandoned Request strands storage and blocks reuse of the conversationId | Reproduced (`ResidualExposure.t.sol`) | Both BLADE and manual |
| conversationId squatting by a third party blocks the honest request | Reproduced | Both; the squatted session stays isolated from the honest initiator |
| Relay replay, CFP front-running and squatting, timestamp drift, Contract Net liveness | Core limitation tests at 4b60b86 (`data/E2/core-limitation-tests.log`, 17 PASS; full suite `data/E2/core_tests.log`, 207 PASS) | Architectural; relay unreachable in the measured wrappers (`trustedRelay == 0`) |

The Request fix rejects stale replies after a conversationId is reused. It does not eliminate all
forms of replay: replay through a trusted relay and squatting remain.

## Nonce-packing study (S-NONCE; not E3, not the official Core)

Isolated overlay of `revision/src/core-variants/nonce-packed/RequestAgent.sol` on Core 4b60b86.
The public `requestStatus` ABI is unchanged (the initiator recomputes `replyWith`); the participant
still stores the token. The per-session nonce is a `uint80` packed into the 10-byte padding of the
initiator's first session slot. Measured only on the `nonce` matrix; Contract Net is bit-identical.

| Quantity | Result |
|---|---|
| Complete Request interaction | −22,067 to −25,297 gas vs E2 (−11.8% on REQ-R1-P0) |
| `startRequest` (first and subsequent) | −22,193 |
| `agree` | −1,306 |
| Terminal (empty payload) | −1,798 |
| Terminal inform at 1024 B | **+1,432** (lost refund of the uncleared token slot) |
| Deployment | **+35,251** initiator, **+30,907** participant |
| Manual baseline | 0 difference (control) |
| Contract Net | 0 difference |
| Live initiator session slots | 1 (vs 2 in E2) + 1 persistent nonce |

Core tests at the same fuzz seed: official E2 207/207; packed 206/207. The single failure is
`Request.t.sol::test_corr_tokenAssignedByCoreAndDeliveredToPeer`, which peeks at
`_request[id].replyWith` in storage (zero on the packed initiator). `requestStatus().replyWith`,
correlation, replay, reuse, fuzz, invariants and the trusted-relay tests pass. Packed-specific
tests cover the Core formula, a `uint80` exhaustion revert, and a **chain-id change during a live
session**: packed recomputes with the new id and rejects the old token; official compares the stored
token and still accepts. That is a real semantic difference.

**Recommendation: do not adopt** in the official Core. Interaction savings are real but deployment
grows, a 1024-byte terminal can cost more, the mapping layout and a new `RequestNonceExhausted`
error change, and in-session chain-id behaviour diverges. E2 is unchanged.

## Integrity

`REVISION_MANIFEST.sha256` covers every file under `revision/` and is rewritten by `promote.py`.
Verify it with `sha256sum -c revision/REVISION_MANIFEST.sha256`.
